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
    tux2lab destroy

DESCRIPTION:
    Permanently destroy the entire lab environment including all VMs, data,
    DNS, networking, downloaded ISO files, and the container.
    This cannot be undone.

OPTIONS:
    -h, --help              Show this help message

    Requires typing 'DESTROY-THE-LAB-AND-ALL-ITS-DATA' to confirm."
            exit 0
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

# ====== DETECT LAB STATE (for display only, not for early exit) ======
# Captured before teardown, since afterwards there is nothing left to inspect
lab_existed=false
if sudo podman container exists "${CONTAINER_NAME}" 2>/dev/null \
   || [[ -f "${LAB_ENV_JSON}" ]] \
   || sudo virsh net-info tux2lab &>/dev/null \
   || ip link show labbr0 &>/dev/null \
   || compgen -G "/tux2lab-data/*" >/dev/null 2>&1; then
    lab_existed=true
fi

# ====== HEADER ======
print_cyan "═══════════════════════════════════════════════════════════════════"
print_red  "              DESTROY LAB — COMPLETE LAB TEARDOWN"
print_cyan "═══════════════════════════════════════════════════════════════════"

# Optional entry, empty when no ISOs have been downloaded
iso_entry=""
if [[ -d /tux2lab-data/iso-files ]] && compgen -G "/tux2lab-data/iso-files/*" >/dev/null 2>&1; then
    iso_size=$(du -sh /tux2lab-data/iso-files 2>/dev/null | cut -f1 || true)
    iso_entry="
  • Downloaded ISO files${iso_size:+ (${iso_size})}"
fi

print_yellow "This operation will PERMANENTLY DESTROY:
  • The tux2lab-engine container and all services
  • All virtual machines and their data
  • Lab network bridge and virtual network
  • Lab config, SSH keys, SSL certificates
  • VM disks, golden images, ksmanager data${iso_entry}"

# ====== LIST VMs THAT WILL BE DESTROYED ======
# Single virsh call yields name and state together
vm_list=""
while IFS='|' read -r vm vm_state; do
    [[ -z "$vm" ]] && continue
    vm_list+="
  - ${vm} (${vm_state})"
done < <(sudo virsh list --all 2>/dev/null | awk 'NR>2 && NF {name=$2; $1=""; $2=""; sub(/^[ \t]+/,""); sub(/[ \t]+$/,""); print name"|"$0}')

if [[ -n "$vm_list" ]]; then
    print_yellow "The following VMs will be DESTROYED:${vm_list}"
fi

print_red "THIS ACTION CANNOT BE UNDONE."
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

# ====== STEP 5.1: STOP NFS AND CLEAN HOST CONFIG ======
source /tux2lab/shared-functions/host-nfs.sh
stop_host_nfs

# ====== STEP 6: CLEAN /etc/hosts ENTRIES ======
print_task "Cleaning lab entries from /etc/hosts..."
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/update-etc-hosts.sh
remove_etc_hosts_block
rm -f "${ETC_HOSTS_STATE}" 2>/dev/null || true
print_task_done

# ====== STEP 6: REMOVE SSH AND SSL ARTIFACTS ======
print_task "Removing SSH and SSL artifacts..."
has_artifacts=false
[[ -f "$HOME/.ssh/tux2lab_id_rsa" ]] && has_artifacts=true
grep -q "# BEGIN tux2lab" "$HOME/.ssh/config.custom" 2>/dev/null && has_artifacts=true
[[ -f /etc/pki/ca-trust/source/anchors/tux2lab-nginx-selfsigned.crt ]] && has_artifacts=true
[[ -f /etc/pki/trust/anchors/tux2lab-nginx-selfsigned.crt ]] && has_artifacts=true
[[ -f /usr/local/share/ca-certificates/tux2lab-nginx-selfsigned.crt ]] && has_artifacts=true

