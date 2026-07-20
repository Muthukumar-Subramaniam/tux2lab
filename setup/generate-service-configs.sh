#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name : generate-service-configs.sh
# Description : Generate all service configuration files from lab_environment.json
#               Outputs configs to /tux2lab-data/<service>/ for the container to read.
#
# Called by   : setup/deploy-lab.sh (during deploy and rebuild)
# If you encounter any issues with this script, or have suggestions or feature requests,
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh

readonly LAB_ENV_JSON="/tux2lab-data/lab-config/lab_environment.json"
readonly DATA_DIR="/tux2lab-data"

if [[ ! -f "${LAB_ENV_JSON}" ]]; then
    print_error "lab_environment.json not found at ${LAB_ENV_JSON}"
    exit 1
fi

# ============================================================================
# READ VALUES FROM JSON
# ============================================================================
DOMAIN=$(jq -r '.lab.domain' "${LAB_ENV_JSON}")
ENGINE_HOSTNAME=$(jq -r '.lab.engine_hostname' "${LAB_ENV_JSON}")
ENGINE_FQDN=$(jq -r '.lab.engine_fqdn' "${LAB_ENV_JSON}")
BRIDGE_IF=$(jq -r '.network.bridge_interface' "${LAB_ENV_JSON}")
IPV4_ADDRESS=$(jq -r '.network.ipv4.address' "${LAB_ENV_JSON}")
IPV4_NETWORK=$(jq -r '.network.ipv4.network' "${LAB_ENV_JSON}")
IPV4_CIDR=$(jq -r '.network.ipv4.cidr' "${LAB_ENV_JSON}")
IPV4_NETMASK=$(jq -r '.network.ipv4.netmask' "${LAB_ENV_JSON}")
IPV4_PREFIX=$(jq -r '.network.ipv4.prefix' "${LAB_ENV_JSON}")
IPV4_GATEWAY=$(jq -r '.network.ipv4.gateway' "${LAB_ENV_JSON}")
IPV4_BROADCAST=$(jq -r '.network.ipv4.broadcast' "${LAB_ENV_JSON}")
IPV4_FIRST24=$(jq -r '.network.ipv4.first24_subnet' "${LAB_ENV_JSON}")
IPV4_LAST24=$(jq -r '.network.ipv4.last24_subnet' "${LAB_ENV_JSON}")
DHCP_START=$(jq -r '.network.ipv4.dhcp_range_start' "${LAB_ENV_JSON}")
DHCP_END=$(jq -r '.network.ipv4.dhcp_range_end' "${LAB_ENV_JSON}")
IPV6_ADDRESS=$(jq -r '.network.ipv6.address' "${LAB_ENV_JSON}")
IPV6_PREFIX=$(jq -r '.network.ipv6.prefix' "${LAB_ENV_JSON}")
IPV6_PREFIX_BASE=$(jq -r '.network.ipv6.prefix_base' "${LAB_ENV_JSON}")
IPV6_ULA_SUBNET=$(jq -r '.network.ipv6.ula_subnet' "${LAB_ENV_JSON}")
UPSTREAM_DNS=$(jq -r '.network.upstream_dns[]' "${LAB_ENV_JSON}")

# ============================================================================
# GENERATE NGINX CONFIG
# ============================================================================
generate_nginx() {
    print_task "Generating nginx config..."
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
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    types_hash_max_size 4096;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    server {
        listen ${IPV4_ADDRESS}:80;
        listen [${IPV6_ADDRESS}]:80;
        server_name ${ENGINE_FQDN};

        root ${DATA_DIR};

        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
    }

    server {
        listen ${IPV4_ADDRESS}:443 ssl;
        listen [${IPV6_ADDRESS}]:443 ssl;
        server_name ${ENGINE_FQDN};

        ssl_certificate ${DATA_DIR}/lab-config/certs/tux2lab-nginx-selfsigned.crt;
        ssl_certificate_key ${DATA_DIR}/lab-config/certs/tux2lab-nginx-selfsigned.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers HIGH:!aNULL:!MD5:!RC4;
        ssl_prefer_server_ciphers on;

        root ${DATA_DIR};

        autoindex on;
        autoindex_exact_size off;
        autoindex_localtime on;
    }
}
EOF
    print_task_done
}

