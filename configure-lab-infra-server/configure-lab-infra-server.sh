#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name : configure-lab-infra-server.sh
# Description : Generate service configuration files from lab_environment.json
#               Writes configs to /tux2lab-data/<service>/ for container consumption.
#
# Usage       : Called by deploy-lab.sh or manually for config regeneration
# If you encounter any issues with this script, or have suggestions or feature requests,
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh

# ============================================================================
# READ LAB ENVIRONMENT
# ============================================================================
readonly LAB_ENV_JSON="/tux2lab-data/lab-config/lab_environment.json"

if [[ ! -f "${LAB_ENV_JSON}" ]]; then
    print_error "Lab environment file not found: ${LAB_ENV_JSON}"
    print_info "Run 'tux2lab deploy' first."
    exit 1
fi

# Read all values from JSON
DOMAIN=$(jq -r '.lab.domain' "${LAB_ENV_JSON}")
ENGINE_HOSTNAME=$(jq -r '.lab.engine_hostname' "${LAB_ENV_JSON}")
ENGINE_FQDN=$(jq -r '.lab.engine_fqdn' "${LAB_ENV_JSON}")
BRIDGE_IF=$(jq -r '.network.bridge_interface' "${LAB_ENV_JSON}")
IPV4_ADDRESS=$(jq -r '.network.ipv4.address' "${LAB_ENV_JSON}")
IPV4_CIDR=$(jq -r '.network.ipv4.cidr' "${LAB_ENV_JSON}")
IPV4_LAST24=$(jq -r '.network.ipv4.last24_subnet' "${LAB_ENV_JSON}")
DHCP_START=$(jq -r '.network.ipv4.dhcp_range_start' "${LAB_ENV_JSON}")
DHCP_END=$(jq -r '.network.ipv4.dhcp_range_end' "${LAB_ENV_JSON}")
IPV6_ADDRESS=$(jq -r '.network.ipv6.address' "${LAB_ENV_JSON}")
IPV6_PREFIX=$(jq -r '.network.ipv6.prefix' "${LAB_ENV_JSON}")
IPV6_PREFIX_BASE=$(jq -r '.network.ipv6.prefix_base' "${LAB_ENV_JSON}")
IPV6_ULA_SUBNET=$(jq -r '.network.ipv6.ula_subnet' "${LAB_ENV_JSON}")

readonly DATA_DIR="/tux2lab-data"
readonly CERTS_DIR="${DATA_DIR}/lab-config/certs"

# ============================================================================
# NGINX CONFIGURATION
# ============================================================================
configure_nginx() {
    print_task "Generating nginx configuration..."

    mkdir -p "${DATA_DIR}/nginx"

    cat > "${DATA_DIR}/nginx/nginx.conf" <<EOF
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /run/nginx.pid;

include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 1024;
}

http {
    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '"\$http_user_agent"';

    access_log  /var/log/nginx/access.log  main;

    sendfile            on;
    tcp_nopush          on;
    keepalive_timeout   65;
    types_hash_max_size 4096;

    include             /etc/nginx/mime.types;
    default_type        application/octet-stream;

    server {
        listen ${IPV4_ADDRESS}:80;
        listen [${IPV6_ADDRESS}]:80;
        server_name ${ENGINE_FQDN};

        root ${DATA_DIR};

        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
        default_type text/plain;
    }

    server {
        listen ${IPV4_ADDRESS}:443 ssl;
        listen [${IPV6_ADDRESS}]:443 ssl;
        server_name ${ENGINE_FQDN};

        ssl_certificate ${CERTS_DIR}/tux2lab-nginx-selfsigned.crt;
        ssl_certificate_key ${CERTS_DIR}/tux2lab-nginx-selfsigned.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5:!RC4;
        ssl_prefer_server_ciphers on;

        root ${DATA_DIR};

        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
        default_type text/plain;
    }
}
EOF

    print_task_done
}

