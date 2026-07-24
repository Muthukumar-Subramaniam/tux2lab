#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: credentials.sh                                                            #
# Description: Manage lab credentials (password, SSH keys, CA cert, RHEL subscription)   #
# Invoked by : tux2lab credentials <subcommand>                                          #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh

readonly LAB_CONFIG_DIR="/tux2lab-data/lab-config"

print_sync_info() {
    print_cyan "Change will propagate to all running VMs within 5 minutes,
or invoke immediately from any VM with: tux2lab-sync"
}

show_credentials_help() {
    print_cyan "USAGE:
    tux2lab credentials <command>
    tux2lab credentials -h

DESCRIPTION:
    Manage lab credentials that are synced to all VMs. Changes propagate
    automatically within 5 minutes via the tux2lab-sync agent on each VM.

COMMANDS:
    password             Change the lab-wide global password
    ssh-keys             Rotate SSH keypair and authorized_keys
    cert                 Renew the self-signed SSL certificate
    rhel-subscription    Update RHEL organization ID and activation key
    show                 Display current credentials status
    -h, --help           Show this help message

EXAMPLES:
    tux2lab credentials show
    tux2lab credentials password
    tux2lab credentials ssh-keys
    tux2lab credentials cert
    tux2lab credentials rhel-subscription"
}

credentials_show() {
    print_cyan "Lab Credentials Status"
    print_cyan "Any changes made here will propagate to all running VMs within 5 minutes."
    printf "${MAKE_IT_CYAN}%s${RESET_COLOR}\n" "------------------------------------------------------------------------"

    # Password hash
    if [[ -f "${LAB_CONFIG_DIR}/shadow-hash" ]]; then
        printf "Password hash:        ${MAKE_IT_GREEN}configured${RESET_COLOR}\n"
    else
        printf "Password hash:        ${MAKE_IT_YELLOW}not set${RESET_COLOR}\n"
    fi

    # SSH keys
    if [[ -f "${LAB_CONFIG_DIR}/ssh-keys/tux2lab_id_rsa" ]]; then
        local fingerprint
        fingerprint=$(ssh-keygen -lf "${LAB_CONFIG_DIR}/ssh-keys/tux2lab_id_rsa.pub" 2>/dev/null | awk '{print $2}') || fingerprint="unknown"
        printf "SSH key fingerprint:  ${MAKE_IT_GREEN}${fingerprint}${RESET_COLOR}\n"
    else
        printf "SSH keys:             ${MAKE_IT_YELLOW}not generated${RESET_COLOR}\n"
    fi

    # CA certificate
    if [[ -f "${LAB_CONFIG_DIR}/certs/tux2lab-nginx-selfsigned.crt" ]]; then
        local expires
        expires=$(openssl x509 -enddate -noout -in "${LAB_CONFIG_DIR}/certs/tux2lab-nginx-selfsigned.crt" 2>/dev/null | cut -d= -f2) || expires="unknown"
        printf "CA certificate:       ${MAKE_IT_GREEN}expires ${expires}${RESET_COLOR}\n"
    else
        printf "CA certificate:       ${MAKE_IT_YELLOW}not generated${RESET_COLOR}\n"
    fi

    # RHEL subscription
    if [[ -f "${LAB_CONFIG_DIR}/rhel-subscription.conf" ]]; then
        local org_id
        org_id=$(grep "RHEL_ORG_ID=" "${LAB_CONFIG_DIR}/rhel-subscription.conf" | cut -d= -f2)
        printf "RHEL subscription:    ${MAKE_IT_GREEN}configured (org: ${org_id})${RESET_COLOR}\n"
    else
        printf "RHEL subscription:    ${MAKE_IT_YELLOW}not configured${RESET_COLOR}\n"
    fi
}

