#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: info.sh                                                                   #
# Description: Display tux2lab deployment information                                     #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh

# ====== HELP ======
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    print_cyan "USAGE:
    tux2lab info

DESCRIPTION:
    Displays tux2lab deployment information including server details,
    network configuration, and lab inventory."
    exit 0
fi

# ====== VERSION HEADER ======
VERSION=$(grep -o '"version": *"[^"]*"' /tux2lab/project_version.json | cut -d'"' -f4)

print_cyan "tux2lab - Lab Management Tool
├─ Version    : $VERSION
├─ Repository : https://github.com/Muthukumar-Subramaniam/tux2lab
└─ Issues     : https://github.com/Muthukumar-Subramaniam/tux2lab/issues"

# ====== VALIDATE ======
LAB_ENV_VARS_FILE="/tux2lab-data/lab_environment_vars"

if [[ ! -f "$LAB_ENV_VARS_FILE" ]]; then
    echo ""
    print_error "No lab deployment found."
    print_info "Run 'tux2lab deploy' first."
    exit 1
fi

source "$LAB_ENV_VARS_FILE"

# ====== GATHER INFO ======

# Deploy mode
if ${lab_infra_server_mode_is_host:-false}; then
    deploy_mode="Host"
else
    deploy_mode="VM"
fi

# Server status (VM mode only)
if [[ "$deploy_mode" == "VM" ]]; then
    if sudo virsh list --state-running --name 2>/dev/null | grep -Fxq "$lab_infra_server_hostname"; then
        server_status="Running"
    elif sudo virsh list --all --name 2>/dev/null | grep -Fxq "$lab_infra_server_hostname"; then
        server_status="Stopped"
    else
        server_status="Not found"
    fi
else
    server_status="Local (host mode)"
fi

# Auto-start
if sudo systemctl is-enabled --quiet tux2lab.service 2>/dev/null; then
    auto_start="Enabled"
else
    auto_start="Disabled"
fi

# Data directory size
if [[ -d /tux2lab-data ]]; then
    data_size=$(du -sh /tux2lab-data 2>/dev/null | awk '{print $1}')
else
    data_size="N/A"
fi

# VM count
total_vms=0
running_vms=0
stopped_vms=0
if command -v virsh &>/dev/null; then
    # Count all VMs (including infra server)
    while IFS= read -r vm_name; do
        [[ -z "$vm_name" ]] && continue
        total_vms=$((total_vms + 1))
    done < <(sudo virsh list --all --name 2>/dev/null)

    while IFS= read -r vm_name; do
        [[ -z "$vm_name" ]] && continue
        running_vms=$((running_vms + 1))
    done < <(sudo virsh list --state-running --name 2>/dev/null)

    stopped_vms=$((total_vms - running_vms))
fi

# Golden images
golden_images=0
golden_images_dir="/tux2lab-data/golden-images-disk-store"
if [[ -d "$golden_images_dir" ]]; then
    golden_images=$(find "$golden_images_dir" -name "*.qcow2" 2>/dev/null | wc -l)
fi

# SSH key type
ssh_key_path="${HOME}/.ssh/tux2lab_id_rsa"
if [[ -f "$ssh_key_path" ]]; then
    ssh_key_info="$ssh_key_path"
else
    ssh_key_info="Not found"
fi

ssh_pub_key_path="${HOME}/.ssh/tux2lab_id_rsa.pub"
if [[ -f "$ssh_pub_key_path" ]]; then
    ssh_pub_info="$ssh_pub_key_path"
else
    ssh_pub_info="Not found"
fi

# ====== DISPLAY INFO ======
echo ""
print_cyan "Lab Deployment Info:"
echo -e "  ${MAKE_IT_CYAN}Deploy Mode:${RESET_COLOR}       $deploy_mode"
echo -e "  ${MAKE_IT_CYAN}Server:${RESET_COLOR}            $lab_infra_server_hostname"
echo -e "  ${MAKE_IT_CYAN}Server Status:${RESET_COLOR}     $server_status"
echo -e "  ${MAKE_IT_CYAN}Admin User:${RESET_COLOR}        $lab_infra_admin_username"
echo -e "  ${MAKE_IT_CYAN}Domain:${RESET_COLOR}            $lab_infra_domain_name"
echo -e "  ${MAKE_IT_CYAN}Server IPv4:${RESET_COLOR}       $lab_infra_server_ipv4_address"
echo -e "  ${MAKE_IT_CYAN}Server IPv6:${RESET_COLOR}       $lab_infra_server_ipv6_address"
echo -e "  ${MAKE_IT_CYAN}Gateway IPv4:${RESET_COLOR}      $lab_infra_server_ipv4_gateway"
echo -e "  ${MAKE_IT_CYAN}Gateway IPv6:${RESET_COLOR}      $lab_infra_server_ipv6_gateway"
echo -e "  ${MAKE_IT_CYAN}Network:${RESET_COLOR}           labbr0"
echo -e "  ${MAKE_IT_CYAN}IPv4 Subnet:${RESET_COLOR}       $lab_infra_server_ipv4_subnet"
echo -e "  ${MAKE_IT_CYAN}IPv6 Subnet:${RESET_COLOR}       $lab_infra_server_ipv6_ula_subnet"
echo -e "  ${MAKE_IT_CYAN}SSH Private Key:${RESET_COLOR}   $ssh_key_info"
echo -e "  ${MAKE_IT_CYAN}SSH Pub Key:${RESET_COLOR}       $ssh_pub_info"
echo -e "  ${MAKE_IT_CYAN}Auto-start:${RESET_COLOR}        $auto_start"
echo -e "  ${MAKE_IT_CYAN}Project Dir:${RESET_COLOR}       /tux2lab"
echo -e "  ${MAKE_IT_CYAN}Data Directory:${RESET_COLOR}    /tux2lab-data ($data_size)"
echo -e "  ${MAKE_IT_CYAN}VMs:${RESET_COLOR}               $running_vms running, $stopped_vms stopped ($total_vms total)"
echo -e "  ${MAKE_IT_CYAN}Golden Images:${RESET_COLOR}     $golden_images available"
