#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
# Script Name : configure-lab-infra-server.sh
# Description : Configures all essential lab infra services on localhost.
#               Replaces the former Ansible playbook with pure Bash.
#               Services: firewall, nginx, NFS, chronyd, git/prompt, PXE boot (Kea/radvd/TFTP).

set -euo pipefail

source /tux2lab/common-utils/color-functions.sh

# =====================================================================
# Load environment variables from /etc/environment
# (Set by setup.sh / deploy-lab-infra-server.sh via dnsbinder)
# =====================================================================
if [[ -f /etc/environment ]]; then
    while IFS='=' read -r key value; do
        [[ -z "$key" || -z "$value" ]] && continue
        value="${value%\"}"
        value="${value#\"}"
        export "$key=$value"
    done < /etc/environment
fi

# =====================================================================
# Validate required environment variables
# =====================================================================
required_env_vars=(
    mgmt_super_user
    mgmt_interface_name
    dnsbinder_server_fqdn
    dnsbinder_server_short_name
    dnsbinder_server_ipv4_address
    dnsbinder_server_ipv6_address
    dnsbinder_network_cidr
    dnsbinder_ipv6_ula_subnet
    dnsbinder_domain
    dnsbinder_last24_subnet
    dnsbinder_gateway
    dnsbinder_broadcast
)

for var in "${required_env_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        print_error "Required environment variable '${var}' is not set."
        print_info "Ensure /etc/environment is populated (run setup.sh first)."
        exit 1
    fi
done

# =====================================================================
# Determine host mode vs VM mode
# =====================================================================
is_host_mode=false
if [[ -f /tux2lab-data/lab_environment_vars ]]; then
    if grep -q '^lab_infra_server_mode_is_host=true' /tux2lab-data/lab_environment_vars; then
        is_host_mode=true
    fi
fi

# =====================================================================
# 1. Apply Firewall Rules
# =====================================================================
configure_firewall() {
    print_info "Configuring firewall rules..."

    if ! systemctl is-active --quiet firewalld; then
        print_info "Firewalld is not running. Skipping firewall rules."
        return
    fi

    print_info "Firewalld is running. Adding lab network CIDRs to trusted zone."

    print_task "Adding IPv4 CIDR ${dnsbinder_network_cidr} to trusted zone..."
    if sudo firewall-cmd --permanent --zone=trusted --add-source="${dnsbinder_network_cidr}" &>/dev/null; then
        print_task_done
    else
        print_task_skip
    fi

    print_task "Adding IPv6 CIDR ${dnsbinder_ipv6_ula_subnet} to trusted zone..."
    if sudo firewall-cmd --permanent --zone=trusted --add-source="${dnsbinder_ipv6_ula_subnet}" &>/dev/null; then
        print_task_done
    else
        print_task_skip
    fi

    print_task "Reloading firewalld..."
    sudo firewall-cmd --reload &>/dev/null
    print_task_done
}