credentials_password() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        exec tux2lab credentials --help
    fi
    local admin_user
    admin_user=$(jq -r '.admin.username' /tux2lab-data/lab-config/lab_environment.json 2>/dev/null) || admin_user="$USER"
    print_cyan "This sets the lab-wide global password for 'root' and '${admin_user}' on all VMs."
    read -rp "Continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_cyan "Aborted."
        exit 0
    fi
    read -rsp "Enter new password: " new_password
    echo ""
    read -rsp "Confirm new password: " confirm_password
    echo ""

    if [[ "$new_password" != "$confirm_password" ]]; then
        print_error "Passwords do not match."
        exit 1
    fi

    if [[ -z "$new_password" ]]; then
        print_error "Password cannot be empty."
        exit 1
    fi

    local hash
    hash=$(openssl passwd -6 "$new_password")
    echo -n "$hash" > "${LAB_CONFIG_DIR}/shadow-hash"
    chmod 644 "${LAB_CONFIG_DIR}/shadow-hash"
    # Update lab_environment.json (source of truth for deploy/rebuild)
    local lab_env_json="${LAB_CONFIG_DIR}/lab_environment.json"
    if [[ -f "$lab_env_json" ]]; then
        jq --arg hash "$hash" '.admin.password_hash = $hash' "$lab_env_json" > "${lab_env_json}.tmp" \
            && mv "${lab_env_json}.tmp" "$lab_env_json"
    fi
    print_success "Password updated."
    print_sync_info
}

credentials_ssh_keys() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        exec tux2lab credentials --help
    fi
    print_yellow "This will generate a new tux2lab SSH keypair (tux2lab_id_rsa) and replace the existing one."
    print_cyan "The new keypair will be synced to all running VMs within 5 minutes."
    read -rp "Continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_cyan "Aborted."
        exit 0
    fi

    local ssh_dir="${LAB_CONFIG_DIR}/ssh-keys"
    local lab_domain
    lab_domain=$(jq -r '.lab.domain' /tux2lab-data/lab-config/lab_environment.json 2>/dev/null) || lab_domain="tux2lab"
    mkdir -p "$ssh_dir"

    # Generate new keypair with lab domain as comment
    rm -f "${ssh_dir}/tux2lab_id_rsa" "${ssh_dir}/tux2lab_id_rsa.pub"
    ssh-keygen -t ed25519 -f "${ssh_dir}/tux2lab_id_rsa" -N "" -C "${lab_domain}" -q
    cp "${ssh_dir}/tux2lab_id_rsa.pub" "${ssh_dir}/authorized_keys"
    chmod 644 "${ssh_dir}/authorized_keys" "${ssh_dir}/tux2lab_id_rsa.pub" "${ssh_dir}/tux2lab_id_rsa"

    # Update host SSH keys for admin user
    local admin_user
    admin_user=$(jq -r '.admin.username' /tux2lab-data/lab-config/lab_environment.json 2>/dev/null) || admin_user="$USER"
    mkdir -p "/home/${admin_user}/.ssh"
    cp "${ssh_dir}/tux2lab_id_rsa" "/home/${admin_user}/.ssh/"
    cp "${ssh_dir}/tux2lab_id_rsa.pub" "/home/${admin_user}/.ssh/"
    # Smart update authorized_keys: replace existing lab key or append if not present
    local new_pubkey
    new_pubkey=$(cat "${ssh_dir}/tux2lab_id_rsa.pub")
    local auth_file="/home/${admin_user}/.ssh/authorized_keys"
    if [[ -f "$auth_file" ]]; then
        sed -i "/ ${lab_domain}$/d" "$auth_file"
    fi
    echo "$new_pubkey" >> "$auth_file"
    chmod 600 "/home/${admin_user}/.ssh/tux2lab_id_rsa"
    chmod 644 "/home/${admin_user}/.ssh/tux2lab_id_rsa.pub" "$auth_file"
    chown -R "${admin_user}:$(id -g "$admin_user")" "/home/${admin_user}/.ssh"

    print_success "SSH keys rotated."
    local fingerprint
    fingerprint=$(ssh-keygen -lf "${ssh_dir}/tux2lab_id_rsa.pub" | awk '{print $2}')
    print_cyan "New fingerprint: ${fingerprint}"
    print_sync_info
}