if $has_artifacts; then
    rm -f "$HOME/.ssh/tux2lab_id_rsa" "$HOME/.ssh/tux2lab_id_rsa.pub" 2>/dev/null || true
    # Remove tux2lab block from config.custom
    if grep -q "# BEGIN tux2lab" "$HOME/.ssh/config.custom" 2>/dev/null; then
        sed -i '/# BEGIN tux2lab/,/# END tux2lab/d' "$HOME/.ssh/config.custom" 2>/dev/null || true
    fi
    # Legacy cleanup
    rm -f "$HOME/.ssh/config.d/tux2lab.conf" 2>/dev/null || true
    if [[ -f "$HOME/.ssh/authorized_keys" ]] && [[ -n "$lab_domain" ]]; then
        escaped_domain="${lab_domain//./\\.}"
        sed -i "/${escaped_domain}/d" "$HOME/.ssh/authorized_keys" 2>/dev/null || true
    fi
    # Remove SSL cert from host trust store
    if [[ -f /etc/pki/ca-trust/source/anchors/tux2lab-nginx-selfsigned.crt ]]; then
        sudo rm -f /etc/pki/ca-trust/source/anchors/tux2lab-nginx-selfsigned.crt
        sudo update-ca-trust &>/dev/null || true
    elif [[ -f /etc/pki/trust/anchors/tux2lab-nginx-selfsigned.crt ]]; then
        sudo rm -f /etc/pki/trust/anchors/tux2lab-nginx-selfsigned.crt
        sudo update-ca-certificates &>/dev/null || true
    elif [[ -f /usr/local/share/ca-certificates/tux2lab-nginx-selfsigned.crt ]]; then
        sudo rm -f /usr/local/share/ca-certificates/tux2lab-nginx-selfsigned.crt
        sudo update-ca-certificates &>/dev/null || true
    fi
    print_task_done
else
    print_task_skip
fi

# ====== STEP 7: REMOVE LABLINK0 DUMMY INTERFACE ======
source /tux2lab/shared-functions/lablink0.sh
remove_lablink0

# ====== STEP 8: REMOVE FIREWALL RULES ======
source /tux2lab/shared-functions/bridge-firewall.sh
close_bridge_firewall "labbr0"

# ====== STEP 9: DESTROY VIRTUAL NETWORK ======
print_task "Destroying tux2lab virtual network..."
if sudo virsh net-info tux2lab &>/dev/null 2>&1 || ip link show labbr0 &>/dev/null 2>&1; then
    sudo virsh net-destroy tux2lab &>/dev/null || true
    sudo virsh net-undefine tux2lab &>/dev/null || true
    print_task_done
else
    print_task_skip
fi

# ====== STEP 9: REMOVE STORAGE POOLS AND STOP LIBVIRTD ======
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

# ====== UNMOUNT ISOs AND WIPE /tux2lab-data/ CONTENTS ======
# Unmount any loop-mounted ISOs under /tux2lab-data/os-repos/
if mount | grep -q "/tux2lab-data/os-repos/"; then
    print_task "Unmounting ISO mounts..."
    mount | grep "/tux2lab-data/os-repos/" | awk '{print $3}' | while read -r mnt; do
        sudo umount "$mnt" 2>/dev/null || sudo umount -l "$mnt" 2>/dev/null || true
    done
    print_task_done
fi

if [[ -d "/tux2lab-data" ]]; then
    print_task "Wiping /tux2lab-data/ contents..."
    if compgen -G "/tux2lab-data/*" >/dev/null 2>&1; then
        sudo rm -rf /tux2lab-data/*
        print_task_done
    else
        print_task_skip
    fi
fi

# ====== STEP 11: REMOVE CONTAINER IMAGE ======
print_task "Removing tux2lab-engine container image..."
if sudo podman images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -q "tux2lab-engine"; then
    sudo podman rmi --all --force &>/dev/null || true
    print_task_done
else
    print_task_skip
fi

# ====== SUMMARY ======
print_cyan "═══════════════════════════════════════════════════════════════════"
if sudo podman container exists "${CONTAINER_NAME}" 2>/dev/null \
   || [[ -f "${LAB_ENV_JSON}" ]] \
   || sudo virsh net-info tux2lab &>/dev/null 2>&1 \
   || ip link show labbr0 &>/dev/null 2>&1; then
    print_warning "Some components could not be fully removed. Run again or check manually."
elif $lab_existed; then
    print_success "Lab has been completely destroyed."
else
    print_info "Lab is already clean — nothing to destroy."
fi
print_cyan "
If you wish to rebuild your lab:
  1. Run /tux2lab/setup/setup-host.sh
  2. Run tux2lab deploy
═══════════════════════════════════════════════════════════════════"

exit 0