# =====================================================================
# 2. Configure nginx Web Server
# =====================================================================
configure_nginx() {
    print_info "Configuring nginx web server..."

    # Create /tux2lab-data directory
    print_task "Ensuring /tux2lab-data directory exists..."
    sudo mkdir -p /tux2lab-data
    sudo chown "${mgmt_super_user}:${mgmt_super_user}" /tux2lab-data
    print_task_done

    # Remove default server block from nginx.conf
    print_task "Removing default server block from nginx.conf..."
    sudo sed -i '/include \/etc\/nginx\/conf\.d\/\*\.conf;/,/^}/{ /include \/etc\/nginx\/conf\.d\/\*\.conf;/b; /^}/b; d; }' /etc/nginx/nginx.conf
    print_task_done

    # Build SSL Subject Alternative Names
    local ssl_san="DNS:${dnsbinder_server_fqdn},DNS:${dnsbinder_server_short_name},IP:${dnsbinder_server_ipv4_address},IP:${dnsbinder_server_ipv6_address}"

    # Generate self-signed SSL private key
    if [[ ! -f /etc/pki/tls/private/tux2lab-nginx-selfsigned.key ]]; then
        print_task "Generating self-signed SSL private key..."
        sudo openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
            -out /etc/pki/tls/private/tux2lab-nginx-selfsigned.key &>/dev/null
        print_task_done
    else
        print_task "Generating self-signed SSL private key..."
        print_task_skip
    fi

    sudo chmod 0600 /etc/pki/tls/private/tux2lab-nginx-selfsigned.key

    # Generate self-signed SSL certificate
    if [[ ! -f /etc/pki/tls/certs/tux2lab-nginx-selfsigned.crt ]]; then
        print_task "Generating self-signed SSL certificate..."
        sudo openssl req -new -x509 \
            -key /etc/pki/tls/private/tux2lab-nginx-selfsigned.key \
            -out /etc/pki/tls/certs/tux2lab-nginx-selfsigned.crt \
            -days 3650 \
            -subj "/O=${dnsbinder_server_fqdn}/CN=${dnsbinder_server_fqdn}" \
            -addext "subjectAltName=${ssl_san}"
        print_task_done
    else
        print_task "Generating self-signed SSL certificate..."
        print_task_skip
    fi

    # Copy cert to system trust anchors and update CA trust
    print_task "Updating system CA trust..."
    sudo cp -f /etc/pki/tls/certs/tux2lab-nginx-selfsigned.crt \
        /etc/pki/ca-trust/source/anchors/tux2lab-nginx-selfsigned.crt
    sudo chmod 0644 /etc/pki/ca-trust/source/anchors/tux2lab-nginx-selfsigned.crt
    sudo update-ca-trust
    print_task_done

    # Create custom nginx configuration
    print_task "Deploying custom nginx configuration..."
    sudo tee /etc/nginx/conf.d/tux2lab.conf > /dev/null <<EOF
server {
    listen ${dnsbinder_server_ipv4_address}:80;
    listen [${dnsbinder_server_ipv6_address}]:80;
    server_name ${dnsbinder_server_fqdn};

    root /tux2lab-data;

    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;
    include /etc/nginx/mime.types;
    default_type text/plain;
}

server {
    listen ${dnsbinder_server_ipv4_address}:443 ssl;
    listen [${dnsbinder_server_ipv6_address}]:443 ssl;
    server_name ${dnsbinder_server_fqdn};

    ssl_certificate /etc/pki/tls/certs/tux2lab-nginx-selfsigned.crt;
    ssl_certificate_key /etc/pki/tls/private/tux2lab-nginx-selfsigned.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5:!RC4;
    ssl_prefer_server_ciphers on;

    root /tux2lab-data;

    autoindex on;
    autoindex_exact_size off;
    autoindex_localtime on;
    include /etc/nginx/mime.types;
    default_type text/plain;
}
EOF
    print_task_done

    # Restart nginx
    print_task "Restarting nginx..."
    sudo systemctl restart nginx
    sudo systemctl enable nginx &>/dev/null
    print_task_done
}

# =====================================================================
# 3. Configure NFS Service
# =====================================================================
configure_nfs() {
    print_info "Configuring NFS service..."

    # Create custom exports
    print_task "Deploying /etc/exports..."
    sudo tee /etc/exports > /dev/null <<EOF
/tux2lab-data *.${dnsbinder_domain}(ro,no_subtree_check,no_root_squash,crossmnt)
EOF
    print_task_done

    # Configure NFS to listen on both IPv4 and IPv6
    print_task "Configuring NFS listen addresses in /etc/nfs.conf..."
    if grep -q '^host=' /etc/nfs.conf; then
        sudo sed -i "s|^host=.*|host=${dnsbinder_server_ipv4_address},${dnsbinder_server_ipv6_address}|" /etc/nfs.conf
    else
        sudo sed -i "/^\[nfsd\]$/a host=${dnsbinder_server_ipv4_address},${dnsbinder_server_ipv6_address}" /etc/nfs.conf
    fi
    print_task_done

    # Restart NFS
    print_task "Restarting nfs-server..."
    sudo systemctl restart nfs-server
    sudo systemctl enable nfs-server &>/dev/null
    print_task_done
}

