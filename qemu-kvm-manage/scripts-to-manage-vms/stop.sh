#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: stop.sh                                                                   #
# Description: Stop the KVM lab infrastructure and all essential services                 #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# ====== GLOBAL CONFIGURATION ======
lab_bridge_interface_name="labbr0"
force_stop=false

# ====== ARGUMENT PARSING ======
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force)
            force_stop=true
            shift
            ;;
        -h|--help)
            print_cyan "USAGE:
    tux2lab stop [options]

OPTIONS:
    -f, --force     Force stop all running VMs before stopping lab infra
    -h, --help      Show this help message"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ====== FORCE STOP ALL VMs ======
force_stop_all_vms() {
    local running_vms
    running_vms=$(sudo virsh list --state-running --name 2>/dev/null | grep -v "^$" | grep -v "^${lab_infra_server_hostname}$" || true)

    if [[ -z "$running_vms" ]]; then
        print_info "No running VMs to stop."
        return
    fi

    print_info "Force stopping all running VMs..."
    while IFS= read -r vm_name; do
        [[ -z "$vm_name" ]] && continue
        print_task "Force stopping VM \"$vm_name\"..." nskip
        if sudo virsh destroy "$vm_name" >/dev/null 2>&1; then
            print_task_done
        else
            print_task_fail
        fi
    done <<< "$running_vms"
}

when_lab_infra_server_is_host() {
    local lab_bridge_dummy_interface_name="dummy-vnet"
    local lab_essential_services=("nginx" "nfs-server" "tftp.socket" "kea-dhcp4" "kea-dhcp6" "radvd")

    # ====== STEP 0: Force stop all VMs if -f ======
    if $force_stop; then
        force_stop_all_vms
    fi

    # ====== STEP 1: Stop essential lab services ======
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

    # ====== STEP 2: Stop named ======
    print_task "Stopping named service..." nskip
    if sudo systemctl stop named 2>/dev/null; then
        print_task_done
    else
        print_task_fail
        failed_services_list+=("named")
    fi

    # ====== STEP 3: Remove IP addresses from labbr0 ======
    if ip link show "$lab_bridge_interface_name" &>/dev/null; then
        print_task "Removing IP addresses from $lab_bridge_interface_name..." nskip
        sudo ip addr flush dev "$lab_bridge_interface_name" 2>/dev/null || true
        print_task_done
    fi

    # ====== STEP 4: Remove dummy interface ======
    if ip link show "$lab_bridge_dummy_interface_name" &>/dev/null; then
        print_task "Removing dummy interface $lab_bridge_dummy_interface_name..." nskip
        sudo ip link set "$lab_bridge_dummy_interface_name" down 2>/dev/null || true
        sudo ip link del "$lab_bridge_dummy_interface_name" 2>/dev/null || true
        print_task_done
    fi

    # ====== STEP 5: Stop libvirtd ======
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
    # ====== STEP 0: Force stop all VMs if -f ======
    if $force_stop; then
        force_stop_all_vms
    fi

    # ====== STEP 1: Shutdown lab infra server VM ======
    if sudo virsh list --state-running | awk '{print $2}' | grep -Fxq "$lab_infra_server_hostname"; then
        print_task "Shutting down lab infra server VM..." nskip
        if sudo virsh shutdown "$lab_infra_server_hostname" >/dev/null 2>&1; then
            print_task_done
            # Wait for VM to actually shut down
            print_task "Waiting for VM to shut down..." nskip
            local shutdown_timeout=60
            local shutdown_elapsed=0
            while sudo virsh list --state-running | awk '{print $2}' | grep -Fxq "$lab_infra_server_hostname"; do
                if [[ $shutdown_elapsed -ge $shutdown_timeout ]]; then
                    print_task_fail
                    print_warning "VM did not shut down within ${shutdown_timeout}s. Force stopping..."
                    sudo virsh destroy "$lab_infra_server_hostname" >/dev/null 2>&1 || true
                    break
                fi
                sleep 2
                shutdown_elapsed=$((shutdown_elapsed + 2))
            done
            print_task_done
        else
            print_task_fail
            print_error "Failed to shut down lab infra server VM"
        fi
    else
        print_info "Lab infra server VM is not running."
    fi

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

print_warning "This will stop all lab infrastructure services."
if $force_stop; then
    print_warning "All running VMs will be FORCE STOPPED (immediate power off)."
fi
print_warning "VMs will lose access to DNS, DHCP, NFS, PXE, and Web services."
echo -n "Type CONFIRM to proceed: "
read -r confirmation
if [[ "${confirmation}" != "CONFIRM" ]]; then
    print_info "Operation cancelled."
    exit 0
fi

print_cyan "--------------------------------------------------------------"

if $lab_infra_server_mode_is_host; then
    when_lab_infra_server_is_host
else
    when_lab_infra_server_is_vm
fi

exit_code=$?
print_cyan "--------------------------------------------------------------"
exit $exit_code
