#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: destroy.sh                                                               #
# Description: Permanently destroy the entire tux2lab environment                        #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh

# ====== FLAG PARSING ======
wipe_iso_files=false

declare -A _seen_args
for arg in "$@"; do
    if [[ -n "${_seen_args[$arg]:-}" ]]; then
        print_error "Duplicate argument: $arg"
        exit 1
    fi
    _seen_args["$arg"]=1
    case "$arg" in
        -h|--help)
            print_cyan "USAGE:
    tux2lab destroy [OPTIONS]

DESCRIPTION:
    Permanently destroys the entire tux2lab environment, including:
      - The tux2lab-engine container
      - All virtual machines and their data
      - Lab network configuration
      - Lab data files (/tux2lab-data/ contents, excluding ISOs)
      - SSH keys and configuration for lab access
      - tux2lab systemd service

    Downloaded boot ISO files are preserved by default.

    If you wish to rebuild your lab after destruction:
      1. Run /tux2lab/setup/setup-host.sh
      2. Run tux2lab deploy

OPTIONS:
    --wipe-iso-files-too    Also delete downloaded boot ISO files
    -h, --help              Show this help message

    Requires typing 'DESTROY-THE-LAB-AND-ALL-ITS-DATA' to confirm."
            exit 0
            ;;
        --wipe-iso-files-too)
            wipe_iso_files=true
            ;;
        *)
            print_error "Unknown argument: $arg"
            echo "Run 'tux2lab destroy --help' for usage information."
            exit 1
            ;;
    esac
done

if [[ "$EUID" -eq 0 ]]; then
    print_error "Running as root user is not allowed."
    print_info "This script should be run as a user with sudo privileges, not as root."
    exit 1
fi

# ====== CONSTANTS ======
readonly CONTAINER_NAME="tux2lab-engine"
readonly LAB_ENV_JSON="/tux2lab-data/lab-config/lab_environment.json"

# ====== READ CONFIG IF AVAILABLE ======
lab_domain=""
lab_ipv4=""
lab_ipv6=""
if [[ -f "$LAB_ENV_JSON" ]]; then
    lab_domain=$(jq -r '.lab.domain' "$LAB_ENV_JSON")
    lab_ipv4=$(jq -r '.network.ipv4.address' "$LAB_ENV_JSON")
    lab_ipv6=$(jq -r '.network.ipv6.address' "$LAB_ENV_JSON")
fi

# ====== EARLY EXIT IF NO LAB EXISTS ======
lab_exists=false
if [[ -f "$LAB_ENV_JSON" ]]; then
    lab_exists=true
elif sudo podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
    lab_exists=true
elif sudo virsh list --all --name 2>/dev/null | grep -q .; then
    lab_exists=true
elif sudo virsh net-info tux2lab &>/dev/null 2>&1; then
    lab_exists=true
elif ip link show labbr0 &>/dev/null 2>&1; then
    lab_exists=true
elif systemctl list-unit-files tux2lab.service &>/dev/null 2>&1; then
    lab_exists=true
fi

if ! $lab_exists; then
    print_info "No lab detected — nothing to destroy."
    exit 0
fi

# ====== HEADER ======
print_cyan "═══════════════════════════════════════════════════════════════════"
print_red  "              DESTROY LAB — COMPLETE LAB TEARDOWN"
print_cyan "═══════════════════════════════════════════════════════════════════"

echo
print_warning "This operation will PERMANENTLY DESTROY:"
print_warning "  • The tux2lab-engine container and all services"
print_warning "  • All virtual machines and their data"
print_warning "  • Lab network bridge and virtual network"
print_warning "  • Lab config, SSH keys, SSL certificates"
print_warning "  • VM disks, golden images, ksmanager data"

if $wipe_iso_files; then
    print_warning "  • Downloaded boot ISO files (--wipe-iso-files-too)"
else
    print_info "  Boot ISO files will be PRESERVED (use --wipe-iso-files-too to remove)"
fi

