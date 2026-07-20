#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: stop.sh                                                                   #
# Description: Stop the entire tux2lab — all VMs, container, and infrastructure           #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# ====== GLOBAL CONFIGURATION ======
vm_shutdown_timeout=120

# ====== HELP ======
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_cyan "USAGE:
    tux2lab stop

DESCRIPTION:
    Gracefully shuts down all running VMs, stops the tux2lab-engine
    container, and tears down the lab infrastructure.
    VMs that do not shut down within ${vm_shutdown_timeout}s are force stopped."
    exit 0
fi

if [[ $# -gt 0 ]]; then
    print_error "Unknown argument: $1"
    echo "Run 'tux2lab stop --help' for usage information."
    exit 1
fi

# ====== SOURCE SHUTDOWN FUNCTION ======
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/shutdown-vm.sh

# ====== HEADER ======
print_cyan "--------------------------------------------------------------"
print_cyan "tux2lab Infrastructure Shutdown"
print_cyan "  Container : ${CONTAINER_NAME}"
print_cyan "  Hostname  : ${lab_infra_server_hostname}"
print_cyan "--------------------------------------------------------------"

print_warning "This will shut down all running VMs and stop all tux2lab services."

# Show running VMs if any
running_vms_list=$(sudo virsh list --state-running --name 2>/dev/null | grep -v "^$" || true)
if [[ -n "$running_vms_list" ]]; then
    print_warning "The following VMs will be shut down:"
    while IFS= read -r vm; do
        [[ -z "$vm" ]] && continue
        print_warning "  - $vm"
    done <<< "$running_vms_list"
fi

echo -n "Type CONFIRM to proceed: "
read -r confirmation
if [[ "${confirmation}" != "CONFIRM" ]]; then
    print_info "Operation cancelled."
    exit 0
fi

print_cyan "--------------------------------------------------------------"

# ====== STEP 1: Shutdown all guest VMs ======
running_vms=$(sudo virsh list --state-running --name 2>/dev/null | grep -v "^$" || true)
if [[ -n "$running_vms" ]]; then
    print_info "Sending graceful shutdown to all running VMs..."
    while IFS= read -r vm_name; do
        [[ -z "$vm_name" ]] && continue
        shutdown_vm "$vm_name" || true
    done <<< "$running_vms"

    # Wait for all VMs to shut down
    print_task "Waiting up to ${vm_shutdown_timeout}s for VMs to shut down..."
    elapsed=0
    while [[ $elapsed -lt $vm_shutdown_timeout ]]; do
        still_running=$(sudo virsh list --state-running --name 2>/dev/null | grep -v "^$" || true)
        if [[ -z "$still_running" ]]; then
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    # Force stop any VMs still running
    remaining=$(sudo virsh list --state-running --name 2>/dev/null | grep -v "^$" || true)
    if [[ -n "$remaining" ]]; then
        print_task_fail
        print_warning "Some VMs did not shut down gracefully. Force stopping..."
        while IFS= read -r vm_name; do
            [[ -z "$vm_name" ]] && continue
            print_task "Force stopping VM \"$vm_name\"..."
            if sudo virsh destroy "$vm_name" >/dev/null 2>&1; then
                print_task_done
            else
                print_task_fail
            fi
        done <<< "$remaining"
    else
        print_task_done
    fi
else
    print_info "No running VMs to shut down."
fi

# ====== STEP 2: Stop container ======
print_task "Stopping tux2lab-engine container..."
if sudo podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
    if sudo podman stop "${CONTAINER_NAME}" &>/dev/null; then
        print_task_done
    else
        print_task_fail
        print_warning "Failed to stop container gracefully, force removing..."
        sudo podman rm -f "${CONTAINER_NAME}" &>/dev/null || true
    fi
else
    print_task_skip
fi

# ====== STEP 3: Destroy virtual network ======
print_task "Destroying tux2lab virtual network..."
sudo virsh net-destroy tux2lab &>/dev/null || true
print_task_done

# ====== STEP 4: Stop libvirtd ======
print_task "Stopping libvirtd..."
if sudo systemctl stop libvirtd libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket 2>/dev/null; then
    print_task_done
else
    print_task_fail
    print_warning "Failed to stop libvirtd."
fi

print_cyan "--------------------------------------------------------------"
print_success "tux2lab infrastructure stopped."
