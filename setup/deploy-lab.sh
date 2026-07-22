#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name : deploy-lab.sh
# Description : Deploy tux2lab lab infrastructure
#               Generates lab_environment.json, SSL certs, SSH keys,
#               service configs, and starts the tux2lab-engine container.
#
# Usage       : tux2lab deploy
# If you encounter any issues with this script, or have suggestions or feature requests,
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh

# ============================================================================
# CONSTANTS
# ============================================================================
readonly TUX2LAB_DATA_DIR="/tux2lab-data"
readonly LAB_CONFIG_DIR="${TUX2LAB_DATA_DIR}/lab-config"
readonly LAB_ENV_JSON="${LAB_CONFIG_DIR}/lab_environment.json"
readonly CERTS_DIR="${LAB_CONFIG_DIR}/certs"
readonly SSH_KEYS_DIR="${LAB_CONFIG_DIR}/ssh-keys"
readonly PROJECT_VERSION=$(jq -r '.version' /tux2lab/project_version.json)
readonly CONTAINER_IMAGE_PRIMARY="ghcr.io/muthukumar-subramaniam/tux2lab-engine:${PROJECT_VERSION}"
readonly CONTAINER_IMAGE_FALLBACK="docker.io/musubram/tux2lab-engine:${PROJECT_VERSION}"
readonly CONTAINER_NAME="tux2lab-engine"
readonly LIBVIRT_NETWORK_NAME="tux2lab"
readonly BRIDGE_INTERFACE="labbr0"
readonly INFRA_HOSTNAME="tux2lab-engine"

# Rebuild mode flag
REBUILD_MODE=false
if [[ "${1:-}" == "--rebuild" ]]; then
    REBUILD_MODE=true
    shift
fi

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================
preflight_checks() {
    print_info "Running pre-flight checks..."

    # Check podman
    if ! command -v podman &>/dev/null; then
        print_warning "podman is not installed. Running setup-host.sh..."
        if [[ -x /tux2lab/setup/setup-host.sh ]]; then
            bash /tux2lab/setup/setup-host.sh --yes || { print_error "setup-host.sh failed."; exit 1; }
        else
            print_error "setup-host.sh not found. Install podman manually."
            exit 1
        fi
    fi

    # Check /tux2lab-data exists
    if [[ ! -d "${TUX2LAB_DATA_DIR}" ]]; then
        print_warning "Directory ${TUX2LAB_DATA_DIR} does not exist. Running setup-host.sh..."
        if [[ -x /tux2lab/setup/setup-host.sh ]]; then
            bash /tux2lab/setup/setup-host.sh --yes || { print_error "setup-host.sh failed."; exit 1; }
        else
            print_error "setup-host.sh not found."
            exit 1
        fi
    fi

    # Check labbr0 bridge exists — auto-recover by running setup-host.sh
    if ! ip link show "${BRIDGE_INTERFACE}" &>/dev/null; then
        print_warning "Bridge ${BRIDGE_INTERFACE} does not exist. Running setup-host.sh to create it..."
        if [[ -x /tux2lab/setup/setup-host.sh ]]; then
            bash /tux2lab/setup/setup-host.sh --yes || {
                print_error "setup-host.sh failed."
                exit 1
            }
        else
            print_error "setup-host.sh not found at /tux2lab/setup/setup-host.sh"
            exit 1
        fi
    fi

    # Check libvirt network exists (for reading network config)
    if ! sudo virsh net-info "${LIBVIRT_NETWORK_NAME}" &>/dev/null 2>&1; then
        print_warning "Libvirt network '${LIBVIRT_NETWORK_NAME}' not found. Running setup-host.sh..."
        if [[ -x /tux2lab/setup/setup-host.sh ]]; then
            bash /tux2lab/setup/setup-host.sh --yes || {
                print_error "setup-host.sh failed."
                exit 1
            }
        else
            print_error "setup-host.sh not found at /tux2lab/setup/setup-host.sh"
            exit 1
        fi
    fi

    # Check jq
    if ! command -v jq &>/dev/null; then
        print_error "jq is not installed."
        print_info "Install jq: sudo dnf install jq (or apt install jq)"
        exit 1
    fi

    # Check for existing deployment
    if [[ -f "${LAB_ENV_JSON}" ]]; then
        print_warning "Existing lab deployment detected: ${LAB_ENV_JSON}"
        print_info "Use 'tux2lab rebuild' to redeploy, or 'tux2lab destroy' to remove."
        exit 0
    fi

    print_info "Pre-flight checks passed."
}