# =====================================================================
# 4. Configure Chronyd (NTP) Service
# =====================================================================
configure_chronyd() {
    print_info "Configuring chronyd (NTP) service..."

    local chrony_config_block
    chrony_config_block="pool time.google.com iburst
bindaddress ${dnsbinder_server_ipv4_address}
bindaddress ${dnsbinder_server_ipv6_address}
allow ${dnsbinder_network_cidr}
allow ${dnsbinder_ipv6_ula_subnet}
local stratum 10"

    if $is_host_mode; then
        # Host mode: Use drop-in config — don't touch the system chrony.conf
        local chrony_confdir
        chrony_confdir=$(grep -m1 '^confdir\s' /etc/chrony.conf 2>/dev/null | awk '{print $2}' || true)

        if [[ -z "$chrony_confdir" ]]; then
            chrony_confdir="/etc/chrony.d"
        fi

        print_task "Ensuring chrony drop-in directory ${chrony_confdir} exists..."
        sudo mkdir -p "$chrony_confdir"
        print_task_done

        # Add confdir directive if missing
        if ! grep -q '^confdir\s' /etc/chrony.conf; then
            print_task "Adding confdir directive to /etc/chrony.conf..."
            sudo cp -p /etc/chrony.conf /etc/chrony.conf.bak
            printf '%s\n' "confdir ${chrony_confdir}" | sudo tee -a /etc/chrony.conf > /dev/null
            print_task_done
        fi

        print_task "Deploying tux2lab chrony drop-in config..."
        sudo tee "${chrony_confdir}/tux2lab.conf" > /dev/null <<EOF
# tux2lab NTP configuration
${chrony_config_block}
EOF
        sudo chmod 0644 "${chrony_confdir}/tux2lab.conf"
        sudo chown root:root "${chrony_confdir}/tux2lab.conf"
        print_task_done
    else
        # VM mode: Edit /etc/chrony.conf directly — we own the VM
        print_task "Commenting existing NTP pools in /etc/chrony.conf..."
        sudo sed -i 's/^pool /#pool /' /etc/chrony.conf
        print_task_done

        local marker_begin="# BEGIN ntp-${dnsbinder_server_fqdn}-settings"
        local marker_end="# END ntp-${dnsbinder_server_fqdn}-settings"

        # Remove existing block if present
        if grep -q "${marker_begin}" /etc/chrony.conf; then
            sudo sed -i "/${marker_begin}/,/${marker_end}/d" /etc/chrony.conf
        fi

        print_task "Adding custom NTP configuration to /etc/chrony.conf..."
        sudo cp -p /etc/chrony.conf /etc/chrony.conf.bak
        {
            echo "${marker_begin}"
            echo "${chrony_config_block}"
            echo "${marker_end}"
        } | sudo tee -a /etc/chrony.conf > /dev/null
        print_task_done
    fi

    # Restart chronyd
    print_task "Restarting chronyd..."
    sudo systemctl restart chronyd
    sudo systemctl enable chronyd &>/dev/null
    print_task_done
}

# =====================================================================
# 5. Configure Git and Command Prompt
# =====================================================================
configure_git_and_prompt() {
    print_info "Configuring git prompt and command prompt..."

    local git_prompt_src="/tux2lab/configure-lab-infra-server/files/git-prompt.sh"

    # Install git-prompt.sh for root
    print_task "Installing git-prompt.sh for root..."
    sudo cp -f "$git_prompt_src" /root/.git-prompt.sh
    sudo chmod 0644 /root/.git-prompt.sh
    print_task_done

    # Install git-prompt.sh for management user
    print_task "Installing git-prompt.sh for ${mgmt_super_user}..."
    sudo cp -f "$git_prompt_src" "/home/${mgmt_super_user}/.git-prompt.sh"
    sudo chown "${mgmt_super_user}:${mgmt_super_user}" "/home/${mgmt_super_user}/.git-prompt.sh"
    sudo chmod 0644 "/home/${mgmt_super_user}/.git-prompt.sh"
    print_task_done

    # Source git-prompt.sh in .bashrc for both users
    local bashrc_files=("/root/.bashrc" "/home/${mgmt_super_user}/.bashrc")
    for bashrc in "${bashrc_files[@]}"; do
        if ! sudo grep -q 'source ~/.git-prompt.sh' "$bashrc"; then
            print_task "Adding git-prompt source to ${bashrc}..."
            echo 'source ~/.git-prompt.sh' | sudo tee -a "$bashrc" > /dev/null
            print_task_done
        fi
    done

    # PS1 variables
    local ps1_mgmt_user="PS1='[\\[\\033]0;\$TITLEPREFIX:\\007\\]\\[\\033[0;32m\\]\\u\\[\\033[0;35m\\]@\\[\\033[0;32m\\]\\h \\[\\033[0;36m\\]\\W\\[\\033[0;33m\\]\`__git_ps1\`\\[\\033[0m\\]]$ '"
    local ps1_root_user="PS1='[\\[\\033]0;\$TITLEPREFIX:\\007\\]\\[\\033[0;31m\\]\\u\\[\\033[0;35m\\]@\\[\\033[0;31m\\]\\h \\[\\033[0;36m\\]\\W\\[\\033[0;33m\\]\`__git_ps1\`\\[\\033[0m\\]]# '"

    # Update PS1 for management user
    print_task "Setting PS1 for ${mgmt_super_user}..."
    local mgmt_bashrc="/home/${mgmt_super_user}/.bashrc"
    sudo sed -i '/^PS1=/d' "$mgmt_bashrc"
    echo "${ps1_mgmt_user}" | sudo tee -a "$mgmt_bashrc" > /dev/null
    print_task_done

    # Update PS1 for root
    print_task "Setting PS1 for root..."
    sudo sed -i '/^PS1=/d' /root/.bashrc
    echo "${ps1_root_user}" | sudo tee -a /root/.bashrc > /dev/null
    print_task_done
}