# ============================================================================
# CHRONY (NTP) CONFIGURATION
# ============================================================================
configure_chrony() {
    print_task "Generating chrony configuration..."

    mkdir -p "${DATA_DIR}/chrony"

    cat > "${DATA_DIR}/chrony/chrony.conf" <<EOF
# NTP upstream sources
pool time.google.com iburst

# Record clock drift
driftfile /var/lib/chrony/drift

# Step clock if offset > 1 second in first 3 updates
makestep 1.0 3

# Enable kernel RTC sync
rtcsync

# NTS keys and cookies
ntsdumpdir /var/lib/chrony

# Log directory
logdir /var/log/chrony

# Bind to lab bridge IP only
bindaddress ${IPV4_ADDRESS}
bindaddress ${IPV6_ADDRESS}

# Allow lab network clients
allow ${IPV4_CIDR}
allow ${IPV6_ULA_SUBNET}

# Serve time even if not synced
local stratum 10
EOF

    print_task_done
}

# ============================================================================
# RADVD (IPv6 Router Advertisement) CONFIGURATION
# ============================================================================
configure_radvd() {
    print_task "Generating radvd configuration..."

    mkdir -p "${DATA_DIR}/radvd"

    cat > "${DATA_DIR}/radvd/radvd.conf" <<EOF
interface ${BRIDGE_IF}
{
    MinRtrAdvInterval 30;
    MaxRtrAdvInterval 100;

    AdvSendAdvert on;
    AdvManagedFlag on;
    AdvOtherConfigFlag on;

    prefix ${IPV6_PREFIX_BASE}::/${IPV6_PREFIX}
    {
        AdvOnLink on;
        AdvAutonomous off;
        AdvRouterAddr on;
        AdvValidLifetime 3600;
        AdvPreferredLifetime 1800;
    };

    RDNSS ${IPV6_ADDRESS}
    {
        AdvRDNSSLifetime 600;
    };

    DNSSL ${DOMAIN}
    {
        AdvDNSSLLifetime 600;
    };
};
EOF

    print_task_done
}

# ============================================================================
# NFS CONFIGURATION
# ============================================================================
configure_nfs() {
    print_task "Generating NFS exports..."

    mkdir -p "${DATA_DIR}/nfs"

    cat > "${DATA_DIR}/nfs/exports" <<EOF
${DATA_DIR} *.${DOMAIN}(ro,no_subtree_check,no_root_squash,crossmnt)
EOF

    print_task_done
}

# ============================================================================
# KEA DHCP4 CONFIGURATION
# ============================================================================
configure_kea_dhcp4() {
    print_task "Generating kea-dhcp4 configuration..."

    mkdir -p "${DATA_DIR}/kea"

    cat > "${DATA_DIR}/kea/kea-dhcp4.conf" <<EOF
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": [ "${BRIDGE_IF}" ],
      "service-sockets-max-retries": 10,
      "service-sockets-retry-wait-time": 5000
    },
    "lease-database": {
      "type": "memfile",
      "persist": true,
      "lfc-interval": 3600
    },
    "valid-lifetime": 3600,
    "renew-timer": 900,
    "rebind-timer": 1800,
    "hooks-libraries": [
      { "library": "/usr/lib64/kea/hooks/libdhcp_lease_cmds.so" }
    ],
    "subnet4": [
      {
        "id": 1,
        "subnet": "${IPV4_CIDR}",
        "pools": [
          { "pool": "${DHCP_START} - ${DHCP_END}" }
        ],
        "option-data": [
          { "name": "routers", "data": "${IPV4_ADDRESS}" },
          { "name": "domain-name-servers", "data": "${IPV4_ADDRESS}" },
          { "name": "domain-name", "data": "${DOMAIN}" },
          { "name": "tftp-server-name", "data": "${IPV4_ADDRESS}" },
          { "name": "boot-file-name", "data": "ipxe.efi" }
        ],
        "reservations": []
      }
    ]
  }
}
EOF

    print_task_done
}