# ============================================================================
# CAPTURE NETWORK CONFIGURATION (from existing labbr0/libvirt network)
# ============================================================================
capture_network_config() {
    print_task "Capturing network configuration from ${BRIDGE_INTERFACE}..."

    local net_xml
    net_xml=$(sudo virsh net-dumpxml "${LIBVIRT_NETWORK_NAME}" 2>/dev/null) || {
        print_task_fail
        print_error "Failed to read network config from libvirt."
        exit 1
    }

    # IPv4 — gateway is the host's IP on labbr0 (also the infra services IP in v2.0.0)
    IPV4_GATEWAY=$(echo "$net_xml" | awk -F"'" '/<ip address=/ {print $2}')
    IPV4_NETMASK=$(echo "$net_xml" | awk -F"'" '/<ip address=/ {print $4}')

    if [[ -z "$IPV4_GATEWAY" || -z "$IPV4_NETMASK" ]]; then
        print_task_fail
        print_error "Failed to extract IPv4 config from libvirt network."
        exit 1
    fi

    # In v2.0.0: services run on the GATEWAY IP (.1) — no separate .2
    IPV4_ADDRESS="${IPV4_GATEWAY}"

    # Calculate CIDR prefix from netmask (count the 1-bits)
    local mask_binary=""
    IFS=. read -r mm1 mm2 mm3 mm4 <<< "$IPV4_NETMASK"
    for octet in $mm1 $mm2 $mm3 $mm4; do
        local val=$octet
        for _ in {1..8}; do
            mask_binary+=$((val / 128))
            val=$(( (val % 128) * 2 ))
        done
    done
    local ones_only="${mask_binary//0/}"
    IPV4_PREFIX="${#ones_only}"

    # Calculate network address
    IFS=. read -r g1 g2 g3 g4 <<< "$IPV4_GATEWAY"
    IFS=. read -r m1 m2 m3 m4 <<< "$IPV4_NETMASK"
    IPV4_NETWORK="$((g1 & m1)).$((g2 & m2)).$((g3 & m3)).$((g4 & m4))"
    IPV4_CIDR="${IPV4_NETWORK}/${IPV4_PREFIX}"

    # Calculate broadcast address
    IPV4_BROADCAST="$((g1 | (255 - m1))).$((g2 | (255 - m2))).$((g3 | (255 - m3))).$((g4 | (255 - m4)))"

    # Calculate first and last /24 subnets within the range
    # (needed by dnsbinder for reverse zones and DHCP range)
    IFS=. read -r n1 n2 n3 n4 <<< "$IPV4_NETWORK"
    IFS=. read -r b1 b2 b3 b4 <<< "$IPV4_BROADCAST"
    IPV4_FIRST24="${n1}.${n2}.${n3}"
    IPV4_LAST24="${b1}.${b2}.${b3}"

    # DHCP range: last 99 IPs (.156-.254) of the last /24 subnet
    DHCP_RANGE_START="${IPV4_LAST24}.156"
    DHCP_RANGE_END="${IPV4_LAST24}.254"

    # IPv6 — ULA from libvirt network
    IPV6_GATEWAY=$(echo "$net_xml" | awk -F"'" '/<ip family=.ipv6/ {print $4}')
    IPV6_PREFIX=$(echo "$net_xml" | awk -F"'" '/<ip family=.ipv6/ {print $6}')

    if [[ -z "$IPV6_GATEWAY" || -z "$IPV6_PREFIX" ]]; then
        print_task_fail
        print_error "IPv6 not configured in libvirt network. Dual-stack required."
        exit 1
    fi

    # In v2.0.0: IPv6 services also on the gateway address (::1)
    IPV6_ADDRESS="${IPV6_GATEWAY}"

    # Extract ULA subnet prefix (e.g., fd28:2808:2020:3000)
    IPV6_PREFIX_BASE=$(echo "$IPV6_GATEWAY" | sed 's/::[^:]*$//')
    IPV6_ULA_SUBNET="${IPV6_PREFIX_BASE}::/${IPV6_PREFIX}"

    print_task_done

    print_info "Network Configuration (Dual-Stack):
  IPv4 Address  : ${IPV4_ADDRESS}
  IPv4 Network  : ${IPV4_CIDR}
  IPv4 Netmask  : ${IPV4_NETMASK}
  IPv4 Broadcast: ${IPV4_BROADCAST}
  First /24     : ${IPV4_FIRST24}.0/24
  Last /24      : ${IPV4_LAST24}.0/24
  DHCP Range    : ${DHCP_RANGE_START} - ${DHCP_RANGE_END}
  IPv6 Address  : ${IPV6_ADDRESS}
  IPv6 Subnet   : ${IPV6_ULA_SUBNET}
  Bridge        : ${BRIDGE_INTERFACE}"
}