# =====================================================================
# 6. Setup PXE Boot Environment (Kea DHCP4/6, radvd, TFTP, iPXE)
# =====================================================================
setup_pxe_boot() {
    print_info "Setting up PXE boot environment..."

    # ------------------------------------------------------------------
    # Detect Kea socket directory
    # ------------------------------------------------------------------
    print_task "Detecting Kea socket directory..."
    local kea_run_dir
    kea_run_dir=$(systemctl show kea-dhcp4.service -p Environment 2>/dev/null \
        | grep -oP 'KEA_CONTROL_SOCKET_DIR=\K[^ "]+' || true)

    if [[ -z "$kea_run_dir" ]]; then
        local test_cfg
        test_cfg=$(mktemp)
        echo '{"Dhcp4":{"control-socket":{"socket-type":"unix","socket-name":"/run/kea/test"}}}' > "$test_cfg"
        local test_output
        test_output=$(kea-dhcp4 -t "$test_cfg" 2>&1 || true)
        rm -f "$test_cfg"
        if echo "$test_output" | grep -qP "supported path is '"; then
            kea_run_dir=$(echo "$test_output" | grep -oP "supported path is '\K[^']+" | head -1)
        else
            kea_run_dir="/run/kea"
        fi
    fi
    print_task_done
    print_info "Kea socket directory: ${kea_run_dir}"

    local kea_ctrl_agent_password="kea-api-password"

    # ------------------------------------------------------------------
    # Compute IPv6 DHCPv6 pool range
    # The pool maps IPv4 octets into IPv6 hex segments for the last 99 IPs
    # ------------------------------------------------------------------
    local ipv6_prefix_base
    ipv6_prefix_base=$(echo "${dnsbinder_ipv6_ula_subnet}" | sed 's|::/.*$||')

    # Split the last-24 subnet into octets (e.g., "192.168.100" → 192 168 100)
    IFS='.' read -r oct1 oct2 oct3 <<< "${dnsbinder_last24_subnet}"

    # Build hex segments: oct1+oct2 → 2 bytes, 00+oct3 → 2 bytes
    local hex_oct12 hex_00oct3
    hex_oct12=$(printf '%02x%02x' "$oct1" "$oct2")
    hex_00oct3=$(printf '00%02x' "$oct3")

    # Pool start: ...:<oct1><oct2>:<00><oct3>:<oct1><oct2>:<oct3>9c
    local pool_start="${ipv6_prefix_base}:${hex_oct12}:${hex_00oct3}:${hex_oct12}:$(printf '%02x' "$oct3")9c"
    # Pool end:   ...:<oct1><oct2>:<00><oct3>:<oct1><oct2>:<oct3>fe
    local pool_end="${ipv6_prefix_base}:${hex_oct12}:${hex_00oct3}:${hex_oct12}:$(printf '%02x' "$oct3")fe"

    # ------------------------------------------------------------------
    # Configure /etc/kea/kea-dhcp4.conf
    # ------------------------------------------------------------------
    print_task "Deploying /etc/kea/kea-dhcp4.conf..."
    sudo tee /etc/kea/kea-dhcp4.conf > /dev/null <<EOF
{
  "Dhcp4": {
    "control-socket": {
      "socket-type": "unix",
      "socket-name": "${kea_run_dir}/kea4-ctrl-socket"
    },
    "interfaces-config": {
      "interfaces": [ "${mgmt_interface_name}" ],
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
        "subnet": "${dnsbinder_network_cidr}",
        "pools": [
          { "pool": "${dnsbinder_last24_subnet}.156 - ${dnsbinder_last24_subnet}.254" }
        ],
        "option-data": [
          { "name": "routers",              "data": "${dnsbinder_gateway}" },
          { "name": "domain-name-servers",  "data": "${dnsbinder_server_ipv4_address}" },
          { "name": "domain-name",          "data": "${dnsbinder_domain}" },
          { "name": "domain-search",        "data": "${dnsbinder_domain}" },
          { "name": "broadcast-address",    "data": "${dnsbinder_broadcast}" }
        ],
        "next-server": "${dnsbinder_server_ipv4_address}",
        "boot-file-name": "ipxe.efi"
      }
    ]
  }
}
EOF
    print_task_done

    # Restart kea-dhcp4
    print_task "Restarting kea-dhcp4..."
    sudo systemctl restart kea-dhcp4
    sudo systemctl enable kea-dhcp4 &>/dev/null
    print_task_done

    # ------------------------------------------------------------------
    # Configure /etc/kea/kea-dhcp6.conf
    # ------------------------------------------------------------------
    print_task "Deploying /etc/kea/kea-dhcp6.conf..."
    sudo tee /etc/kea/kea-dhcp6.conf > /dev/null <<EOF
{
  "Dhcp6": {
    "control-socket": {
      "socket-type": "unix",
      "socket-name": "${kea_run_dir}/kea6-ctrl-socket"
    },
    "interfaces-config": {
      "interfaces": [ "${mgmt_interface_name}" ],
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
        "subnet": "${dnsbinder_ipv6_ula_subnet}",
        "interface": "${mgmt_interface_name}",
        "pools": [
          {
            "pool": "${pool_start} - ${pool_end}"
          }
        ],
        "option-data": [
          { "name": "dns-servers",   "data": "${dnsbinder_server_ipv6_address}" },
          { "name": "domain-search", "data": "${dnsbinder_domain}" },
          { "name": "bootfile-url",  "data": "tftp://[${dnsbinder_server_ipv6_address}]/ipxe.efi" }
        ]
      }
    ]
  }
}
EOF
    print_task_done

    # Restart kea-dhcp6
    print_task "Restarting kea-dhcp6..."
    sudo systemctl restart kea-dhcp6
    sudo systemctl enable kea-dhcp6 &>/dev/null
    print_task_done

    # ------------------------------------------------------------------
    # Configure /etc/kea/kea-ctrl-agent.conf
    # ------------------------------------------------------------------
    print_task "Deploying /etc/kea/kea-ctrl-agent.conf..."
    sudo tee /etc/kea/kea-ctrl-agent.conf > /dev/null <<EOF
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
          "password": "${kea_ctrl_agent_password}"
        }
      ]
    },

    "control-sockets": {
      "dhcp4": {
        "socket-type": "unix",
        "socket-name": "${kea_run_dir}/kea4-ctrl-socket"
      },
      "dhcp6": {
        "socket-type": "unix",
        "socket-name": "${kea_run_dir}/kea6-ctrl-socket"
      }
    }
  }
}
EOF
    print_task_done

    # Restart kea-ctrl-agent
    print_task "Restarting kea-ctrl-agent..."
    sudo systemctl restart kea-ctrl-agent
    sudo systemctl enable kea-ctrl-agent &>/dev/null
    print_task_done

    # ------------------------------------------------------------------
    # Configure radvd for IPv6 Router Advertisements
    # ------------------------------------------------------------------
    print_task "Deploying /etc/radvd.conf..."
    sudo tee /etc/radvd.conf > /dev/null <<EOF
