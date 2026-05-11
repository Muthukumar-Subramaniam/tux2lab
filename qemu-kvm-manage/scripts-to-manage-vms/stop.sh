#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: stop.sh                                                                   #
# Description: Stop the entire KVM lab — all VMs, services, and infrastructure            #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# ====== GLOBAL CONFIGURATION ======
lab_bridge_interface_name="labbr0"
vm_shutdown_timeout=120

# ====== HELP ======
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_cyan "USAGE:
    tux2lab stop

DESCRIPTION:
    Gracefully shuts down all running VMs, stops all lab services,
    and tears down the lab infrastructure.
    VMs that do not shut down within ${vm_shutdown_timeout}s are force stopped."
    exit 0
fi

# ====== SOURCE SHUTDOWN FUNCTION ======
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/shutdown-vm.sh

# ====== SHUTDOWN ALL VMs ======
shutdown_all_vms() {
    local running_vms
    running_vms=$(sudo virsh list --state-running --name 2>/dev/null | grep -v "^$" || true)

    if [[ -z "$running_vms" ]]; then
        print_info "No running VMs to shut down."
        return
    fi

    # Send graceful shutdown to all VMs (infra server last in VM mode)
    print_info "Sending graceful shutdown to all running VMs..."
    local infra_vm_running=false
    while IFS= read -r vm_name; do
        [[ -z "$vm_name" ]] && continue
        if [[ "$vm_name" == "$lab_infra_server_hostname" ]] && ! $lab_infra_server_mode_is_host; then
            infra_vm_running=true
            continue
        fi
        shutdown_vm "$vm_name"
    done <<< "$running_vms"

    # Shutdown infra server VM last
    if $infra_vm_running; then
        print_info "Shutting down lab infra server VM last..."
        shutdown_vm "$lab_infra_server_hostname"
    fi

    # Wait for all VMs to shut down
    print_task "Waiting up to ${vm_shutdown_timeout}s for VMs to shut down..."
    local elapsed=0
    while [[ $elapsed -lt $vm_shutdown_timeout ]]; do
        local still_running
        still_running=$(sudo virsh list --state-running --name 2>/dev/null | grep -v "^$" || true)
        if [[ -z "$still_running" ]]; then
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    # Force stop any VMs still running
    local remaining
    remaining=$(sudo virsh list --state-running --name 2>/dev/null | grep -v "^$" || true)
    if [[ -n "$remaining" ]]; then
        print_task_fail
        print_warning "Some VMs did not shut down gracefully. Force stopping..."
        while IFS= read -r vm_name; do
            [[ -z "$vm_name" ]] && continue
            print_task "Force stopping VM \"$vm_name\"..." nskip
            if sudo virsh destroy "$vm_name" >/dev/null 2>&1; then
                print_task_done
            else
                print_task_fail
            fi
        done <<< "$remaining"
    else
        print_task_done
    fi
}

when_lab_infra_server_is_host() {
    local lab_bridge_dummy_interface_name="dummy-vnet"
    local lab_essential_services=("nginx" "nfs-server" "tftp.socket" "kea-dhcp4" "kea-dhcp6" "radvd")

    # ====== STEP 1: Shutdown all VMs ======
    shutdown_all_vms

    # ====== STEP 2: Stop essential lab services ======
    print_info "Stopping lab services..."
    local failed_services_list=()
    for service_name in "${lab_essential_services[@]}"; do
        print_task "Stopping $service_name..." nskip
        if sudo systemctl stop "$service_name" 2>/dev/null; then
            print_task_done
        else
            print_task_fail
            failed_services_list+=("$service_name")
        fi
    done

    # ====== STEP 3: Stop named ======
    print_task "Stopping named service..." nskip
    if sudo systemctl stop named 2>/dev/null; then
        print_task_done
    else
        print_task_fail
        failed_services_list+=("named")
    fi

    # ====== STEP 4: Remove IP addresses from labbr0 ======
    if ip link show "$lab_bridge_interface_name" &>/dev/null; then
        print_task "Removing IP addresses from $lab_bridge_interface_name..." nskip
        sudo ip addr flush dev "$lab_bridge_interface_name" 2>/dev/null || true
        print_task_done
    fi

    # ====== STEP 5: Remove dummy interface ======
    if ip link show "$lab_bridge_dummy_interface_name" &>/dev/null; then
        print_task "Removing dummy interface $lab_bridge_dummy_interface_name..." nskip
        sudo ip link set "$lab_bridge_dummy_interface_name" down 2>/dev/null || true
        sudo ip link del "$lab_bridge_dummy_interface_name" 2>/dev/null || true
        print_task_done
    fi

    # ====== STEP 6: Stop libvirtd ======
    print_task "Stopping libvirtd..." nskip
    if sudo systemctl stop libvirtd libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket 2>/dev/null; then
        print_task_done
    else
        print_task_fail
        failed_services_list+=("libvirtd")
    fi

    if [[ ${#failed_services_list[@]} -eq 0 ]]; then
        print_success "All lab services stopped successfully."
    else
        print_warning "Some services failed to stop: ${failed_services_list[*]}"
    fi
}

when_lab_infra_server_is_vm() {
    # ====== STEP 1: Shutdown all VMs (including infra server) ======
    shutdown_all_vms

    # ====== STEP 2: Stop libvirtd ======
    print_task "Stopping libvirtd..." nskip
    if sudo systemctl stop libvirtd libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket 2>/dev/null; then
        print_task_done
    else
        print_task_fail
        print_warning "Failed to stop libvirtd"
    fi

    print_success "Lab infrastructure stopped."
}

# ====== MAIN LOGIC ======

print_cyan "--------------------------------------------------------------"
print_info "KVM Lab Infrastructure Shutdown"
print_cyan "--------------------------------------------------------------"

if $lab_infra_server_mode_is_host; then
    print_notify "Lab Infra Server Mode: HOST ( $lab_infra_server_hostname )"
else
    print_notify "Lab Infra Server Mode: VM ( $lab_infra_server_hostname )"
fi
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

# Skip confirmation when called by systemd (TUX2LAB_SYSTEMD=true)
if [[ "${TUX2LAB_SYSTEMD:-}" != "true" ]]; then
    echo -n "Type CONFIRM to proceed: "
    read -r confirmation
    if [[ "${confirmation}" != "CONFIRM" ]]; then
        print_info "Operation cancelled."
        exit 0
    fi
fi

print_cyan "--------------------------------------------------------------"

if $lab_infra_server_mode_is_host; then
    when_lab_infra_server_is_host
else
    when_lab_infra_server_is_vm
fi

exit_code=$?

# Sync systemd service state when stopped interactively
if [[ "${TUX2LAB_SYSTEMD:-}" != "true" ]]; then
    if systemctl list-unit-files tux2lab-lab-infra.service &>/dev/null; then
        sudo systemctl stop tux2lab-lab-infra.service --no-block 2>/dev/null || true
    fi
fi

print_cyan "--------------------------------------------------------------"
exit $exit_code
