#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
# Script Name : deploy-lab-infra-server.sh
# Description : Interactive script to deploy the Lab Infra Server
#               on either a dedicated KVM VM or directly on the KVM host.

set -euo pipefail
IFS=$'\n\t'

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/ks-manage/distro-versions.conf

if [[ -z "${INFRA_SERVER_VERSION:-}" ]]; then
    echo "[ERROR] INFRA_SERVER_VERSION not defined in distro-versions.conf"
    exit 1
fi

# Internal flag: --rebuild is used by 'tux2lab rebuild' to redeploy
# using the existing environment file without interactive prompts.
REBUILD_MODE=false
if [[ "${1:-}" == "--rebuild" ]]; then
    REBUILD_MODE=true
    shift
fi

# Check if lab environment is already deployed
check_existing_lab_deployment() {
    local LAB_ENV_FILE="/tux2lab-data/lab_environment_vars"
    local found_issues=0
  
    print_info "Checking for existing lab deployment..."
  
    # Check if lab environment file exists
    if [[ -f "$LAB_ENV_FILE" ]]; then
        print_warning "Found existing lab environment configuration at: $LAB_ENV_FILE"
        found_issues=1
    
        # Source the file to get existing values
        source "$LAB_ENV_FILE"
    
        if [[ -n "${lab_infra_server_hostname:-}" ]]; then
            print_warning "Lab Infra Server appears to be already configured:" nskip
            print_warning "  Hostname: ${lab_infra_server_hostname}"
      
            # Check if it's a VM deployment
            if [[ "${lab_infra_server_mode_is_host:-false}" == "false" ]]; then
                # Check if VM exists
                if sudo virsh list --all | grep -q "${lab_infra_server_hostname}"; then
                    print_warning "  VM Status: EXISTS (running or stopped)"
                    found_issues=2
                fi
        
                # Check if VM disk exists
                local VM_DIR="/tux2lab-data/vms/${lab_infra_server_hostname}"
                if [[ -d "$VM_DIR" ]]; then
                    print_warning "  VM Directory: EXISTS at $VM_DIR"
                    found_issues=2
                fi
            else
                # Check if host-mode services are running
                print_warning "  Mode: HOST (deployed directly on KVM host)"
                if sudo systemctl is-active --quiet named; then
                    print_warning "  DNS Service (named): ACTIVE"
                    found_issues=2
                fi
                if sudo systemctl is-active --quiet kea-dhcp4; then
                    print_warning "  DHCP Service (kea): ACTIVE"
                    found_issues=2
                fi
            fi
        fi
    fi
  
    # Check for SSH keys
    if [[ -f "$HOME/.ssh/tux2lab_id_rsa" ]]; then
        print_warning "Lab SSH keys already exist at: $HOME/.ssh/tux2lab_id_rsa"
        found_issues=1
    fi
  
    # Check for SSH config
    if [[ -f "/etc/ssh/ssh_config.d/999-tux2lab.conf" ]]; then
        print_warning "Lab SSH config already exists: /etc/ssh/ssh_config.d/999-tux2lab.conf"
        found_issues=1
    fi
  
    if [[ $found_issues -eq 2 ]]; then
        print_red "═══════════════════════════════════════════════════════════════════
CRITICAL: Lab infrastructure is already deployed!
Re-running this script will OVERWRITE your existing setup.
═══════════════════════════════════════════════════════════════════"
    
        print_yellow "If you want to redeploy from scratch, you must:
    1. Backup any important data from your lab
    2. Manually remove the existing deployment:
        • Delete VM: sudo virsh destroy ${lab_infra_server_hostname:-tux2lab-engine}
                     sudo virsh undefine ${lab_infra_server_hostname:-tux2lab-engine} --nvram
                     sudo rm -rf /tux2lab-data/vms/${lab_infra_server_hostname:-tux2lab-engine}
        • Or stop host services: sudo systemctl stop named kea-dhcp4 nginx
    3. Remove lab config: sudo rm -rf /tux2lab-data/lab_environment_vars
    4. Remove SSH keys: rm -f ~/.ssh/tux2lab_id_rsa*"
    
        read -rp "Do you understand the risks and want to FORCE re-deployment? (YES/NO): " force_confirm
    
        if [[ "$force_confirm" != "YES" ]]; then
            print_info "Deployment cancelled. Your existing lab is safe."
            exit 0
        fi
    
        print_warning "Proceeding with FORCED re-deployment..."
        sleep 2
    elif [[ $found_issues -eq 1 ]]; then
        print_warning "Some lab components already exist.
Continuing may overwrite existing SSH keys or configuration."
    
        read -rp "Type 'OVERWRITE' to continue with deployment: " continue_confirm
    
        if [[ "$continue_confirm" != "OVERWRITE" ]]; then
            print_info "Deployment cancelled."
            exit 0
        fi
    
        print_warning "Proceeding with deployment..."
        sleep 1
    else
        print_info "No existing lab deployment detected. Safe to proceed."
    fi
}