# ====== LIST VMs THAT WILL BE DESTROYED ======
all_vms=$(sudo virsh list --all --name 2>/dev/null | grep -v "^$" || true)
if [[ -n "$all_vms" ]]; then
    echo
    print_warning "The following VMs will be DESTROYED:"
    while IFS= read -r vm; do
        [[ -z "$vm" ]] && continue
        vm_state=$(sudo virsh domstate "$vm" 2>/dev/null || echo "unknown")
        print_warning "  - ${vm} (${vm_state})"
    done <<< "$all_vms"
fi

echo
print_red "THIS ACTION CANNOT BE UNDONE."
echo
echo -n "Type DESTROY-THE-LAB-AND-ALL-ITS-DATA to confirm: "
read -r confirmation

if [[ "${confirmation}" != "DESTROY-THE-LAB-AND-ALL-ITS-DATA" ]]; then
    print_info "Operation cancelled. Your lab is safe."
    exit 0
fi

print_cyan "═══════════════════════════════════════════════════════════════════"

# ====== STEP 1: STOP AND REMOVE CONTAINER ======
print_task "Stopping and removing tux2lab-engine container..."
if sudo podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
    sudo podman stop "${CONTAINER_NAME}" &>/dev/null || true
    sudo podman rm -f "${CONTAINER_NAME}" &>/dev/null || true
    print_task_done
else
    print_task_skip
fi

# ====== STEP 2: FORCE STOP ALL RUNNING VMs ======
running_vms=$(sudo virsh list --state-running --name 2>/dev/null | grep -v "^$" || true)
if [[ -n "$running_vms" ]]; then
    while IFS= read -r vm_name; do
        [[ -z "$vm_name" ]] && continue
        print_task "Force stopping VM \"${vm_name}\"..."
        if sudo virsh destroy "$vm_name" >/dev/null 2>&1; then
            print_task_done
        else
            print_task_fail
        fi
    done <<< "$running_vms"
else
    print_info "No running VMs to stop."
fi

# ====== STEP 3: UNDEFINE ALL VMs ======
all_vms=$(sudo virsh list --all --name 2>/dev/null | grep -v "^$" || true)
if [[ -n "$all_vms" ]]; then
    while IFS= read -r vm_name; do
        [[ -z "$vm_name" ]] && continue
        print_task "Undefining VM \"${vm_name}\"..."
        if sudo virsh undefine "$vm_name" --nvram >/dev/null 2>&1; then
            print_task_done
        elif sudo virsh undefine "$vm_name" >/dev/null 2>&1; then
            print_task_done
        else
            print_task_fail
            print_warning "Could not undefine VM \"${vm_name}\""
        fi

        # Remove VM disk directory
        if [[ -d "/tux2lab-data/vms/${vm_name}" ]]; then
            sudo rm -rf "/tux2lab-data/vms/${vm_name}"
        fi

        # Remove storage pool if it exists
        if sudo virsh pool-info "$vm_name" &>/dev/null; then
            sudo virsh pool-destroy "$vm_name" &>/dev/null || true
            sudo virsh pool-undefine "$vm_name" &>/dev/null || true
        fi
    done <<< "$all_vms"
else
    print_info "No VMs to remove."
fi

# ====== STEP 4: STOP AND REMOVE SYSTEMD SERVICE ======
print_task "Stopping and removing tux2lab.service..."
if systemctl list-unit-files tux2lab.service &>/dev/null 2>&1; then
    sudo systemctl stop tux2lab.service --no-block 2>/dev/null || true
    sudo systemctl disable tux2lab.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/tux2lab.service
    sudo systemctl daemon-reload
    print_task_done
else
    print_task_skip
fi

# ====== STEP 5: CLEAN /etc/hosts ENTRIES ======
print_task "Cleaning lab entries from /etc/hosts..."
if [[ -n "$lab_domain" ]] && grep -q "${lab_domain}" /etc/hosts 2>/dev/null; then
    escaped_domain="${lab_domain//./\\.}"
    sudo sed -i "/${escaped_domain}/d" /etc/hosts 2>/dev/null || true
    print_task_done