# ============================================================================
# COLLECT CREDENTIALS (only user prompt: password)
# ============================================================================
collect_credentials() {
    # Admin username = current user (no prompt)
    ADMIN_USERNAME="$USER"
    ADMIN_DOMAIN="${USER}.internal"
    INFRA_FQDN="${INFRA_HOSTNAME}.${ADMIN_DOMAIN}"

    print_info "Lab Infra Server : ${INFRA_FQDN}"
    print_info "Admin User       : ${ADMIN_USERNAME}"

    print_warning "The following will be configured:
  - Generate SSH keypair for lab access
  - Generate self-signed SSL certificate
  - Generate service configurations (DNS, DHCP, NTP, HTTP, TFTP, NFS)
  - Pull and start tux2lab-engine container (DNS, DHCP, NTP, HTTP, TFTP)
  - Start NFS server on host (bound to lab bridge)
  - Configure host DNS resolution and SSH"
    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_info "Deploy cancelled by user."
        exit 0
    fi

    # Prompt for password
    local password_plain=""
    local confirm_password=""
    while true; do
        read -s -p "Enter your Lab Infra Global password: " password_plain
        echo
        if [[ -z "$password_plain" ]]; then
            print_error "Password cannot be empty."
            continue
        elif [[ ${#password_plain} -lt 8 ]]; then
            print_warning "Password is less than 8 characters."
            read -rp "Are you sure? (y/n): " confirm_weak
            if [[ ! "$confirm_weak" =~ ^[Yy]$ ]]; then
                continue
            fi
        fi

        read -s -p "Re-enter Lab Infra Global password: " confirm_password
        echo
        if [[ "$password_plain" != "$confirm_password" ]]; then
            print_error "Passwords do not match."
            continue
        fi
        break
    done

    # Generate shadow-compatible hash
    local salt
    salt=$(openssl rand -hex 8 | head -c 16)
    ADMIN_PASSWORD_HASH=$(openssl passwd -6 -salt "$salt" "$password_plain")
    unset password_plain confirm_password

    print_info "Credentials ready for user '${ADMIN_USERNAME}'."
}

# ============================================================================
# GENERATE SSH KEYPAIR
# ============================================================================
generate_ssh_keys() {
    print_task "Generating SSH keypair..."

    mkdir -p "${SSH_KEYS_DIR}"
    local key_file="${SSH_KEYS_DIR}/tux2lab_id_rsa"

    if [[ -f "$key_file" ]]; then
        print_task_skip
        print_info "SSH keys already exist at ${SSH_KEYS_DIR}/"
        return
    fi

    ssh-keygen -t rsa -b 4096 -N "" -f "$key_file" -C "${ADMIN_DOMAIN}" &>/dev/null
    cp "${key_file}.pub" "${SSH_KEYS_DIR}/authorized_keys"
    # Lab keys are served via HTTP to VMs — readable by nginx
    chmod 644 "$key_file" "${key_file}.pub" "${SSH_KEYS_DIR}/authorized_keys"

    # Also install on host for SSH access to guest VMs
    local host_ssh_dir="$HOME/.ssh"
    mkdir -p "$host_ssh_dir"
    cp "$key_file" "${host_ssh_dir}/tux2lab_id_rsa"
    cp "${key_file}.pub" "${host_ssh_dir}/tux2lab_id_rsa.pub"
    chmod 600 "${host_ssh_dir}/tux2lab_id_rsa"

    # Add to authorized_keys on host
    local auth_keys="${host_ssh_dir}/authorized_keys"
    touch "$auth_keys" && chmod 600 "$auth_keys"
    if ! grep -qF "$(cat "${key_file}.pub")" "$auth_keys" 2>/dev/null; then
        cat "${key_file}.pub" >> "$auth_keys"
    fi

    print_task_done
    print_info "SSH keys generated at ${SSH_KEYS_DIR}/"
}

# ============================================================================
# GENERATE SSL CERTIFICATE
# ============================================================================
generate_ssl_cert() {
    print_task "Generating SSL certificate..."

    mkdir -p "${CERTS_DIR}"
    local key_file="${CERTS_DIR}/tux2lab-nginx-selfsigned.key"
    local cert_file="${CERTS_DIR}/tux2lab-nginx-selfsigned.crt"

    if [[ -f "$cert_file" && -f "$key_file" ]]; then
        print_task_skip
        print_info "SSL certificate already exists."
        return
    fi

    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:4096 \
        -keyout "$key_file" \
        -out "$cert_file" \
        -subj "/CN=${INFRA_FQDN}" \
        -addext "subjectAltName=DNS:${INFRA_FQDN},DNS:${INFRA_HOSTNAME},IP:${IPV4_ADDRESS},IP:${IPV6_ADDRESS}" \
        &>/dev/null

    chmod 600 "$key_file"
    chmod 644 "$cert_file"

    # Install cert into host CA trust store (so curl/wget work without -k)
    if [[ -d /etc/pki/ca-trust/source/anchors ]]; then
        # RHEL/Fedora/SUSE
        sudo cp "$cert_file" /etc/pki/ca-trust/source/anchors/tux2lab-nginx-selfsigned.crt
        sudo update-ca-trust &>/dev/null
    elif [[ -d /usr/local/share/ca-certificates ]]; then
        # Debian/Ubuntu
        sudo cp "$cert_file" /usr/local/share/ca-certificates/tux2lab-nginx-selfsigned.crt
        sudo update-ca-certificates &>/dev/null
    fi

    print_task_done
    print_info "SSL certificate generated and trusted by host."
}

# ============================================================================
# GENERATE lab_environment.json
# ============================================================================
generate_lab_environment_json() {
    print_task "Generating lab_environment.json..."

    mkdir -p "${LAB_CONFIG_DIR}"

    cat > "${LAB_ENV_JSON}" <<EOF
{
  "lab": {
    "name": "tux2lab",
    "domain": "${ADMIN_DOMAIN}",
    "engine_hostname": "${INFRA_HOSTNAME}",
    "engine_fqdn": "${INFRA_FQDN}"
  },
  "network": {
    "bridge_interface": "${BRIDGE_INTERFACE}",
    "ipv4": {
      "address": "${IPV4_ADDRESS}",
      "network": "${IPV4_NETWORK}",
      "cidr": "${IPV4_CIDR}",
      "netmask": "${IPV4_NETMASK}",
      "prefix": "${IPV4_PREFIX}",
      "gateway": "${IPV4_GATEWAY}",
      "broadcast": "${IPV4_BROADCAST}",
      "first24_subnet": "${IPV4_FIRST24}",
      "last24_subnet": "${IPV4_LAST24}",
      "dhcp_range_start": "${DHCP_RANGE_START}",
      "dhcp_range_end": "${DHCP_RANGE_END}"
    },
    "ipv6": {
      "address": "${IPV6_ADDRESS}",
      "prefix": "${IPV6_PREFIX}",
      "prefix_base": "${IPV6_PREFIX_BASE}",
      "gateway": "${IPV6_GATEWAY}",
      "ula_subnet": "${IPV6_ULA_SUBNET}"
    },
    "upstream_dns": ["8.8.8.8", "2001:4860:4860::8888", "1.1.1.1", "2606:4700:4700::1111"]
  },
  "admin": {
    "username": "${ADMIN_USERNAME}",
    "password_hash": "${ADMIN_PASSWORD_HASH}",
    "shell": "/bin/bash"
  },
  "rhel": {
    "org_id": "",
    "activation_key": ""
  }
}
EOF

    chmod 644 "${LAB_ENV_JSON}"
    print_task_done
    print_info "Lab environment written to ${LAB_ENV_JSON}"

    # Generate compatibility vars file for ksmanager/prepare-distro (legacy format)
    print_task "Generating compatibility lab_environment_vars..."
    cat > "${TUX2LAB_DATA_DIR}/lab_environment_vars" <<EOVARS
# Auto-generated from lab_environment.json — do not edit manually
lab_infra_server_hostname="${INFRA_FQDN}"
lab_infra_domain_name="${ADMIN_DOMAIN}"
lab_infra_admin_username="${ADMIN_USERNAME}"
lab_admin_shadow_password='${ADMIN_PASSWORD_HASH}'
lab_infra_server_ipv4_address="${IPV4_ADDRESS}"
lab_infra_server_ipv6_address="${IPV6_ADDRESS}"
lab_infra_server_ipv4_gateway="${IPV4_GATEWAY}"
lab_infra_server_ipv6_gateway="${IPV6_GATEWAY}"
lab_infra_server_ipv4_subnet="${IPV4_CIDR}"
lab_infra_server_ipv4_netmask="${IPV4_NETMASK}"
lab_infra_server_ipv6_prefix="${IPV6_PREFIX}"
lab_infra_server_ipv6_ula_subnet="${IPV6_ULA_SUBNET}"
dnsbinder_domain="${ADMIN_DOMAIN}"
dnsbinder_server_ipv4_address="${IPV4_ADDRESS}"
dnsbinder_server_ipv6_address="${IPV6_ADDRESS}"
dnsbinder_server_fqdn="${INFRA_FQDN}"
dnsbinder_gateway="${IPV4_GATEWAY}"
dnsbinder_network_cidr="${IPV4_CIDR}"
dnsbinder_cidr_prefix="${IPV4_PREFIX}"
dnsbinder_netmask="${IPV4_NETMASK}"
dnsbinder_first24_subnet="${IPV4_FIRST24}"
dnsbinder_last24_subnet="${IPV4_LAST24}"
dnsbinder_ipv6_gateway="${IPV6_GATEWAY}"
dnsbinder_ipv6_prefix="${IPV6_PREFIX}"
dnsbinder_ipv6_ula_subnet="${IPV6_ULA_SUBNET}"
mgmt_super_user="${ADMIN_USERNAME}"
EOVARS
    chmod 644 "${TUX2LAB_DATA_DIR}/lab_environment_vars"
    print_task_done
}

# ============================================================================
# GENERATE SERVICE CONFIGS
# ============================================================================
generate_service_configs() {
    print_info "Generating service configurations..."

    if [[ -x /tux2lab/setup/generate-service-configs.sh ]]; then
        bash /tux2lab/setup/generate-service-configs.sh
    else
        print_warning "Config generator not yet implemented — skipping."
        print_info "Service configs will need to be created manually for testing."
    fi
}

# ============================================================================
# SETUP DNS (calls dnsbinder --setup)
# ============================================================================
setup_dns() {
    print_info "Setting up DNS with dnsbinder..."

    if [[ -x /tux2lab/named-manage/dnsbinder.sh ]]; then
        sudo bash /tux2lab/named-manage/dnsbinder.sh --setup "${ADMIN_DOMAIN}" || {
            print_error "Failed to setup DNS with dnsbinder."
            exit 1
        }
    else
        print_warning "dnsbinder not found — skipping DNS setup."
        return
    fi

    # Pre-populate DNS records for DHCP pool IPs (needed for NFS ACL reverse-lookup)
    if dig @"${IPV4_ADDRESS}" +short +time=1 +tries=1 A "dhcp-lease156.${ADMIN_DOMAIN}" 2>/dev/null | grep -q '^[0-9]'; then
        print_info "DHCP lease DNS records already exist — skipping."
    else
        print_task "Creating DNS records for DHCP pool (156-254)..."
        local dhcp_lease_file
        dhcp_lease_file="$(mktemp /tmp/dhcp-lease-records.XXXXXXXXXX)"
        for octet in $(seq 156 254); do
            echo "dhcp-lease${octet} ${IPV4_LAST24}.${octet}" >> "$dhcp_lease_file"
        done
        sudo bash /tux2lab/named-manage/dnsbinder.sh -cify --inline "$dhcp_lease_file" &>/dev/null || true
        rm -f "$dhcp_lease_file"
        print_task_done
    fi
}

# ============================================================================
# ENSURE BRIDGE IS UP
# ============================================================================
source /tux2lab/shared-functions/lablink0.sh

ensure_bridge_up() {
    # Validate bridge exists and has IPs
    if ! ip link show "${BRIDGE_INTERFACE}" &>/dev/null; then
        print_error "Bridge ${BRIDGE_INTERFACE} does not exist."
        exit 1
    fi
    if ! ip -4 addr show dev "${BRIDGE_INTERFACE}" 2>/dev/null | grep -q "inet "; then
        print_error "No IPv4 address on ${BRIDGE_INTERFACE}."
        exit 1
    fi
    if ! ip -6 addr show dev "${BRIDGE_INTERFACE}" 2>/dev/null | grep -q "inet6.*scope global"; then
        print_error "No IPv6 address on ${BRIDGE_INTERFACE}."
        exit 1
    fi

    ensure_lablink0 "${BRIDGE_INTERFACE}"

    # Open bridge firewall if host has restrictive iptables
    source /tux2lab/shared-functions/bridge-firewall.sh
    open_bridge_firewall "${BRIDGE_INTERFACE}"
}

# ============================================================================
# START CONTAINER
# ============================================================================
start_container() {
    print_task "Pulling tux2lab-engine container image..."

    # Try primary registry (ghcr.io), fallback to Docker Hub
    local container_image=""
    local pull_start=$SECONDS
    local pull_log
    pull_log=$(mktemp)

    sudo podman pull "${CONTAINER_IMAGE_PRIMARY}" &>"$pull_log" &
    local pull_pid=$!
    local pull_elapsed=0
    while kill -0 "$pull_pid" 2>/dev/null; do
        printf "\r${MAKE_IT_CYAN}[TASK] Pulling tux2lab-engine container image [%dm %ds]...${RESET_COLOR}\033[K" $((pull_elapsed/60)) $((pull_elapsed%60))
        sleep 1
        pull_elapsed=$((SECONDS - pull_start))
    done

    if wait "$pull_pid"; then
        container_image="${CONTAINER_IMAGE_PRIMARY}"
        pull_elapsed=$((SECONDS - pull_start))
        printf "\r\033[K"
        printf "${MAKE_IT_CYAN}[TASK] Pulling tux2lab-engine container image (%dm %ds)...${RESET_COLOR}" $((pull_elapsed/60)) $((pull_elapsed%60))
        print_task_done
    else
        # Fallback to Docker Hub
        pull_start=$SECONDS
        sudo podman pull "${CONTAINER_IMAGE_FALLBACK}" &>"$pull_log" &
        pull_pid=$!
        pull_elapsed=0
        while kill -0 "$pull_pid" 2>/dev/null; do
            printf "\r${MAKE_IT_CYAN}[TASK] Pulling tux2lab-engine container image [%dm %ds]...${RESET_COLOR}\033[K" $((pull_elapsed/60)) $((pull_elapsed%60))
            sleep 1
            pull_elapsed=$((SECONDS - pull_start))
        done

        if wait "$pull_pid"; then
            container_image="${CONTAINER_IMAGE_FALLBACK}"
            pull_elapsed=$((SECONDS - pull_start))
            printf "\r\033[K"
            printf "${MAKE_IT_CYAN}[TASK] Pulling tux2lab-engine container image (%dm %ds)...${RESET_COLOR}" $((pull_elapsed/60)) $((pull_elapsed%60))
            print_task_done
            print_info "Using fallback registry (Docker Hub)."
        else
            printf "\r\033[K"
            print_task "Pulling tux2lab-engine container image..."
            print_task_fail
            print_error "Failed to pull container image from both registries."
            print_info "  Primary:  ${CONTAINER_IMAGE_PRIMARY}"
            print_info "  Fallback: ${CONTAINER_IMAGE_FALLBACK}"
            rm -f "$pull_log"
            exit 1
        fi
    fi
    rm -f "$pull_log"

    print_task "Starting tux2lab-engine container..."
    local start_begin=$SECONDS

    (
        # Remove existing container if present (from failed previous run)
        if sudo podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
            sudo podman rm -f "${CONTAINER_NAME}" &>/dev/null || true
        fi
        source /tux2lab/shared-functions/run-container.sh
        run_tux2lab_container "${CONTAINER_NAME}" "${container_image}" "${INFRA_FQDN}" "${TUX2LAB_DATA_DIR}" "${IPV4_ADDRESS}" "${BRIDGE_INTERFACE}"
    ) &
    local run_pid=$!

    # Live timer while container is being created
    local start_elapsed=0
    while kill -0 "$run_pid" 2>/dev/null; do
        printf "\r${MAKE_IT_CYAN}[TASK] Starting tux2lab-engine container [%dm %ds]...${RESET_COLOR}\033[K" $((start_elapsed/60)) $((start_elapsed%60))
        sleep 1
        start_elapsed=$((SECONDS - start_begin))
    done
    wait "$run_pid" || true

    # Verify container is up
    sleep 1
    start_elapsed=$((SECONDS - start_begin))
    if sudo podman ps --filter "name=${CONTAINER_NAME}" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
        printf "\r\033[K"
        printf "${MAKE_IT_CYAN}[TASK] Starting tux2lab-engine container (%dm %ds)...${RESET_COLOR}" $((start_elapsed/60)) $((start_elapsed%60))
        print_task_done
        print_info "Container '${CONTAINER_NAME}' is running."
    else
        printf "\r\033[K"
        print_task "Starting tux2lab-engine container..."
        print_task_fail
        print_error "Container failed to start. Check logs:"
        print_info "  sudo podman logs ${CONTAINER_NAME}"
        exit 1
    fi
}

# ============================================================================
# CONFIGURE HOST DNS RESOLUTION
# ============================================================================
configure_host_dns() {
    print_task "Configuring DNS resolution on host..."

    # Add /etc/hosts entry (needed before DNS container is running)
    local hosts_entry="${IPV4_ADDRESS} ${INFRA_FQDN} ${INFRA_HOSTNAME}"
    if ! grep -qF "${INFRA_FQDN}" /etc/hosts 2>/dev/null; then
        echo "${hosts_entry}" | sudo tee -a /etc/hosts &>/dev/null
    fi
    # IPv6 entry
    local hosts_entry_v6="${IPV6_ADDRESS} ${INFRA_FQDN} ${INFRA_HOSTNAME}"
    if ! grep -qF "${IPV6_ADDRESS}" /etc/hosts 2>/dev/null; then
        echo "${hosts_entry_v6}" | sudo tee -a /etc/hosts &>/dev/null
    fi

    # Configure resolvectl to use our DNS for the lab domain
    if command -v resolvectl &>/dev/null; then
        sudo resolvectl dns "${BRIDGE_INTERFACE}" "${IPV4_ADDRESS}" "${IPV6_ADDRESS}" 2>/dev/null || true
        sudo resolvectl domain "${BRIDGE_INTERFACE}" "${ADMIN_DOMAIN}" 2>/dev/null || true
    fi

    print_task_done
}

# ============================================================================
# CONFIGURE HOST SSH
# ============================================================================
configure_host_ssh() {
    print_task "Configuring SSH for lab domain..."

    # Calculate subnet wildcard patterns (all /24s within the network range)
    local ssh_host_patterns="*.${ADMIN_DOMAIN}"
    IFS=. read -r n1 n2 n3 _ <<< "$IPV4_NETWORK"
    IFS=. read -r _ _ b3 _ <<< "$IPV4_BROADCAST"
    for octet3 in $(seq "$n3" "$b3"); do
        ssh_host_patterns+=" ${n1}.${n2}.${octet3}.*"
    done

    local ssh_config_dir="$HOME/.ssh"
    local ssh_config_file="${ssh_config_dir}/config.d/tux2lab.conf"

    mkdir -p "${ssh_config_dir}/config.d"

    cat > "$ssh_config_file" <<EOF
Host ${ssh_host_patterns}
  IdentityFile ~/.ssh/tux2lab_id_rsa
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel QUIET
EOF

    chmod 644 "$ssh_config_file"

    # Ensure main ssh_config includes config.d
    local main_config="${ssh_config_dir}/config"
    if [[ ! -f "$main_config" ]] || ! grep -q "Include.*config.d" "$main_config" 2>/dev/null; then
        echo "Include ${ssh_config_dir}/config.d/*" | cat - "$main_config" 2>/dev/null > "${main_config}.tmp" || \
            echo "Include ${ssh_config_dir}/config.d/*" > "${main_config}.tmp"
        mv "${main_config}.tmp" "$main_config"
        chmod 600 "$main_config"
    fi

    print_task_done
}

# ============================================================================
# REBUILD MODE (non-interactive — uses existing lab_environment.json)
# ============================================================================
rebuild_lab() {
    print_info "Rebuilding lab using existing configuration..."

    if [[ ! -f "${LAB_ENV_JSON}" ]]; then
        print_error "Lab environment file not found at ${LAB_ENV_JSON}"
        print_info "Cannot rebuild without existing configuration."
        print_info "Run 'tux2lab deploy' to create a new lab from scratch."
        exit 1
    fi

    # Basic pre-flight checks for rebuild
    if ! command -v podman &>/dev/null; then
        print_error "podman is not installed."
        exit 1
    fi
    if ! ip link show "${BRIDGE_INTERFACE}" &>/dev/null; then
        print_error "Bridge ${BRIDGE_INTERFACE} is not available. Is the host network up?"
        exit 1
    fi

    # Read values from existing JSON
    IPV4_ADDRESS=$(jq -r '.network.ipv4.address' "${LAB_ENV_JSON}")
    IPV6_ADDRESS=$(jq -r '.network.ipv6.address' "${LAB_ENV_JSON}")
    ADMIN_DOMAIN=$(jq -r '.lab.domain' "${LAB_ENV_JSON}")
    INFRA_FQDN=$(jq -r '.lab.engine_fqdn' "${LAB_ENV_JSON}")

    print_info "Rebuild configuration:
  Hostname  : ${INFRA_FQDN}
  Domain    : ${ADMIN_DOMAIN}
  IPv4      : ${IPV4_ADDRESS}
  IPv6      : ${IPV6_ADDRESS}"

    # Stop and remove existing container
    print_task "Stopping existing container..."
    if sudo podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
        sudo podman stop "${CONTAINER_NAME}" &>/dev/null || true
        sudo podman rm -f "${CONTAINER_NAME}" &>/dev/null || true
        print_task_done
    else
        print_task_skip
    fi

    # Regenerate service configs
    generate_service_configs

    # Ensure bridge is UP and start container
    ensure_bridge_up
    start_container
    source /tux2lab/shared-functions/host-nfs.sh
    start_host_nfs "${IPV4_ADDRESS}" "${IPV6_ADDRESS}"

    # Health check
    print_info "Running health check..."
    if [[ -x /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/health.sh ]]; then
        /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/health.sh || true
    fi

    print_green "═══════════════════════════════════════════════════════════════════
  Lab infrastructure rebuilt successfully!
═══════════════════════════════════════════════════════════════════"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    # Handle rebuild mode (non-interactive)
    if $REBUILD_MODE; then
        rebuild_lab
        exit 0
    fi

    print_green "═══════════════════════════════════════════════════════════════════
  tux2lab — Lab Infrastructure Deployment
═══════════════════════════════════════════════════════════════════"

    preflight_checks
    capture_network_config
    collect_credentials
    generate_ssh_keys
    generate_ssl_cert
    generate_lab_environment_json
    generate_service_configs
    setup_dns
    ensure_bridge_up
    start_container
    source /tux2lab/shared-functions/host-nfs.sh
    start_host_nfs "${IPV4_ADDRESS}" "${IPV6_ADDRESS}"
    configure_host_dns
    configure_host_ssh

    # Run health check
    print_info "Running health check..."
    if [[ -x /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/health.sh ]]; then
        /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/health.sh || true
    fi

    print_green "═══════════════════════════════════════════════════════════════════
  Lab Infrastructure deployed successfully!
═══════════════════════════════════════════════════════════════════
  Hostname  : ${INFRA_FQDN}
  Domain    : ${ADMIN_DOMAIN}
  Admin     : ${ADMIN_USERNAME}
  IPv4      : ${IPV4_ADDRESS}
  IPv6      : ${IPV6_ADDRESS}
  Container : ${CONTAINER_NAME}
═══════════════════════════════════════════════════════════════════"
}

main "$@"