prepare_lab_infra_config() {
    print_info "Preparing general Lab Infra configuration..."
    local vendored_virt_manager_dir="/tux2lab/vendor/virt-manager"

    # Pre-flight environment checks
    if [[ ! -d "${vendored_virt_manager_dir}/virtinst" || ! -f "${vendored_virt_manager_dir}/virt-install" ]]; then
        print_error "Vendored virt-manager files not found at ${vendored_virt_manager_dir}!"
        print_info "Please install and set up QEMU/KVM first."
        print_info "Run the script \033[1msetup-qemu-kvm.sh\033[0m to configure your environment."
        exit 1
    fi

    if [[ ! -d /tux2lab-data ]]; then
        print_error "Directory /tux2lab-data does not exist."
        print_warning "Seems like your QEMU/KVM environment is not yet setup."
        print_info "Run the script \033[1msetup-qemu-kvm.sh\033[0m to configure your environment."
        exit 1
    fi

    print_info "Pre-flight checks passed: QEMU/KVM environment is ready."

    # Fixed server name and domain — deterministic, no user prompt needed
    lab_infra_server_shortname="tux2lab-engine"
    lab_infra_domain_name="${USER}.internal"
    lab_infra_server_hostname="${lab_infra_server_shortname}.${lab_infra_domain_name}"

    print_info "Lab Infra Server Hostname: \033[1m${lab_infra_server_hostname}\033[0m"

    lab_infra_admin_username="$USER"
    print_info "Using current user '${lab_infra_admin_username}' as Lab Infra Global user."

    # Prompt for password, validate length, confirm match
    while true; do
        echo
        read -s -p "Enter your Lab Infra Global password: " lab_admin_password_plain
        echo
        if [[ -z "$lab_admin_password_plain" ]]; then
            print_error "Password cannot be empty. Please try again."
            continue
        elif [[ ${#lab_admin_password_plain} -lt 8 ]]; then
            print_warning "Password is less than 8 characters!"
            read -rp "Are you sure you want to proceed? (y/n): " confirm_weak
            if [[ ! "$confirm_weak" =~ ^[Yy]$ ]]; then
                print_error "Aborting. Please enter a stronger password."
                continue
            fi
        fi

        echo
        read -s -p "Re-enter your Lab Infra Global password: " confirm_password
        echo
        if [[ "$lab_admin_password_plain" != "$confirm_password" ]]; then
            print_error "Passwords do not match. Please try again."
            continue
        fi

        break
    done

    # Generate a random salt using only portable crypt-safe characters [a-zA-Z0-9./]
    lab_admin_password_salt=$(openssl rand -hex 8 | head -c 16)

    # Generate SHA-512 shadow-compatible hash
    lab_admin_shadow_password=$(openssl passwd -6 -salt "$lab_admin_password_salt" "$lab_admin_password_plain")

    print_info "Infra Management user credentials are ready for user: \033[1m${lab_infra_admin_username}\033[0m"

    # SSH public key logic
    print_info "Checking for SSH public key on local workstation..."

    SSH_DIR="$HOME/.ssh"
    SSH_PRIVATE_KEY_FILE="$SSH_DIR/tux2lab_id_rsa"
    SSH_PUB_KEY_FILE="$SSH_DIR/tux2lab_id_rsa.pub"

    # Ensure ~/.ssh directory exists
    if [[ ! -d "$SSH_DIR" ]]; then
        print_info ".ssh directory not found. Creating..."
        mkdir -p "$SSH_DIR"
        chmod 700 "$SSH_DIR"
    fi

    # Check if SSH public key exists
    if [[ ! -f "$SSH_PUB_KEY_FILE" ]]; then
        print_info "SSH keys for tux2lab not found on this local workstation."
        print_info "Generating a new RSA key pair..."
        ssh-keygen -t rsa -b 4096 -N "" -f "$SSH_PRIVATE_KEY_FILE" -C "${lab_infra_domain_name}" &>/dev/null
        print_success "New SSH keys generated successfully:"
        print_info "Private Key: $SSH_PRIVATE_KEY_FILE" nskip
        print_info "Public Key : $SSH_PUB_KEY_FILE"
    else
        print_info "SSH keys for tux2lab found on this local workstation."
    fi
    # Read the public key into an explanatory variable
    lab_infra_ssh_public_key=$(<"$SSH_PUB_KEY_FILE")
    lab_infra_ssh_private_key=$(<"$SSH_PRIVATE_KEY_FILE")
    # Update authorized_keys for current user
    print_info "Ensuring tux2lab Infra SSH public key is in authorized_keys of user '${lab_infra_admin_username}'..."
    AUTHORIZED_KEYS_FILE="$SSH_DIR/authorized_keys"
    touch "$AUTHORIZED_KEYS_FILE"
    chmod 600 "$AUTHORIZED_KEYS_FILE"
    if ! grep -qF "$lab_infra_ssh_public_key" "$AUTHORIZED_KEYS_FILE"; then
        echo "$lab_infra_ssh_public_key" >> "$AUTHORIZED_KEYS_FILE"
        print_success "tux2lab Infra SSH public key added to authorized_keys."
    else
        print_info "tux2lab Infra SSH public key already present in authorized_keys."
    fi
    # Print confirmation
    print_info "Lab Infra SSH public key is ready for user \033[1m${lab_infra_admin_username}\033[0m on domain \033[1m${lab_infra_domain_name}\033[0m"

    # Ensure QEMU/KVM environment is ready (libvirtd + network)
    if $REBUILD_MODE || ! sudo virsh net-info tux2lab &>/dev/null; then
        print_info "Running QEMU/KVM setup to ensure environment is ready..."
        bash /tux2lab/qemu-kvm-manage/setup-qemu-kvm.sh --yes
    fi

    # Capture network info from QEMU-KVM default bridge
    print_task "Capturing network info from QEMU-KVM default network bridge..."

    qemu_kvm_default_net_info=$(sudo virsh net-dumpxml tux2lab 2>/dev/null) || {
        print_error "Failed to get network info from virsh"
        exit 1
    }
    lab_infra_server_ipv4_gateway=$(echo "$qemu_kvm_default_net_info" | awk -F"'" '/<ip address=/ {print $2}')
    lab_infra_server_ipv4_netmask=$(echo "$qemu_kvm_default_net_info" | awk -F"'" '/<ip address=/ {print $4}')
  
    if [[ -z "$lab_infra_server_ipv4_gateway" || -z "$lab_infra_server_ipv4_netmask" ]]; then
        print_error "Failed to extract network information from virsh output"
        exit 1
    fi
  
    lab_infra_server_ipv4_address=$(echo "$lab_infra_server_ipv4_gateway" | awk -F. '{ printf "%d.%d.%d.%d", $1, $2, $3, $4+1 }')

    # Extract IPv6 ULA configuration (required for dual-stack)
    lab_infra_server_ipv6_gateway=$(echo "$qemu_kvm_default_net_info" | awk -F"'" '/<ip family=.ipv6/ {print $4}')
    lab_infra_server_ipv6_prefix=$(echo "$qemu_kvm_default_net_info" | awk -F"'" '/<ip family=.ipv6/ {print $6}')
  
    if [[ -z "$lab_infra_server_ipv6_gateway" || -z "$lab_infra_server_ipv6_prefix" ]]; then
        print_error "IPv6 configuration not found in QEMU/KVM default network!"
        print_info "Dual-stack support required. Please ensure labbr0.xml has IPv6 configured."
        exit 1
    fi
  
    # Extract the /64 prefix base (remove host portion)
    lab_infra_server_ipv6_ula_subnet=$(echo "$lab_infra_server_ipv6_gateway" | sed 's/::[^:]*$/::/')/${lab_infra_server_ipv6_prefix}
  
    # Lab Infra Server gets special IPv6 address ::2 (gateway is ::1)
    # Extract IPv6 prefix without host portion (e.g., fd28:2808:2020:3000)
    ipv6_prefix_base=$(echo "$lab_infra_server_ipv6_gateway" | sed 's/::[^:]*$//')
  
    # Assign ::2 as the infrastructure server address
    lab_infra_server_ipv6_address="${ipv6_prefix_base}::2"

    # Calculate IPv4 subnet in CIDR notation
    IFS=. read -r m1 m2 m3 m4 <<< "$lab_infra_server_ipv4_netmask"
    cidr_prefix=$(awk -v m1="$m1" -v m2="$m2" -v m3="$m3" -v m4="$m4" 'BEGIN {
        for(i=1;i<=4;i++) {
            val=(i==1?m1:i==2?m2:i==3?m3:m4);
            for(b=7;b>=0;b--) if(and(val,lshift(1,b))) bits++
        }
        print bits
    }')
    IFS=. read -r o1 o2 o3 o4 <<< "$lab_infra_server_ipv4_gateway"
    network_o1=$((o1 & m1))
    network_o2=$((o2 & m2))
    network_o3=$((o3 & m3))
    network_o4=$((o4 & m4))
    lab_infra_server_ipv4_cidr_prefix="${cidr_prefix}"
    lab_infra_server_ipv4_subnet="${network_o1}.${network_o2}.${network_o3}.${network_o4}/${lab_infra_server_ipv4_cidr_prefix}"

    print_task_done

    # Print captured network information in user-friendly format
    print_info "Lab Infra Server Network Information (Dual-Stack):
✓ Hostname            : \033[1m${lab_infra_server_hostname}\033[0m
✓ Domain              : \033[1m${lab_infra_domain_name}\033[0m
✓ IPv4 Address        : \033[1m${lab_infra_server_ipv4_address}\033[0m
✓ IPv4 Gateway        : \033[1m${lab_infra_server_ipv4_gateway}\033[0m
✓ IPv4 Netmask        : \033[1m${lab_infra_server_ipv4_netmask}\033[0m
✓ IPv4 Subnet         : \033[1m${lab_infra_server_ipv4_subnet}\033[0m
✓ IPv6 Address        : \033[1m${lab_infra_server_ipv6_address}\033[0m
✓ IPv6 Gateway        : \033[1m${lab_infra_server_ipv6_gateway}\033[0m
✓ IPv6 ULA Subnet     : \033[1m${lab_infra_server_ipv6_ula_subnet}\033[0m"

    # Update SSH Custom Config
    print_task "Creating SSH Custom Config for '${lab_infra_domain_name}' domain..."
    # Split IP address
    IFS='.' read -r lab_infra_ipv4_octet1 lab_infra_ipv4_octet2 lab_infra_ipv4_octet3 lab_infra_ipv4_octet4 <<< "$lab_infra_server_ipv4_address"
    # Split Netmask
    IFS='.' read -r lab_infra_mask_octet1 lab_infra_mask_octet2 lab_infra_mask_octet3 lab_infra_mask_octet4 <<< "$lab_infra_server_ipv4_netmask"

    # Calculate the subnet span for the third octet
    # Example: netmask 255.255.252.0 → mask_octet3=252 → span = 255 - 252 = 3
    subnet_span=$((255 - lab_infra_mask_octet3))

    # Calculate the starting subnet
    starting_subnet_octet=$((lab_infra_ipv4_octet3 & lab_infra_mask_octet3))

    # Calculate the final subnet
    ending_subnet_octet=$((starting_subnet_octet | subnet_span))

    # Build allowed subnet list
    subnets_to_allow_ssh_pub_access=""

    for subnet_octet in $(seq "$starting_subnet_octet" "$ending_subnet_octet"); do
        subnets_to_allow_ssh_pub_access+=" ${lab_infra_ipv4_octet1}.${lab_infra_ipv4_octet2}.$subnet_octet.*"
    done

    # Trim leading space
    subnets_to_allow_ssh_pub_access="${subnets_to_allow_ssh_pub_access# }"

    # Create SSH config directory if it doesn't exist
    sudo mkdir -p /etc/ssh/ssh_config.d

    # Write SSH custom config (system-wide)
    SSH_CUSTOM_CONFIG_FILE="/etc/ssh/ssh_config.d/999-tux2lab.conf"
    sudo tee "$SSH_CUSTOM_CONFIG_FILE" &>/dev/null <<EOF
Host *.${lab_infra_domain_name} ${lab_infra_server_ipv4_address} ${subnets_to_allow_ssh_pub_access}
        IdentityFile ~/.ssh/tux2lab_id_rsa
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
        LogLevel QUIET
EOF

    # Also update user's personal SSH config.custom as fallback
    USER_SSH_DIR="${HOME}/.ssh"
    USER_SSH_CONFIG_CUSTOM="${USER_SSH_DIR}/config.custom"
  
    # Remove old lab config entries if they exist
    if [[ -f "$USER_SSH_CONFIG_CUSTOM" ]]; then
        sed -i '/# tux2lab SSH Config - Start/,/# tux2lab SSH Config - End/d' "$USER_SSH_CONFIG_CUSTOM"
        sed -i '/# KVM Lab SSH Config - Start/,/# KVM Lab SSH Config - End/d' "$USER_SSH_CONFIG_CUSTOM"
    fi
  
    # Append new lab config
    cat >> "$USER_SSH_CONFIG_CUSTOM" <<EOF
# tux2lab SSH Config - Start
Host *.${lab_infra_domain_name} ${lab_infra_server_ipv4_address} ${subnets_to_allow_ssh_pub_access}
        IdentityFile ~/.ssh/tux2lab_id_rsa
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
        LogLevel QUIET
# tux2lab SSH Config - End
EOF
  
    # Ensure main config includes config.custom
    USER_SSH_CONFIG="${USER_SSH_DIR}/config"
  
    # Add Include directive if not already present
    if [[ ! -f "$USER_SSH_CONFIG" ]] || ! grep -q "Include.*config.custom" "$USER_SSH_CONFIG"; then
        # Create or prepend to existing file
        if [[ -f "$USER_SSH_CONFIG" && -s "$USER_SSH_CONFIG" ]]; then
            # File exists and is not empty - prepend
            sed -i '1i # Include any user specified SSH configuration\nInclude ~/.ssh/config.custom\n' "$USER_SSH_CONFIG"
        else
            # File doesn't exist or is empty - create with content
            cat > "$USER_SSH_CONFIG" << 'EOF'
# Include any user specified SSH configuration
Include ~/.ssh/config.custom
EOF
        fi
    fi

    print_task_done

    print_task "Updating /etc/hosts for ${lab_infra_server_hostname}..."

    # Remove any existing entry (escape dots for regex safety)
    local escaped_hostname
    escaped_hostname=$(printf '%s' "${lab_infra_server_hostname}" | sed 's/\./\\./g')
    sudo sed -i.bak "/${escaped_hostname}/d" /etc/hosts 

    # Add dual-stack entries
    echo "${lab_infra_server_ipv4_address} ${lab_infra_server_hostname}" | sudo tee -a /etc/hosts &>/dev/null
    echo "${lab_infra_server_ipv6_address} ${lab_infra_server_hostname}" | sudo tee -a /etc/hosts &>/dev/null

    print_task_done
    # Save all lab environment variables to file
    LAB_ENV_VARS_FILE="/tux2lab-data/lab_environment_vars"

    print_task "Saving lab environment variables to ${LAB_ENV_VARS_FILE}..."

    # Create file with secure permissions before writing sensitive data (shadow password, SSH keys)
    touch "$LAB_ENV_VARS_FILE"
    chmod 600 "$LAB_ENV_VARS_FILE"

tee "$LAB_ENV_VARS_FILE" &>/dev/null <<EOF
lab_infra_server_hostname="${lab_infra_server_hostname}"
lab_infra_domain_name="${lab_infra_domain_name}"
lab_infra_admin_username="${lab_infra_admin_username}"
lab_admin_shadow_password='${lab_admin_shadow_password}'
lab_infra_ssh_private_key='${lab_infra_ssh_private_key}'
lab_infra_ssh_public_key='${lab_infra_ssh_public_key}'
lab_infra_server_ipv4_gateway="${lab_infra_server_ipv4_gateway}"
lab_infra_server_ipv4_netmask="${lab_infra_server_ipv4_netmask}"
lab_infra_server_ipv4_cidr_prefix="${lab_infra_server_ipv4_cidr_prefix}"
lab_infra_server_ipv4_address="${lab_infra_server_ipv4_address}"
lab_infra_server_ipv4_subnet="${lab_infra_server_ipv4_subnet}"
lab_infra_server_ipv6_gateway="${lab_infra_server_ipv6_gateway}"
lab_infra_server_ipv6_prefix="${lab_infra_server_ipv6_prefix}"
lab_infra_server_ipv6_ula_subnet="${lab_infra_server_ipv6_ula_subnet}"
lab_infra_server_ipv6_address="${lab_infra_server_ipv6_address}"
EOF

    print_task_done

}

#-------------------------------------------------------------
# Non-interactive config restore for rebuild mode
#-------------------------------------------------------------
prepare_lab_infra_config_for_rebuild() {
    print_info "Rebuilding lab using existing configuration..."

    LAB_ENV_VARS_FILE="/tux2lab-data/lab_environment_vars"
    if [[ ! -f "$LAB_ENV_VARS_FILE" ]]; then
        print_error "Lab environment file not found at $LAB_ENV_VARS_FILE"
        print_info "Cannot rebuild without existing configuration."
        print_info "Run 'tux2lab deploy' to create a new lab from scratch."
        exit 1
    fi

    source "$LAB_ENV_VARS_FILE"

    # Pre-flight environment checks
    local vendored_virt_manager_dir="/tux2lab/vendor/virt-manager"
    if [[ ! -d "${vendored_virt_manager_dir}/virtinst" || ! -f "${vendored_virt_manager_dir}/virt-install" ]]; then
        print_error "Vendored virt-manager files not found at ${vendored_virt_manager_dir}!"
        exit 1
    fi
    if [[ ! -d /tux2lab-data ]]; then
        print_error "Directory /tux2lab-data does not exist."
        exit 1
    fi

    # Derive shortname from hostname
    lab_infra_server_shortname="${lab_infra_server_hostname%%.*}"

    print_info "Rebuild configuration:
✓ Hostname            : \033[1m${lab_infra_server_hostname}\033[0m
✓ Domain              : \033[1m${lab_infra_domain_name}\033[0m
✓ Admin User          : \033[1m${lab_infra_admin_username}\033[0m
✓ Mode                : \033[1m$(if ${lab_infra_server_mode_is_host:-false}; then echo HOST; else echo VM; fi)\033[0m
✓ IPv4 Address        : \033[1m${lab_infra_server_ipv4_address}\033[0m
✓ IPv6 Address        : \033[1m${lab_infra_server_ipv6_address}\033[0m"

    # Ensure SSH keys exist on disk
    SSH_DIR="$HOME/.ssh"
    SSH_PRIVATE_KEY_FILE="$SSH_DIR/tux2lab_id_rsa"
    SSH_PUB_KEY_FILE="$SSH_DIR/tux2lab_id_rsa.pub"

    if [[ ! -d "$SSH_DIR" ]]; then
        mkdir -p "$SSH_DIR"
        chmod 700 "$SSH_DIR"
    fi

    # Always restore SSH keys from environment file (source of truth)
    print_info "Restoring SSH keys from environment file..."
    echo "$lab_infra_ssh_private_key" > "$SSH_PRIVATE_KEY_FILE"
    chmod 600 "$SSH_PRIVATE_KEY_FILE"
    echo "$lab_infra_ssh_public_key" > "$SSH_PUB_KEY_FILE"
    chmod 644 "$SSH_PUB_KEY_FILE"
    print_success "SSH keys restored."

    # Ensure public key is in authorized_keys
    AUTHORIZED_KEYS_FILE="$SSH_DIR/authorized_keys"
    touch "$AUTHORIZED_KEYS_FILE"
    chmod 600 "$AUTHORIZED_KEYS_FILE"
    if ! grep -qF "$lab_infra_ssh_public_key" "$AUTHORIZED_KEYS_FILE"; then
        echo "$lab_infra_ssh_public_key" >> "$AUTHORIZED_KEYS_FILE"
    fi

    # Compute subnets_to_allow_ssh_pub_access
    IFS='.' read -r lab_infra_ipv4_octet1 lab_infra_ipv4_octet2 lab_infra_ipv4_octet3 lab_infra_ipv4_octet4 <<< "$lab_infra_server_ipv4_address"
    IFS='.' read -r lab_infra_mask_octet1 lab_infra_mask_octet2 lab_infra_mask_octet3 lab_infra_mask_octet4 <<< "$lab_infra_server_ipv4_netmask"
    subnet_span=$((255 - lab_infra_mask_octet3))
    starting_subnet_octet=$((lab_infra_ipv4_octet3 & lab_infra_mask_octet3))
    ending_subnet_octet=$((starting_subnet_octet | subnet_span))
    subnets_to_allow_ssh_pub_access=""
    for subnet_octet in $(seq "$starting_subnet_octet" "$ending_subnet_octet"); do
        subnets_to_allow_ssh_pub_access+=" ${lab_infra_ipv4_octet1}.${lab_infra_ipv4_octet2}.$subnet_octet.*"
    done
    subnets_to_allow_ssh_pub_access="${subnets_to_allow_ssh_pub_access# }"

    # Update SSH config
    print_task "Updating SSH config for ${lab_infra_domain_name}..."
    sudo mkdir -p /etc/ssh/ssh_config.d
    SSH_CUSTOM_CONFIG_FILE="/etc/ssh/ssh_config.d/999-tux2lab.conf"
    sudo tee "$SSH_CUSTOM_CONFIG_FILE" &>/dev/null <<EOF
Host *.${lab_infra_domain_name} ${lab_infra_server_ipv4_address} ${subnets_to_allow_ssh_pub_access}
        IdentityFile ~/.ssh/tux2lab_id_rsa
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
        LogLevel QUIET
EOF

    USER_SSH_DIR="${HOME}/.ssh"
    USER_SSH_CONFIG_CUSTOM="${USER_SSH_DIR}/config.custom"
    if [[ -f "$USER_SSH_CONFIG_CUSTOM" ]]; then
        sed -i '/# tux2lab SSH Config - Start/,/# tux2lab SSH Config - End/d' "$USER_SSH_CONFIG_CUSTOM"
        sed -i '/# KVM Lab SSH Config - Start/,/# KVM Lab SSH Config - End/d' "$USER_SSH_CONFIG_CUSTOM"
    fi
    cat >> "$USER_SSH_CONFIG_CUSTOM" <<EOF
# tux2lab SSH Config - Start
Host *.${lab_infra_domain_name} ${lab_infra_server_ipv4_address} ${subnets_to_allow_ssh_pub_access}
        IdentityFile ~/.ssh/tux2lab_id_rsa
        StrictHostKeyChecking no
        UserKnownHostsFile /dev/null
        LogLevel QUIET
# tux2lab SSH Config - End
EOF

    USER_SSH_CONFIG="${USER_SSH_DIR}/config"
    if [[ ! -f "$USER_SSH_CONFIG" ]] || ! grep -q "Include.*config.custom" "$USER_SSH_CONFIG"; then
        if [[ -f "$USER_SSH_CONFIG" && -s "$USER_SSH_CONFIG" ]]; then
            sed -i '1i # Include any user specified SSH configuration\nInclude ~/.ssh/config.custom\n' "$USER_SSH_CONFIG"
        else
            cat > "$USER_SSH_CONFIG" << 'EOF'
# Include any user specified SSH configuration
Include ~/.ssh/config.custom
EOF
        fi
    fi
    print_task_done

    # Update /etc/hosts
    print_task "Updating /etc/hosts for ${lab_infra_server_hostname}..."
    local escaped_hostname
    escaped_hostname=$(printf '%s' "${lab_infra_server_hostname}" | sed 's/\./\\./g')
    sudo sed -i.bak "/${escaped_hostname}/d" /etc/hosts
    echo "${lab_infra_server_ipv4_address} ${lab_infra_server_hostname}" | sudo tee -a /etc/hosts &>/dev/null
    echo "${lab_infra_server_ipv6_address} ${lab_infra_server_hostname}" | sudo tee -a /etc/hosts &>/dev/null
    print_task_done

    print_success "Lab configuration restored from existing environment file."
}

#-------------------------------------------------------------
# Deployment mode functions
#-------------------------------------------------------------
validate_infra_server_iso() {
    # ISO setup — look for the marker file written by 'tux2lab distro download-infra-iso'
    ISO_DIR="/tux2lab-data/iso-files"
    INFRA_ISO_MARKER="${ISO_DIR}/infra-server-iso"
    INFRA_DISTRO_MARKER="${ISO_DIR}/infra-server-distro"
    ISO_NAME=""
    INFRA_DISTRO=""

    if [[ -f "$INFRA_ISO_MARKER" ]]; then
        ISO_NAME=$(< "$INFRA_ISO_MARKER")
        # Validate the marker points to an actual file
        if [[ ! -f "${ISO_DIR}/${ISO_NAME}" ]]; then
            print_error "Marker references ${ISO_NAME} but file not found in ${ISO_DIR}/"
            print_info "Please re-run: \033[1mtux2lab distro download-infra-iso\033[0m"
            exit 1
        fi
    else
        print_error "No infra server ISO has been downloaded yet."
        print_info "Please run: \033[1mtux2lab distro download-infra-iso\033[0m"
        print_info "Supported: AlmaLinux, Rocky Linux, Oracle Linux, CentOS Stream, RHEL"
        exit 1
    fi

    # Read the distro name written by 'tux2lab distro download-infra-iso'
    if [[ -f "$INFRA_DISTRO_MARKER" ]]; then
        INFRA_DISTRO=$(< "$INFRA_DISTRO_MARKER")
    else
        print_error "No infra server distro marker found."
        print_info "Please re-run: \033[1mtux2lab distro download-infra-iso\033[0m"
        exit 1
    fi

    print_info "ISO file found: ${ISO_DIR}/${ISO_NAME} (${INFRA_DISTRO} ${INFRA_SERVER_VERSION})"

    default_linux_distro_iso_path="${ISO_DIR}/${ISO_NAME}"
}

deploy_lab_infra_server_vm() {
    # Check for infra server ISO early — before any setup work
    validate_infra_server_iso
    if $REBUILD_MODE; then
        prepare_lab_infra_config_for_rebuild
    else
        prepare_lab_infra_config
    fi
    print_info "Starting deployment of lab infra server on a dedicated VM..."

    # VM directory and disk path
    VM_DIR="/tux2lab-data/vms/${lab_infra_server_hostname}"
    VM_DISK_PATH="${VM_DIR}/${lab_infra_server_hostname}.qcow2"

    # Clean up existing VM if in rebuild mode, otherwise error out
    if sudo virsh list --all | grep -qw "${lab_infra_server_hostname}"; then
        if $REBUILD_MODE; then
            print_info "Cleaning up existing VM '${lab_infra_server_hostname}' for rebuild..."
            sudo virsh destroy "${lab_infra_server_hostname}" &>/dev/null || true
            sudo virsh undefine "${lab_infra_server_hostname}" --nvram &>/dev/null || true
        else
            print_error "Lab Infra VM '${lab_infra_server_hostname}' already exists in libvirt!"
            print_info "To remove it, run: sudo virsh destroy ${lab_infra_server_hostname} && sudo virsh undefine ${lab_infra_server_hostname} --nvram && sudo rm -rf ${VM_DIR}"
            exit 1
        fi
    fi

    # Clean up stale ISO mount if present
    if mountpoint -q "/mnt/iso-for-${lab_infra_server_hostname}" &>/dev/null; then
        sudo umount -l "/mnt/iso-for-${lab_infra_server_hostname}" &>/dev/null || true
        sudo rmdir "/mnt/iso-for-${lab_infra_server_hostname}" &>/dev/null || true
    fi

    # Clean up VM directory (disk, NVRAM, old kickstart files)
    if [[ -d "$VM_DIR" ]]; then
        if $REBUILD_MODE; then
            print_info "Removing existing VM directory..."
            rm -rf "$VM_DIR"
        else
            print_error "Lab Infra VM directory already exists at $VM_DIR."
            print_info "To remove it, run: sudo rm -rf ${VM_DIR}"
            exit 1
        fi
    fi

    # Recreate clean VM directory
    mkdir -p "$VM_DIR"

    print_info "Lab Infra VM '${lab_infra_server_hostname}' ready to create."

    lab_infra_server_mode_is_host=false

    # Ensure the variable is recorded in the lab environment file
    if [[ -f "$LAB_ENV_VARS_FILE" ]]; then
        if grep -q "^lab_infra_server_mode_is_host=" "$LAB_ENV_VARS_FILE"; then
            sed -i "s/^lab_infra_server_mode_is_host=.*/lab_infra_server_mode_is_host=${lab_infra_server_mode_is_host}/" "$LAB_ENV_VARS_FILE"
        else
            echo "lab_infra_server_mode_is_host=${lab_infra_server_mode_is_host}" >> "$LAB_ENV_VARS_FILE"
        fi
    fi

    # -----------------------------
    # Mount ISO for kernel/initrd extraction
    # -----------------------------
    print_task "Mounting ISO for kernel/initrd extraction..."
    local iso_mount_dir="/mnt/iso-for-${lab_infra_server_hostname}"

    # Clean up stale mount from a previously interrupted deploy
    if [[ -d "$iso_mount_dir" ]]; then
        if mountpoint -q "$iso_mount_dir" 2>/dev/null; then
            sudo umount -l "$iso_mount_dir" 2>/dev/null || true
        fi
        sudo rmdir "$iso_mount_dir" 2>/dev/null || true
    fi

    sudo mkdir -p "$iso_mount_dir"
    local mount_err
    if ! mount_err=$(sudo mount -o loop,ro "${ISO_DIR}/${ISO_NAME}" "$iso_mount_dir" 2>&1); then
        print_task_fail
        print_error "Failed to mount ISO: ${ISO_DIR}/${ISO_NAME}"
        print_error "${mount_err}"
        exit 1
    fi
    print_task_done

    # -----------------------------
    # Kickstart file preparation
    # -----------------------------
    print_info "Preparing Kickstart file for unattended installation of Lab Infra VM..."

    KS_FILE="${VM_DIR}/${lab_infra_server_hostname}_ks.cfg"

    cp -f /tux2lab/qemu-kvm-manage/infra-server-ks-template.cfg "${KS_FILE}" || {
        print_error "Failed to copy kickstart template"
        exit 1
    }

    sed -i \
        -e "s/get_ipv4_address/${lab_infra_server_ipv4_address}/g" \
        -e "s/get_ipv4_netmask/${lab_infra_server_ipv4_netmask}/g" \
        -e "s/get_ipv4_gateway/${lab_infra_server_ipv4_gateway}/g" \
        -e "s/get_ipv6_address/${lab_infra_server_ipv6_address}/g" \
        -e "s/get_ipv6_gateway/${lab_infra_server_ipv6_gateway}/g" \
        -e "s/get_ipv6_prefix/${lab_infra_server_ipv6_prefix}/g" \
        -e "s/get_mgmt_super_user/${lab_infra_admin_username}/g" \
        -e "s/get_infra_server_name/${lab_infra_server_hostname}/g" \
        -e "s/get_lab_infra_domain_name/${lab_infra_domain_name}/g" \
        -e "s/get_subnets_to_allow_ssh_pub_access/${subnets_to_allow_ssh_pub_access}/g" \
        -e "s/get_infra_server_distro/${INFRA_DISTRO}/g" \
        -e "s/get_infra_server_version/${INFRA_SERVER_VERSION}/g" \
        "${KS_FILE}"

    awk -v val="$lab_admin_shadow_password" '{ gsub(/get_shadow_password_super_mgmt_user/, val) } 1' \
            "${KS_FILE}" > "${KS_FILE}"_tmp_ksmanager && mv "${KS_FILE}"_tmp_ksmanager "${KS_FILE}" || { print_error "Failed to update shadow password in kickstart"; exit 1; }

    awk -v val="$lab_infra_ssh_public_key" '{ gsub(/get_ssh_public_key_of_qemu_host_machine/, val) } 1' \
            "${KS_FILE}" > "${KS_FILE}"_tmp_ksmanager && mv "${KS_FILE}"_tmp_ksmanager "${KS_FILE}" || { print_error "Failed to update SSH public key in kickstart"; exit 1; }

    awk -v val="$lab_infra_ssh_private_key" '{ gsub(/get_ssh_private_key_of_qemu_host_machine/, val) } 1' \
            "${KS_FILE}" > "${KS_FILE}"_tmp_ksmanager && mv "${KS_FILE}"_tmp_ksmanager "${KS_FILE}" || { print_error "Failed to update SSH private key in kickstart"; exit 1; }

    # Set correct group ownership so QEMU/libvirt can read the kickstart file
    # Must be done after all sed/awk modifications since awk temp-file rewrites reset ownership
    if getent group libvirt-qemu &>/dev/null; then
        QEMU_GROUP="libvirt-qemu"
    elif getent group qemu &>/dev/null; then
        QEMU_GROUP="qemu"
    else
        print_error "Neither 'qemu' nor 'libvirt-qemu' group found. Is QEMU/KVM installed correctly?"
        exit 1
    fi
    sudo chown "$USER:$QEMU_GROUP" "${KS_FILE}"

    print_success "Kickstart file prepared at ${KS_FILE}"
    # -------------------------
    # Further deployment logic goes here
    # -------------------------
    # -----------------------------
    # Deploy tux2lab.service
    # -----------------------------
    print_task "Deploying tux2lab.service..."
    sudo tee /etc/systemd/system/tux2lab.service > /dev/null <<EOF
[Unit]
Description=tux2lab Lab Infrastructure
After=network-online.target libvirtd.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=$(whoami)
ExecStart=/tux2lab/qemu-kvm-manage/scripts-to-manage-vms/start.sh

[Install]
WantedBy=multi-user.target
EOF
    sudo chmod 644 /etc/systemd/system/tux2lab.service
    sudo systemctl daemon-reload
    sudo systemctl enable tux2lab.service >/dev/null 2>&1
    print_task_done

    # -----------------------------
    # Launch VM via virt-install
    # -----------------------------
    print_info "Buckle up! We are about to view the Infra Server VM (${lab_infra_server_hostname}) deployment from console!"
    print_info "The console will disconnect automatically after the OS installation completes."
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/select-ovmf.sh

    sudo PYTHONPATH="/tux2lab/vendor/virt-manager" python3 "/tux2lab/vendor/virt-manager/virt-install" \
        --name "${lab_infra_server_hostname}" \
        --features acpi=on,apic=on \
        --memory 2048 \
        --vcpus 2 \
        --disk path="${VM_DIR}/${lab_infra_server_hostname}.qcow2",size=30,bus=virtio \
        --disk path="$ISO_DIR/$ISO_NAME",device=cdrom,bus=sata \
        --os-variant detect=on,require=off \
        --network network=tux2lab,model=virtio \
        --initrd-inject="${KS_FILE}" \
        --location "$iso_mount_dir" \
        --extra-args "inst.ks=file:/${lab_infra_server_hostname}_ks.cfg inst.stage2=cdrom inst.repo=cdrom console=ttyS0 nomodeset inst.text quiet" \
        --graphics none \
        --noreboot \
        --watchdog none \
        --console pty,target_type=serial \
        --machine q35 \
        --cpu host-model \
        --boot loader=${OVMF_CODE_PATH},\
nvram.template=${OVMF_VARS_PATH},\
nvram="${VM_DIR}/${lab_infra_server_hostname}_VARS.fd",menu=on

    # Cleanup ISO mount
    sudo umount -l "$iso_mount_dir" 2>/dev/null || true
    sudo rmdir "$iso_mount_dir" 2>/dev/null || true

    # -----------------------------
    # Post-install: start VM and wait for bootstrap to complete
    # -----------------------------
    echo
    print_info "OS installation complete. Starting VM for first-boot configuration..."

    # Brief pause to let libvirt finalize domain state after install
    sleep 5

    # Start the VM (kickstart powered it off after install)
    if ! sudo virsh start "${lab_infra_server_hostname}" &>/dev/null; then
        print_error "Failed to start VM after installation."
        exit 1
    fi

    # Wait for SSH to become reachable
    local ssh_opts="-i ${HOME}/.ssh/tux2lab_id_rsa -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"
    local max_ssh_wait=300  # 5 minutes
    local elapsed=0

    while ! ssh $ssh_opts "${lab_infra_admin_username}@${lab_infra_server_ipv4_address}" true 2>/dev/null; do
        if [[ $elapsed -ge $max_ssh_wait ]]; then
            echo
            print_error "Timed out waiting for SSH (${max_ssh_wait}s). VM may still be booting."
            print_info "You can check manually: ssh ${lab_infra_admin_username}@${lab_infra_server_ipv4_address}"
            exit 1
        fi
        printf "\r${MAKE_IT_MAGENTA}[INFO] Waiting for SSH to become available on ${lab_infra_server_hostname} [%dm %ds]...${RESET_COLOR}\033[K" $((elapsed/60)) $((elapsed%60))
        sleep 5
        elapsed=$((elapsed + 5))
    done
    printf "\r${MAKE_IT_MAGENTA}[INFO] Waiting for SSH to become available on ${lab_infra_server_hostname} [%dm %ds]...${RESET_COLOR}\033[K" $((elapsed/60)) $((elapsed%60))
    print_success ""

    # Wait for bootstrap to complete
    local max_bootstrap_wait=900  # 15 minutes
    elapsed=0

    while ! ssh $ssh_opts "${lab_infra_admin_username}@${lab_infra_server_ipv4_address}" \
        "test -f /opt/tux2lab-bootstrap.done" 2>/dev/null; do
        if [[ $elapsed -ge $max_bootstrap_wait ]]; then
            echo
            print_error "Timed out waiting for bootstrap (${max_bootstrap_wait}s)."
            print_info "Bootstrap may still be running. Check with:"
            print_info "  ssh ${lab_infra_admin_username}@${lab_infra_server_ipv4_address} 'journalctl -u tux2lab-bootstrap -f'"
            exit 1
        fi
        printf "\r${MAKE_IT_MAGENTA}[INFO] Waiting for lab infrastructure bootstrap to complete [%dm %ds]...${RESET_COLOR}\033[K" $((elapsed/60)) $((elapsed%60))
        sleep 10
        elapsed=$((elapsed + 10))
    done
    printf "\r${MAKE_IT_MAGENTA}[INFO] Waiting for lab infrastructure bootstrap to complete [%dm %ds]...${RESET_COLOR}\033[K" $((elapsed/60)) $((elapsed%60))
    print_success ""

    # Configure DNS resolution on the KVM host to use the lab's DNS server
    print_task "Configuring DNS resolution for labbr0..."
    if sudo resolvectl dns labbr0 "${lab_infra_server_ipv4_address}" "${lab_infra_server_ipv6_address}" 2>/dev/null && \
       sudo resolvectl domain labbr0 "~${lab_infra_domain_name}" 2>/dev/null; then
        print_task_done
    else
        print_task_fail
        print_warning "Could not configure resolvectl. Run 'tux2lab dns' manually."
    fi

    echo
    print_green "═══════════════════════════════════════════════════════════════════"
    print_green "  Lab Infrastructure Server deployed successfully!"
    print_green "═══════════════════════════════════════════════════════════════════"
    print_green "  Hostname    : ${lab_infra_server_hostname}"
    print_green "  Domain      : ${lab_infra_domain_name}"
    print_green "  Admin       : ${lab_infra_admin_username}"
    print_green "  IPv4        : ${lab_infra_server_ipv4_address}"
    print_green "  IPv6        : ${lab_infra_server_ipv6_address}"
    print_green "  IPv4 Subnet : ${lab_infra_server_ipv4_subnet}"
    print_green "  IPv6 Subnet : ${lab_infra_server_ipv6_ula_subnet}"
    print_green "  IPv4 Gateway: ${lab_infra_server_ipv4_gateway}"
    print_green "  IPv6 Gateway: ${lab_infra_server_ipv6_gateway}"
    print_green "═══════════════════════════════════════════════════════════════════"
    echo

    # Run health check to verify all services
    print_info "Running health check..."
    echo
    /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/health.sh

    exit 0
}

deploy_lab_infra_server_host() {
    if $REBUILD_MODE; then
        prepare_lab_infra_config_for_rebuild
    else
        prepare_lab_infra_config
    fi
    print_info "Starting deployment of lab infra server directly on the KVM host..."

    # Check if critical services are already running (indicates existing deployment)
    print_info "Checking for existing host-mode services..."
    local existing_services=()

    if sudo systemctl is-active --quiet named; then
        existing_services+=("named (DNS)")
    fi
    if sudo systemctl is-active --quiet kea-dhcp4; then
        existing_services+=("kea-dhcp4 (DHCP)")
    fi
    if sudo systemctl is-active --quiet nginx; then
        existing_services+=("nginx (Web)")
    fi

    if [[ ${#existing_services[@]} -gt 0 ]]; then
        print_warning "Found active lab services on host:"
        for svc in "${existing_services[@]}"; do
            print_warning "  - $svc"
        done
        echo
        print_warning "These services will be reconfigured/overwritten."
        read -rp "Type 'RECONFIGURE' to continue with host deployment: " host_continue

        if [[ "$host_continue" != "RECONFIGURE" ]]; then
            print_info "Host deployment cancelled."
            exit 0
        fi

        print_warning "Proceeding with host deployment..."
        sleep 1
    fi

    # -----------------------------
    # Deployment mode flag
    # -----------------------------
    lab_infra_server_mode_is_host=true

    if [[ -f "$LAB_ENV_VARS_FILE" ]]; then
        if grep -q "^lab_infra_server_mode_is_host=" "$LAB_ENV_VARS_FILE"; then
            sed -i "s/^lab_infra_server_mode_is_host=.*/lab_infra_server_mode_is_host=${lab_infra_server_mode_is_host}/" "$LAB_ENV_VARS_FILE"
        else
            echo "lab_infra_server_mode_is_host=${lab_infra_server_mode_is_host}" >> "$LAB_ENV_VARS_FILE"
        fi
    fi

    # ====== CONFIGURATION ======
    local lab_bridge_dummy_interface_name="dummy-vnet"
    local lab_bridge_interface_name="labbr0"

    # ====== Check and start libvirtd if needed ======
    if sudo systemctl is-active --quiet libvirtd; then
        print_info "libvirtd is already running"
    else
        print_info "Starting libvirtd..."
        if ! sudo systemctl restart libvirtd; then
            print_error "Failed to start libvirtd"
            exit 1
        fi
        print_success "libvirtd started successfully"
    fi

    # ====== Wait for labbr0 ======
    print_info "Waiting for $lab_bridge_interface_name to be created..."
    local bridge_creation_timeout_seconds=30
    local bridge_creation_elapsed_seconds=0
    until ip link show "$lab_bridge_interface_name" &>/dev/null; do
        if [[ $bridge_creation_elapsed_seconds -ge $bridge_creation_timeout_seconds ]]; then
            print_error "Timeout waiting for $lab_bridge_interface_name"
            exit 1
        fi
        printf "."
        sleep 1
        bridge_creation_elapsed_seconds=$((bridge_creation_elapsed_seconds + 1))
    done
    echo
    print_info "$lab_bridge_interface_name detected!"

    # ====== Create dummy link if missing ======
    if ! ip link show "$lab_bridge_dummy_interface_name" &>/dev/null; then
        print_info "Creating dummy interface $lab_bridge_dummy_interface_name to keep $lab_bridge_interface_name always up..."
        sudo ip link add name "$lab_bridge_dummy_interface_name" type dummy || { print_error "Failed to create dummy interface"; return 1; }
        sudo ip link set "$lab_bridge_dummy_interface_name" master "$lab_bridge_interface_name" || { print_error "Failed to attach dummy to bridge"; return 1; }
        sudo ip link set "$lab_bridge_dummy_interface_name" up || { print_error "Failed to bring up dummy interface"; return 1; }
        print_success "Dummy interface created and attached"
    else
        print_info "Dummy interface $lab_bridge_dummy_interface_name already exists."
    fi

    # ====== Wait for labbr0 to come up ======
    print_info "Waiting for $lab_bridge_interface_name to come UP..."
    local bridge_up_timeout_seconds=30
    local bridge_up_elapsed_seconds=0
    while ! ip link show "$lab_bridge_interface_name" 2>/dev/null | grep -q 'state UP'; do
        if [[ $bridge_up_elapsed_seconds -ge $bridge_up_timeout_seconds ]]; then
            print_error "Timeout waiting for $lab_bridge_interface_name to come up"
            exit 1
        fi
        printf "."
        sleep 1
        bridge_up_elapsed_seconds=$((bridge_up_elapsed_seconds + 1))
    done
    echo
    print_info "$lab_bridge_interface_name is UP and running!"

    # ====== Assign IP addresses (dual-stack) ======
    local lab_infra_server_ipv4_cidr_prefix
    lab_infra_server_ipv4_cidr_prefix=$(awk -F. '{for(i=1;i<=4;i++){n=$i+0; while(n){c+=n%2; n=int(n/2)}}} END{print c+0}' <<< "${lab_infra_server_ipv4_netmask}")

    print_info "Configuring IPv4 ${lab_infra_server_ipv4_address}/${lab_infra_server_ipv4_cidr_prefix} on $lab_bridge_interface_name..."
    # Add the IPv4 address with CIDR prefix
    if sudo ip addr add "${lab_infra_server_ipv4_address}/${lab_infra_server_ipv4_cidr_prefix}" dev "$lab_bridge_interface_name" 2>/dev/null; then
        print_success "IPv4 address assigned successfully"
    else
        print_info "IPv4 address may already be assigned"
    fi

    print_info "Configuring IPv6 ${lab_infra_server_ipv6_address}/${lab_infra_server_ipv6_prefix} on $lab_bridge_interface_name..."
    # Add the IPv6 address with prefix
    if sudo ip addr add "${lab_infra_server_ipv6_address}/${lab_infra_server_ipv6_prefix}" dev "$lab_bridge_interface_name" 2>/dev/null; then
        print_success "IPv6 address assigned successfully"
    else
        print_info "IPv6 address may already be assigned"
    fi

    # -----------------------------
    # Install required packages
    # -----------------------------
    print_task "Installing required packages on host..."

    REQUIRED_PACKAGES=(
        bash-completion vim git bind-utils bind wget tar cifs-utils
        tftp-server kea kea-hooks radvd nginx nginx-mod-stream openssl tmux
        rsync sysstat tcpdump traceroute nc samba-client lsof nfs-utils
        nmap tuned tree yum-utils python3-pip python3-cryptography
    )

    # Install packages, skipping already installed ones
    sudo dnf install -y "${REQUIRED_PACKAGES[@]}" &>/dev/null &
    pkg_pid=$!

    elapsed=0
    while kill -0 "$pkg_pid" 2>/dev/null; do
        printf "\r${MAKE_IT_CYAN}[TASK] Installing required packages on host [%dm %ds]...${RESET_COLOR}\033[K" $((elapsed/60)) $((elapsed%60))
        sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$pkg_pid" || {
        printf "\r\033[K"
        print_task "Installing required packages on host..."
        print_task_fail
        print_error "Failed to install required packages."
        exit 1
    }
    printf "\r\033[K"
    print_task "Installing required packages on host..."
    print_task_done

    # -----------------------------
    # Install Ansible if not already installed
    # -----------------------------
    if command -v ansible &>/dev/null; then
        print_info "Ansible is already installed."
    else
        print_task "Installing Ansible on the host..."

        if command -v dnf &>/dev/null; then
            sudo dnf install -y ansible-core &>/dev/null &
            pkg_pid=$!
        elif command -v apt-get &>/dev/null; then
            (sudo apt-get update &>/dev/null && sudo apt-get install -y ansible-core &>/dev/null) &
            pkg_pid=$!
        else
            print_task_fail
            print_error "Unsupported package manager. Cannot install ansible-core."
            exit 1
        fi

        elapsed=0
        while kill -0 "$pkg_pid" 2>/dev/null; do
            printf "\r${MAKE_IT_CYAN}[TASK] Installing Ansible on the host [%dm %ds]...${RESET_COLOR}\033[K" $((elapsed/60)) $((elapsed%60))
            sleep 1
            elapsed=$((elapsed + 1))
        done
        wait "$pkg_pid" || {
            printf "\r\033[K"
            print_task "Installing Ansible on the host..."
            print_task_fail
            print_error "Failed to install Ansible."
            exit 1
        }
        printf "\r\033[K"
        print_task "Installing Ansible on the host..."
        print_task_done
    fi

    if ! ansible-galaxy collection install -r /tux2lab/configure-lab-infra-server/requirements.yml; then
        print_error "Failed to install Ansible collections"
        exit 1
    fi

    # ---------------------------
    # Lab Infra DNS configuration
    # ---------------------------
    print_info "Setting up Lab Infra DNS with custom utility dnsbinder (dual-stack)..."
    if ! sudo bash /tux2lab/named-manage/dnsbinder.sh --setup "${lab_infra_domain_name}"; then
        print_error "Failed to setup DNS with dnsbinder"
        exit 1
    fi

    # Set mgmt_super_user in environment using lab_infra_admin_username
    if ! grep -q mgmt_super_user /etc/environment; then
        echo "mgmt_super_user=\"${lab_infra_admin_username}\"" | sudo tee -a /etc/environment &>/dev/null
    fi

    # Set mgmt_interface_name in environment
    if ! grep -q mgmt_interface_name /etc/environment; then
        echo "mgmt_interface_name=\"labbr0\"" | sudo tee -a /etc/environment &>/dev/null
    fi

    # Set default_linux_distro_iso_path in environment (VM mode only — host mode uses tux2lab distro setup)
    if [[ "${lab_infra_server_mode_is_host}" == "false" ]]; then
        if ! grep -q default_linux_distro_iso_path /etc/environment; then
            echo "default_linux_distro_iso_path=\"${default_linux_distro_iso_path}\"" | sudo tee -a /etc/environment &>/dev/null
        fi

        # Set infra server distro and version in environment (for Ansible ISO mount)
        if ! grep -q infra_server_distro /etc/environment; then
            echo "infra_server_distro=\"${INFRA_DISTRO}\"" | sudo tee -a /etc/environment &>/dev/null
        fi
        if ! grep -q infra_server_version /etc/environment; then
            echo "infra_server_version=\"${INFRA_SERVER_VERSION}\"" | sudo tee -a /etc/environment &>/dev/null
        fi
    fi

    # Backup environment file
    sudo cp -p /etc/environment "/root/environment_bkp_$(date +%F)" || {
        print_warning "Failed to backup /etc/environment"
    }

    # Reload environment to include new variables
    # Export all variables from /etc/environment
    if [[ -f /etc/environment ]]; then
        while IFS='=' read -r key value; do
            # Ignore empty lines or lines without '='
            [[ -z "$key" || -z "$value" ]] && continue
            # Remove quotes around value
            value="${value%\"}"
            value="${value#\"}"
            export "$key=$value"
        done < /etc/environment
    fi

    print_info "Reserving DNS Records for DHCP lease (last 99 IPs: .156-.254)..."

    if [[ -z "${dnsbinder_last24_subnet:-}" ]]; then
        print_error "dnsbinder_last24_subnet not set. DNS setup may have failed."
        exit 1
    fi

    # Check if first DHCP lease record already exists — skip entire block if so
    if dig @"${dnsbinder_server_ipv4_address}" +short +time=1 +tries=1 A "dhcp-lease156.${dnsbinder_domain}" 2>/dev/null | grep -q '^[0-9]'; then
        print_info "DHCP lease DNS records already exist — skipping."
    else
        # Generate hostname-IP pairs file for batch creation
        local dhcp_lease_file
        dhcp_lease_file="$(mktemp /tmp/dhcp-lease-records.XXXXXXXXXX)"
        for IPOCTET in $(seq 156 254); do
            echo "dhcp-lease${IPOCTET} ${dnsbinder_last24_subnet}.${IPOCTET}" >> "$dhcp_lease_file"
        done
        # Batch create all DHCP lease DNS entries in a single dnsbinder invocation
        if ! sudo bash /tux2lab/named-manage/dnsbinder.sh -cify "$dhcp_lease_file"; then
            print_warning "Some DHCP lease DNS records may have failed to create."
        fi
        rm -f "$dhcp_lease_file"
    fi

    print_info "Checking SELinux status..."

    if sestatus 2>/dev/null | grep -q "disabled"; then
        print_info "SELinux is already disabled."
    else
        print_info "Disabling SELinux for current boot and persistently..."
        # Disable for current boot
        sudo setenforce 0 2>/dev/null || true
        # Disable for all future boots
        sudo grubby --update-kernel ALL --args selinux=0
        print_success "SELinux has been disabled."
    fi

    # -----------------------------
    # Ansible playbook execution
    # -----------------------------

    print_info "Executing Ansible playbook to configure Lab Infra Services..."

    export ANSIBLE_REMOTE_USER="${lab_infra_admin_username}"
    ANSIBLE_HOME="/tux2lab/configure-lab-infra-server/"

    # Run ansible-playbook that configures the essential services
    if ! ansible-playbook /tux2lab/configure-lab-infra-server/configure-lab-infra-server.yaml; then
        print_error "Ansible playbook execution failed"
        exit 1
    fi

    # -----------------------------
    # Deploy tux2lab.service
    # -----------------------------
    print_task "Deploying tux2lab.service..."
    sudo tee /etc/systemd/system/tux2lab.service > /dev/null <<EOF
[Unit]
Description=tux2lab Lab Infrastructure
After=network-online.target libvirtd.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=$(whoami)
ExecStart=/tux2lab/qemu-kvm-manage/scripts-to-manage-vms/start.sh

[Install]
WantedBy=multi-user.target
EOF
    sudo chmod 644 /etc/systemd/system/tux2lab.service
    sudo systemctl daemon-reload
    sudo systemctl enable tux2lab.service >/dev/null 2>&1
    print_task_done

    echo
    print_green "═══════════════════════════════════════════════════════════════════"
    print_green "  Lab Infrastructure Server deployed successfully!"
    print_green "═══════════════════════════════════════════════════════════════════"
    print_green "  Hostname    : ${lab_infra_server_hostname}"
    print_green "  Domain      : ${lab_infra_domain_name}"
    print_green "  Admin       : ${lab_infra_admin_username}"
    print_green "  IPv4        : ${lab_infra_server_ipv4_address}"
    print_green "  IPv6        : ${lab_infra_server_ipv6_address}"
    print_green "  IPv4 Subnet : ${lab_infra_server_ipv4_subnet}"
    print_green "  IPv6 Subnet : ${lab_infra_server_ipv6_ula_subnet}"
    print_green "  IPv4 Gateway: ${lab_infra_server_ipv4_gateway}"
    print_green "  IPv6 Gateway: ${lab_infra_server_ipv6_gateway}"
    print_green "═══════════════════════════════════════════════════════════════════"
    echo

    # Run health check to verify all services
    print_info "Running health check..."
    echo
    /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/health.sh

}

#-------------------------------------------------------------
# Main execution starts here
#-------------------------------------------------------------

if $REBUILD_MODE; then
    # Rebuild mode: source existing env file to determine deployment mode,
    # then call the appropriate deploy function (which uses non-interactive config).
    LAB_ENV_VARS_FILE="/tux2lab-data/lab_environment_vars"
    if [[ ! -f "$LAB_ENV_VARS_FILE" ]]; then
        print_error "Lab environment file not found. Cannot rebuild."
        print_info "Run 'tux2lab deploy' to create a new lab from scratch."
        exit 1
    fi
    source "$LAB_ENV_VARS_FILE"

    if ${lab_infra_server_mode_is_host:-false}; then
        print_info "Rebuilding Lab Infra Server in HOST mode..."
        deploy_lab_infra_server_host
    else
        print_info "Rebuilding Lab Infra Server in VM mode..."
        deploy_lab_infra_server_vm
    fi
    exit 0
fi

# Cleanup predecessor project (server-hub) if detected
bash /tux2lab/qemu-kvm-manage/cleanup-old-server-hub.sh

# CRITICAL: Check for existing deployment before proceeding
check_existing_lab_deployment

#-------------------------------------------------------------
# Deployment selection prompt
#-------------------------------------------------------------
echo
print_yellow "-------------------------------------------------------------
Lab Infra Server Deployment Mode Selection
-------------------------------------------------------------
Choose where to deploy your lab infra server:

    [vm]   → Deploy inside a dedicated KVM virtual machine
                ✓ Recommended for most users
                ✓ Provides isolation and easier management
                ✓ Can be easily removed or recreated
                ✓ Does not modify your host system
                ℹ Requires: ~2GB RAM, 2 vCPUs for lab infra server VM

    [host] → Deploy directly on the KVM host itself
                ✓ Lower resource overhead (no separate VM)
                ✓ Good for systems with limited RAM/CPU
                ✓ Suitable for WSL environments (may need tweaks)
                ⚠ ONLY use if you completely own this machine
                ⚠ NOT for shared, managed, or production systems
                ⚠ Modifies your host system directly
                ⚠ Installs packages: bind, kea, nginx, tftp-server, etc.
                ⚠ Configures system services directly on your machine
                ⚠ May conflict with existing services (DNS, DHCP, Web)
                ⚠ Requires understanding of network service management
                ⚠ More difficult to undo or clean up
-------------------------------------------------------------"

while true; do
    read -rp "Enter your choice (VM/HOST) [ Default: VM ]: " DEPLOY_TARGET
    DEPLOY_TARGET="${DEPLOY_TARGET:-VM}"
    case "$DEPLOY_TARGET" in
        VM)
            print_info "Confirmed: Lab Infra Server Deployment Mode set to 'VM'."
            deploy_lab_infra_server_vm
            break
            ;;
        HOST)
            print_yellow "═══════════════════════════════════════════════════════════════════
⚠  WARNING: HOST MODE DEPLOYMENT
═══════════════════════════════════════════════════════════════════"
            print_warning "You have chosen to deploy directly on your KVM host machine."
            echo
            print_info "Host mode is suitable for:
  ✓ Systems with limited RAM/CPU resources
  ✓ Machines you completely own (personal/dedicated systems)
  ✓ WSL environments (may require additional tweaks)
  ✓ Scenarios where VM overhead needs to be avoided"
            echo
            print_red "⚠  CRITICAL: Use HOST mode ONLY if you completely own this machine!
   • Do NOT use on shared systems
   • Do NOT use on managed/enterprise systems
   • Do NOT use on production systems
   • Do NOT use if you don't have full admin control"
            echo
            print_warning "This will:
  • Install and configure DNS (BIND) service
  • Install and configure DHCP (Kea) service
  • Install and configure NFS service
  • Install and configure Web (Nginx) service
  • Install and configure TFTP service
  • Install and configure NTP (chrony) service
  • Modify system network configuration
  • Change system-level service configurations
  • Potentially conflict with any existing services"
            echo
            print_warning "This option modifies your host system and is harder to reverse than VM mode.
If you have sufficient resources, consider using VM mode for safer deployment."
            echo
            read -rp "Type 'CONFIRM' to proceed with HOST mode deployment or 'NO' to cancel: " host_confirm
            
            if [[ "$host_confirm" != "CONFIRM" ]]; then
                print_info "Host deployment cancelled. Please choose 'VM' for safer deployment."
                continue
            fi
            
            print_info "Confirmed: Lab Infra Server Deployment Mode set to 'HOST'."
            deploy_lab_infra_server_host
            break
            ;;
        *)
            print_warning "Invalid choice. Please type either 'VM' or 'HOST'."
            ;;
    esac
done