# ============================================================================
# GENERATE KEA DHCPv4 CONFIG
# ============================================================================
generate_kea_dhcp4() {
    print_task "Generating kea-dhcp4 config..."
    mkdir -p "${DATA_DIR}/kea"

    cat > "${DATA_DIR}/kea/kea-dhcp4.conf" <<EOF
{
  "Dhcp4": {
    "control-socket": {
      "socket-type": "unix",
      "socket-name": "/var/run/kea/kea4-ctrl-socket"
    },
    "interfaces-config": {
      "interfaces": [ "${BRIDGE_IF}" ],
      "service-sockets-max-retries": 10,
      "service-sockets-retry-wait-time": 5000
    },
    "lease-database": { "type": "memfile" },
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
          { "name": "routers",              "data": "${IPV4_GATEWAY}" },
          { "name": "domain-name-servers",  "data": "${IPV4_ADDRESS}" },
          { "name": "domain-name",          "data": "${DOMAIN}" },
          { "name": "domain-search",        "data": "${DOMAIN}" },
          { "name": "broadcast-address",    "data": "${IPV4_BROADCAST}" }
        ],
        "next-server": "${IPV4_ADDRESS}",
        "boot-file-name": "ipxe.efi"
      }
    ]
  }
}
EOF
    print_task_done
}

# ============================================================================
# GENERATE KEA DHCPv6 CONFIG
# ============================================================================
generate_kea_dhcp6() {
    print_task "Generating kea-dhcp6 config..."

    # Calculate IPv6 DHCP pool (maps IPv4 octets into hex for the last 99 IPs)
    IFS='.' read -r oct1 oct2 oct3 <<< "${IPV4_LAST24}"
    local hex_oct12
    hex_oct12=$(printf '%02x%02x' "$oct1" "$oct2")
    local hex_00oct3
    hex_00oct3=$(printf '00%02x' "$oct3")
    local oct3_hex
    oct3_hex=$(printf '%02x' "$oct3")

    local pool_start="${IPV6_PREFIX_BASE}:${hex_oct12}:${hex_00oct3}:${hex_oct12}:${oct3_hex}9c"
    local pool_end="${IPV6_PREFIX_BASE}:${hex_oct12}:${hex_00oct3}:${hex_oct12}:${oct3_hex}fe"

    cat > "${DATA_DIR}/kea/kea-dhcp6.conf" <<EOF
{
  "Dhcp6": {
    "control-socket": {
      "socket-type": "unix",
      "socket-name": "/var/run/kea/kea6-ctrl-socket"
    },
    "interfaces-config": {
      "interfaces": [ "${BRIDGE_IF}" ],
      "service-sockets-max-retries": 10,
      "service-sockets-retry-wait-time": 5000
    },
    "lease-database": { "type": "memfile" },
    "valid-lifetime": 3600,
    "renew-timer": 900,
    "rebind-timer": 1800,
    "preferred-lifetime": 1800,
    "hooks-libraries": [
      { "library": "/usr/lib64/kea/hooks/libdhcp_lease_cmds.so" }
    ],
    "subnet6": [
      {
        "id": 1,
        "subnet": "${IPV6_PREFIX_BASE}::/${IPV6_PREFIX}",
        "interface": "${BRIDGE_IF}",
        "pools": [
          {
            "pool": "${pool_start} - ${pool_end}"
          }
        ],
        "option-data": [
          { "name": "dns-servers",   "data": "${IPV6_ADDRESS}" },
          { "name": "domain-search", "data": "${DOMAIN}" },
          { "name": "bootfile-url",  "data": "tftp://[${IPV6_ADDRESS}]/ipxe.efi" }
        ]
      }
    ]
  }
}
EOF
    print_task_done
}