else
    print_task_skip
fi

# ====== STEP 6: REMOVE SSH ARTIFACTS ======
print_task "Removing SSH artifacts..."
rm -f "$HOME/.ssh/tux2lab_id_rsa" "$HOME/.ssh/tux2lab_id_rsa.pub" 2>/dev/null || true
rm -f "$HOME/.ssh/config.d/tux2lab.conf" 2>/dev/null || true
if [[ -f "$HOME/.ssh/authorized_keys" ]] && [[ -n "$lab_domain" ]]; then
    escaped_domain="${lab_domain//./\\.}"
    sed -i "/${escaped_domain}/d" "$HOME/.ssh/authorized_keys" 2>/dev/null || true
fi
print_task_done

# ====== STEP 7: DESTROY VIRTUAL NETWORK ======
print_task "Destroying tux2lab virtual network..."
if sudo virsh net-info tux2lab &>/dev/null 2>&1 || ip link show labbr0 &>/dev/null 2>&1; then
    sudo virsh net-destroy tux2lab &>/dev/null || true
    sudo virsh net-undefine tux2lab &>/dev/null || true
    print_task_done
else
    print_task_skip
fi

# ====== STEP 8: REMOVE STORAGE POOLS AND STOP LIBVIRTD ======
if systemctl is-active libvirtd &>/dev/null; then
    for pool_name in $(sudo virsh pool-list --all --name 2>/dev/null | grep -v "^$" || true); do
        print_task "Removing storage pool \"${pool_name}\"..."
        sudo virsh pool-destroy "$pool_name" &>/dev/null || true
        sudo virsh pool-undefine "$pool_name" &>/dev/null || true
        print_task_done
    done
fi

print_task "Stopping and disabling libvirtd..."
if systemctl is-enabled libvirtd &>/dev/null || systemctl is-active libvirtd &>/dev/null; then
    sudo systemctl stop libvirtd libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket 2>/dev/null || true
    sudo systemctl disable libvirtd libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket 2>/dev/null || true
    print_task_done
else
    print_task_skip
fi

# ====== STEP 9: WIPE /tux2lab-data/ CONTENTS ======
if [[ -d "/tux2lab-data" ]]; then
    if $wipe_iso_files; then
        print_task "Wiping /tux2lab-data/ contents (including ISOs)..."
        if compgen -G "/tux2lab-data/*" >/dev/null 2>&1; then
            sudo rm -rf /tux2lab-data/*
            print_task_done
        else
            print_task_skip
        fi
    else
        print_task "Wiping /tux2lab-data/ contents (preserving ISOs)..."
        has_content=false
        for item in /tux2lab-data/*; do
            [[ ! -e "$item" ]] && continue
            [[ "$(basename "$item")" == "iso-files" ]] && continue
            has_content=true
            break
        done
        if $has_content; then
            for item in /tux2lab-data/*; do
                [[ "$(basename "$item")" == "iso-files" ]] && continue
                sudo rm -rf "$item"
            done
            print_task_done
        else
            print_task_skip
        fi
    fi
fi

# ====== STEP 10: REMOVE CONTAINER IMAGE ======
print_task "Removing tux2lab-engine container image..."
if sudo podman images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -q "tux2lab-engine"; then
    sudo podman rmi --all --force &>/dev/null || true
    print_task_done
else
    print_task_skip
fi

# ====== SUMMARY ======
print_cyan "═══════════════════════════════════════════════════════════════════"
print_success "Lab has been completely destroyed."
if ! $wipe_iso_files && [[ -d "/tux2lab-data/iso-files" ]]; then
    print_cyan "ISO files preserved at /tux2lab-data/iso-files/"
fi
print_cyan "
If you wish to rebuild your lab:
  1. Run /tux2lab/setup/setup-host.sh
  2. Run tux2lab deploy
═══════════════════════════════════════════════════════════════════"

exit 0