credentials_cert() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        exec tux2lab credentials --help
    fi
    print_yellow "This will generate a new self-signed SSL certificate for the tux2lab-engine HTTPS server."
    print_cyan "Nginx on the tux2lab-engine container will be reloaded to use the new certificate."
    print_cyan "All VMs will trust the new cert within 5 minutes."
    read -rp "Continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_cyan "Aborted."
        exit 0
    fi

    local cert_dir="${LAB_CONFIG_DIR}/certs"
    local lab_fqdn
    lab_fqdn=$(jq -r '.lab.engine_fqdn' /tux2lab-data/lab-config/lab_environment.json 2>/dev/null) || lab_fqdn="tux2lab-engine"
    local domain
    domain=$(jq -r '.lab.domain' /tux2lab-data/lab-config/lab_environment.json 2>/dev/null) || domain="internal"

    mkdir -p "$cert_dir"
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "${cert_dir}/tux2lab-nginx-selfsigned.key" \
        -out "${cert_dir}/tux2lab-nginx-selfsigned.crt" \
        -subj "/CN=${lab_fqdn}" \
        -addext "subjectAltName=DNS:${lab_fqdn},DNS:*.${domain}" \
        2>/dev/null

    chmod 644 "${cert_dir}/tux2lab-nginx-selfsigned.crt"
    chmod 600 "${cert_dir}/tux2lab-nginx-selfsigned.key"

    # Restart nginx to pick up new cert
    local container_name="tux2lab-engine"
    if sudo podman exec "${container_name}" nginx -s reload &>/dev/null; then
        print_cyan "Nginx reloaded with new certificate."
    else
        print_yellow "Could not reload nginx. Restart the container: tux2lab rebuild"
    fi

    # Update host CA trust
    if command -v update-ca-trust &>/dev/null; then
        sudo cp "${cert_dir}/tux2lab-nginx-selfsigned.crt" /etc/pki/ca-trust/source/anchors/ 2>/dev/null || true
        sudo update-ca-trust 2>/dev/null || true
    elif command -v update-ca-certificates &>/dev/null; then
        sudo cp "${cert_dir}/tux2lab-nginx-selfsigned.crt" /usr/local/share/ca-certificates/ 2>/dev/null || true
        sudo update-ca-certificates 2>/dev/null || true
    fi

    local expires
    expires=$(openssl x509 -enddate -noout -in "${cert_dir}/tux2lab-nginx-selfsigned.crt" | cut -d= -f2)
    print_success "Certificate renewed. Expires: ${expires}"
    print_sync_info
}

credentials_rhel_subscription() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        exec tux2lab credentials --help
    fi
    if [[ -f "${LAB_CONFIG_DIR}/rhel-subscription.conf" ]]; then
        local current_org
        current_org=$(grep "RHEL_ORG_ID=" "${LAB_CONFIG_DIR}/rhel-subscription.conf" | cut -d= -f2)
        print_cyan "Current: Org ID: ${current_org}, Activation Key: (configured)"
    fi
    print_cyan "Enter new RHEL subscription credentials."
    print_cyan "Get them from: https://console.redhat.com/settings/connector/activation-keys"
    read -rp "Organization ID: " org_id
    if [[ -z "$org_id" ]]; then
        print_error "Organization ID is required."
        exit 1
    fi
    read -rp "Activation Key: " activation_key
    if [[ -z "$activation_key" ]]; then
        print_error "Activation Key is required."
        exit 1
    fi

    cat > "${LAB_CONFIG_DIR}/rhel-subscription.conf" << EOF
# RHEL Subscription Manager credentials for PXE kickstart installs
# Updated by: tux2lab credentials rhel-subscription
RHEL_ORG_ID=${org_id}
RHEL_ACTIVATION_KEY=${activation_key}
EOF
    chmod 644 "${LAB_CONFIG_DIR}/rhel-subscription.conf"
    print_success "RHEL subscription credentials updated."
    print_sync_info
}

# ====== DISPATCH ======

if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_credentials_help
    exit 0
fi

case "$1" in
    show)
        credentials_show
        ;;
    password)
        shift; credentials_password "$@"
        ;;
    ssh-keys)
        shift; credentials_ssh_keys "$@"
        ;;
    cert)
        shift; credentials_cert "$@"
        ;;
    rhel-subscription)
        shift; credentials_rhel_subscription "$@"
        ;;
    *)
        print_error "Unknown command: $1"
        echo
        show_credentials_help
        exit 1
        ;;
esac