# ============================================================================
# GENERATE KEA CONTROL AGENT CONFIG
# ============================================================================
generate_kea_ctrl_agent() {
    print_task "Generating kea-ctrl-agent config..."

    cat > "${DATA_DIR}/kea/kea-ctrl-agent.conf" <<EOF
{
  "Control-agent": {
    "http-host": "127.0.0.1",
    "http-port": 8000,
    "authentication": {
      "type": "basic",
      "realm": "Kea Control Agent",
      "clients": [
        {
          "user": "kea-api",
          "password": "kea-api-password"
        }
      ]
    },
    "control-sockets": {
      "dhcp4": {
        "socket-type": "unix",
        "socket-name": "/var/run/kea/kea4-ctrl-socket"
      },
      "dhcp6": {
        "socket-type": "unix",
        "socket-name": "/var/run/kea/kea6-ctrl-socket"
      }
    }
  }
}
EOF
    print_task_done
}

# ============================================================================
# GENERATE RADVD CONFIG
# ============================================================================
generate_radvd() {
    print_task "Generating radvd config..."
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
# GENERATE CHRONY CONFIG
# ============================================================================
generate_chrony() {
    print_task "Generating chrony config..."
    mkdir -p "${DATA_DIR}/chrony"

    cat > "${DATA_DIR}/chrony/chrony.conf" <<EOF
pool time.google.com iburst

driftfile /var/lib/chrony/drift
ntsdumpdir /var/lib/chrony
logdir /var/log/chrony

bindaddress ${IPV4_ADDRESS}
bindaddress ${IPV6_ADDRESS}
allow ${IPV4_CIDR}
allow ${IPV6_PREFIX_BASE}::/${IPV6_PREFIX}
local stratum 10
EOF
    print_task_done
}

# ============================================================================
# GENERATE NFS EXPORTS
# ============================================================================
generate_nfs_exports() {
    print_task "Generating NFS exports..."
    mkdir -p "${DATA_DIR}/nfs"

    cat > "${DATA_DIR}/nfs/exports" <<EOF
${DATA_DIR} *.${DOMAIN}(ro,no_subtree_check,no_root_squash,crossmnt)
EOF
    print_task_done
}

# ============================================================================
# SETUP TFTP DIRECTORY
# ============================================================================
setup_tftpboot() {
    print_task "Setting up tftpboot directory..."
    mkdir -p "${DATA_DIR}/tftpboot"

    # Copy iPXE EFI binary from project files if not already present
    local ipxe_source="/tux2lab/common-utils/ipxe-firmware/ipxe.efi"
    if [[ -f "$ipxe_source" && ! -f "${DATA_DIR}/tftpboot/ipxe.efi" ]]; then
        cp "$ipxe_source" "${DATA_DIR}/tftpboot/ipxe.efi"
    fi
    print_task_done
}

# ============================================================================
# SETUP NAMED DIRECTORIES (dnsbinder generates the actual named.conf)
# ============================================================================
setup_named_dirs() {
    print_task "Setting up named directories..."
    mkdir -p "${DATA_DIR}/named/dnsbinder-managed-zone-files"
    mkdir -p "${DATA_DIR}/named/data"
    mkdir -p "${DATA_DIR}/named/dynamic"
    print_task_done
}

# ============================================================================
# MAIN
# ============================================================================
print_info "Generating service configs from ${LAB_ENV_JSON}..."

generate_nginx
generate_kea_dhcp4
generate_kea_dhcp6
generate_kea_ctrl_agent
generate_radvd
generate_chrony
generate_nfs_exports
setup_tftpboot
setup_named_dirs

print_success "All service configurations generated."
