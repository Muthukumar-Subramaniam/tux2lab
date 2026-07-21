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
VERSION=$(jq -r '.version' /tux2lab/project_version.json)

print_cyan "tux2lab - Lab Management Tool
├─ Version    : $VERSION
├─ Repository : https://github.com/Muthukumar-Subramaniam/tux2lab
└─ Issues     : https://github.com/Muthukumar-Subramaniam/tux2lab/issues"

# ====== VALIDATE ======
readonly LAB_ENV_JSON="/tux2lab-data/lab-config/lab_environment.json"

if [[ ! -f "$LAB_ENV_JSON" ]]; then
    echo ""
    print_error "No lab deployment found."
    print_info "Run 'tux2lab deploy' first."
    exit 1
fi

# ====== READ CONFIG ======
readonly CONTAINER_NAME="tux2lab-engine"
lab_hostname=$(jq -r '.lab.engine_fqdn' "$LAB_ENV_JSON")
lab_domain=$(jq -r '.lab.domain' "$LAB_ENV_JSON")
lab_admin=$(jq -r '.admin.username' "$LAB_ENV_JSON")
lab_ipv4=$(jq -r '.network.ipv4.address' "$LAB_ENV_JSON")
lab_ipv6=$(jq -r '.network.ipv6.address' "$LAB_ENV_JSON")
lab_ipv4_cidr=$(jq -r '.network.ipv4.cidr' "$LAB_ENV_JSON")
lab_ipv6_subnet=$(jq -r '.network.ipv6.ula_subnet' "$LAB_ENV_JSON")
lab_bridge=$(jq -r '.network.bridge_interface' "$LAB_ENV_JSON")

# ====== CONTAINER STATUS ======
if sudo podman ps --filter "name=${CONTAINER_NAME}" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
    container_status="Running"
elif sudo podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
    container_status="Stopped"
else
    container_status="Not found"
fi

# Container image
container_image=$(sudo podman inspect "${CONTAINER_NAME}" --format '{{.ImageName}}' 2>/dev/null || echo "N/A")

# Auto-start
if sudo systemctl is-enabled --quiet tux2lab.service 2>/dev/null; then
    auto_start="Enabled"
else
    auto_start="Disabled"
fi

# Data directory size
if [[ -d /tux2lab-data ]]; then
    data_size=$(sudo du -sh /tux2lab-data 2>/dev/null | awk '{print $1}') || data_size="N/A"
else
    data_size="N/A"
fi

# VM count
total_vms=0
running_vms=0
stopped_vms=0
if command -v virsh &>/dev/null; then
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

# SSH key
ssh_key_path="${HOME}/.ssh/tux2lab_id_rsa"
if [[ -f "$ssh_key_path" ]]; then
    ssh_key_info="$ssh_key_path"
else
    ssh_key_info="Not found"
fi

# ====== DISPLAY ======
echo ""
print_cyan "Lab Deployment Info:"
echo -e "  ${MAKE_IT_CYAN}Lab Infra Server:${RESET_COLOR}  $lab_hostname"
echo -e "  ${MAKE_IT_CYAN}Domain:${RESET_COLOR}            $lab_domain"
echo -e "  ${MAKE_IT_CYAN}Admin User:${RESET_COLOR}        $lab_admin"
echo -e "  ${MAKE_IT_CYAN}IPv4 Address:${RESET_COLOR}      $lab_ipv4"
echo -e "  ${MAKE_IT_CYAN}IPv6 Address:${RESET_COLOR}      $lab_ipv6"
echo -e "  ${MAKE_IT_CYAN}IPv4 Network:${RESET_COLOR}      $lab_ipv4_cidr"
echo -e "  ${MAKE_IT_CYAN}IPv6 Subnet:${RESET_COLOR}       $lab_ipv6_subnet"
echo -e "  ${MAKE_IT_CYAN}Bridge:${RESET_COLOR}            $lab_bridge"
echo -e "  ${MAKE_IT_CYAN}Container:${RESET_COLOR}         ${CONTAINER_NAME} (${container_status})"
echo -e "  ${MAKE_IT_CYAN}Container Image:${RESET_COLOR}   $container_image"
echo -e "  ${MAKE_IT_CYAN}Auto-start:${RESET_COLOR}        $auto_start"
echo -e "  ${MAKE_IT_CYAN}SSH Key:${RESET_COLOR}           $ssh_key_info"
echo -e "  ${MAKE_IT_CYAN}Data Directory:${RESET_COLOR}    /tux2lab-data ($data_size)"
echo -e "  ${MAKE_IT_CYAN}VMs:${RESET_COLOR}               $running_vms running, $stopped_vms stopped ($total_vms total)"
echo -e "  ${MAKE_IT_CYAN}Golden Images:${RESET_COLOR}     $golden_images available"