# ============================================================================
# KEA DHCP6 CONFIGURATION
# ============================================================================
configure_kea_dhcp6() {
    print_task "Generating kea-dhcp6 configuration..."

    # Calculate DHCPv6 pool range from subnet
    IFS='.' read -r oct1 oct2 oct3 <<< "${IPV4_LAST24}"
    local hex_oct12 hex_00oct3
    hex_oct12=$(printf '%02x%02x' "$oct1" "$oct2")
    hex_00oct3=$(printf '00%02x' "$oct3")
    local pool_start="${IPV6_PREFIX_BASE}:${hex_oct12}:${hex_00oct3}:${hex_oct12}:$(printf '%02x' "$oct3")9c"
    local pool_end="${IPV6_PREFIX_BASE}:${hex_oct12}:${hex_00oct3}:${hex_oct12}:$(printf '%02x' "$oct3")fe"

    cat > "${DATA_DIR}/kea/kea-dhcp6.conf" <<EOF
{
  "Dhcp6": {
    "interfaces-config": {
      "interfaces": [ "${BRIDGE_IF}" ]
    },
    "lease-database": {
      "type": "memfile",
      "persist": true,
      "lfc-interval": 3600
    },
    "valid-lifetime": 3600,
    "renew-timer": 900,
    "rebind-timer": 1800,
    "hooks-libraries": [
      { "library": "/usr/lib64/kea/hooks/libdhcp_lease_cmds.so" }
    ],
    "subnet6": [
      {
        "id": 1,
        "subnet": "${IPV6_PREFIX_BASE}::/${IPV6_PREFIX}",
        "pools": [
          { "pool": "${pool_start} - ${pool_end}" }
        ],
        "option-data": [
          { "name": "dns-servers", "data": "${IPV6_ADDRESS}" },
          { "name": "domain-search", "data": "${DOMAIN}" }
        ],
        "reservations": []
      }
    ]
  }
}
EOF

    print_task_done
}

# ============================================================================
# KEA CONTROL AGENT CONFIGURATION
# ============================================================================
configure_kea_ctrl_agent() {
    print_task "Generating kea-ctrl-agent configuration..."

    cat > "${DATA_DIR}/kea/kea-ctrl-agent.conf" <<EOF
{
  "Control-agent": {
    "http-host": "127.0.0.1",
    "http-port": 8000,
    "authentication": {
      "type": "basic",
      "clients": [
        {
          "user": "kea-api",
          "password-file": "${DATA_DIR}/kea/kea-api-password"
        }
      ]
    },
    "control-sockets": {
      "dhcp4": {
        "socket-type": "unix",
        "socket-name": "/run/kea/kea4-ctrl-socket"
      },
      "dhcp6": {
        "socket-type": "unix",
        "socket-name": "/run/kea/kea6-ctrl-socket"
      }
    }
  }
}
EOF

    # Generate API password if not exists
    if [[ ! -f "${DATA_DIR}/kea/kea-api-password" ]]; then
        openssl rand -hex 16 > "${DATA_DIR}/kea/kea-api-password"
        chmod 600 "${DATA_DIR}/kea/kea-api-password"
    fi

    print_task_done
}

# ============================================================================
# TFTP BOOT FILES
# ============================================================================
configure_tftpboot() {
    print_task "Setting up TFTP boot files..."

    mkdir -p "${DATA_DIR}/tftpboot"

    # Copy iPXE EFI binary from project files
    local ipxe_source="/tux2lab/configure-lab-infra-server/files/ipxe.efi"
    if [[ -f "$ipxe_source" ]]; then
        cp "$ipxe_source" "${DATA_DIR}/tftpboot/ipxe.efi"
        print_task_done
    else
        print_task_fail
        print_warning "iPXE binary not found at ${ipxe_source}"
    fi
}

# ============================================================================
# MAIN
# ============================================================================
print_info "Generating service configurations from ${LAB_ENV_JSON}..."
echo

configure_nginx
configure_chrony
configure_radvd
configure_nfs
configure_kea_dhcp4
configure_kea_dhcp6
configure_kea_ctrl_agent
configure_tftpboot

echo
print_success "All service configurations generated."
print_info "Configs written to ${DATA_DIR}/{nginx,chrony,radvd,nfs,kea}/"