interface ${mgmt_interface_name}
{
    MinRtrAdvInterval 30;
    MaxRtrAdvInterval 100;

    AdvSendAdvert on;
    AdvManagedFlag on;        # M=1: Use DHCPv6 for addresses
    AdvOtherConfigFlag on;    # O=1: Use DHCPv6 for DNS/options

    prefix ${dnsbinder_ipv6_ula_subnet}
    {
        AdvOnLink on;
        AdvAutonomous off;    # A=0: Disable SLAAC, force DHCPv6
        AdvRouterAddr on;
        AdvValidLifetime 3600;
        AdvPreferredLifetime 1800;
    };

    RDNSS ${dnsbinder_server_ipv6_address}
    {
        AdvRDNSSLifetime 600;
    };

    DNSSL ${dnsbinder_domain}
    {
        AdvDNSSLLifetime 600;
    };
};
EOF
    print_task_done

    # Restart radvd
    print_task "Restarting radvd..."
    sudo systemctl restart radvd
    sudo systemctl enable radvd &>/dev/null
    print_task_done

    # ------------------------------------------------------------------
    # Enable IPv6 forwarding for radvd
    # ------------------------------------------------------------------
    print_task "Enabling IPv6 forwarding..."
    echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee /etc/sysctl.d/99-ipv6-forwarding.conf > /dev/null
    sudo sysctl -w net.ipv6.conf.all.forwarding=1 &>/dev/null
    print_task_done

    # ------------------------------------------------------------------
    # Bind-mount /tux2lab under /tux2lab-data
    # ------------------------------------------------------------------
    print_task "Setting up bind mount /tux2lab → /tux2lab-data/tux2lab..."
    sudo mkdir -p /tux2lab-data/tux2lab

    # Unmount stale mount if present
    if mountpoint -q /tux2lab-data/tux2lab 2>/dev/null; then
        sudo umount /tux2lab-data/tux2lab 2>/dev/null || true
    fi

    sudo mount --bind /tux2lab /tux2lab-data/tux2lab
    sudo mount -o remount,bind,ro /tux2lab-data/tux2lab

    # Ensure fstab entry exists
    if ! grep -q '/tux2lab-data/tux2lab' /etc/fstab 2>/dev/null; then
        echo '/tux2lab  /tux2lab-data/tux2lab  none  bind,ro  0  0' | sudo tee -a /etc/fstab > /dev/null
    fi
    print_task_done

    # ------------------------------------------------------------------
    # Deploy iPXE files
    # ------------------------------------------------------------------
    print_task "Deploying iPXE boot files..."
    sudo mkdir -p /tux2lab-data/ipxe
    sudo chown "${mgmt_super_user}:${mgmt_super_user}" /tux2lab-data/ipxe

    sudo cp -f /tux2lab/configure-lab-infra-server/files/ipxe.efi /tux2lab-data/ipxe/ipxe.efi
    sudo chmod 0644 /tux2lab-data/ipxe/ipxe.efi

    sudo cp -f /tux2lab/configure-lab-infra-server/files/ipxe.efi /var/lib/tftpboot/ipxe.efi
    sudo chmod 0644 /var/lib/tftpboot/ipxe.efi
    print_task_done

    # ------------------------------------------------------------------
    # Enable TFTP
    # ------------------------------------------------------------------
    print_task "Enabling tftp.socket..."
    sudo systemctl start tftp.socket
    sudo systemctl enable tftp.socket &>/dev/null
    print_task_done

    # ------------------------------------------------------------------
    # Final service enable sweep
    # ------------------------------------------------------------------
    print_task "Ensuring all PXE services are started and enabled..."
    local pxe_services=("kea-dhcp4" "kea-dhcp6" "kea-ctrl-agent" "radvd")
    for svc in "${pxe_services[@]}"; do
        sudo systemctl start "$svc" 2>/dev/null || true
        sudo systemctl enable "$svc" &>/dev/null || true
    done
    print_task_done

    # ------------------------------------------------------------------
    # Create CLI symlinks
    # ------------------------------------------------------------------
    print_task "Creating CLI symlinks (dnsbinder, ksmanager, prepare-distro-for-ksmanager)..."

    sudo ln -sf /tux2lab/named-manage/dnsbinder.sh /usr/sbin/dnsbinder
    sudo chmod 0755 /tux2lab/ks-manage/ksmanager.sh
    sudo ln -sf /tux2lab/ks-manage/ksmanager.sh /usr/local/bin/ksmanager
    sudo chmod 0755 /tux2lab/ks-manage/prepare-distro-for-ksmanager.sh
    sudo ln -sf /tux2lab/ks-manage/prepare-distro-for-ksmanager.sh /usr/local/bin/prepare-distro-for-ksmanager

    print_task_done
}

# =====================================================================
# Main execution — mirrors the former playbook role order
# =====================================================================
print_info "Configuring Lab Infra Services..."
configure_firewall
configure_nginx
configure_nfs
configure_chronyd
if ! $is_host_mode; then
    configure_git_and_prompt
fi
setup_pxe_boot

# Apply SELinux contexts if SELinux is present and not disabled
if $is_host_mode && command -v getenforce &>/dev/null && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
    print_info "Applying SELinux contexts for lab services..."
    # named: zone files
    if [[ -d /tux2lab-data/dnsbinder-managed-zone-files ]]; then
        sudo chcon -R -t named_zone_t /tux2lab-data/dnsbinder-managed-zone-files 2>/dev/null || true
    fi
    # nginx: web content
    sudo chcon -R -t httpd_sys_content_t /tux2lab-data 2>/dev/null || true
    # NFS exports
    sudo setsebool -P nfs_export_all_ro on 2>/dev/null || true
    sudo setsebool -P nfs_export_all_rw on 2>/dev/null || true
fi

print_success "All Lab Infra Services have been configured successfully."
