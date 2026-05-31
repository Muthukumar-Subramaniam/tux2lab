#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# Function to show help
fn_show_help() {
    print_cyan "Usage: tux2lab vm stop [OPTIONS]
Options:
  -H, --hosts <list>   Comma-separated list of VM hostnames to stop
  -f, --force          Skip confirmation prompt and force power-off
  -h, --help           Show this help message

Examples:
  tux2lab vm stop -H vm1                    # Stop single VM with confirmation
  tux2lab vm stop -f -H vm1                 # Stop single VM without confirmation
  tux2lab vm stop -H vm1,vm2,vm3            # Stop multiple VMs with confirmation
  tux2lab vm stop -f -H vm1,vm2             # Stop multiple VMs without confirmation
"
}

# Parse arguments
SUPPORTS_FORCE="yes"
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/parse-vm-control-args.sh
parse_vm_control_args "$@"

force_stop="$FORCE_FLAG"
hosts_list="$HOSTS_LIST"
vm_hostname_arg="$VM_HOSTNAME_ARG"

# Function to stop a single VM
stop_vm() {
    local vm_name="$1"
    
    print_task "Stopping VM '$vm_name'..."
    
    # Check if VM exists in 'virsh list --all'
    if ! sudo virsh list --all | awk '{print $2}' | grep -Fxq "$vm_name"; then
        print_task_fail
        print_error "VM does not exist"
        return 1
    fi
    
    # Check if VM exists in 'virsh list'
    if ! sudo virsh list | awk '{print $2}' | grep -Fxq "$vm_name"; then
        print_task_skip
        print_info "VM is not running (already stopped)"
        return 2
    fi
    
    # Proceed with Stop
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/poweroff-vm.sh
    if POWEROFF_VM_CONTEXT="Stopping" POWEROFF_VM_STRICT=true poweroff_vm "$vm_name" &>/dev/null; then
        print_task_done
        return 0
    else
        print_task_fail
        print_error "Failed to power off VM"
        return 1
    fi
}

# Handle multiple hosts
if [[ -n "$hosts_list" ]]; then
    IFS=',' read -ra hosts_array <<< "$hosts_list"
    
    # Check if hosts list is empty
    if [[ ${#hosts_array[@]} -eq 0 ]]; then
        print_error "No hostnames provided in --hosts list."
        exit 1
    fi
    
    # Validate and normalize hostnames
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/validate-and-process-hostnames.sh
    if ! validate_and_process_hostnames hosts_array; then
        exit 1
    fi
    
    validated_hosts=("${VALIDATED_HOSTS[@]}")
    
    # Warning prompt unless force flag is used
    if [[ "$force_stop" == false ]]; then
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/confirm-vm-operation.sh
        if ! confirm_vm_operation "stop" "forcefully power off" "This is equivalent to pulling the power plug (may cause data loss)." "${#validated_hosts[@]}" "${validated_hosts[*]}"; then
            exit 0
        fi
    fi
    
    # Stop each VM
    failed_vms=()
    successful_vms=()
    skipped_vms=()
    total_vms=${#validated_hosts[@]}
    current=0
    
    for vm_name in "${validated_hosts[@]}"; do
        ((++current))
        print_info "Progress: $current/$total_vms"
        exit_code=0
        stop_vm "$vm_name" || exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            successful_vms+=("$vm_name")
        elif [[ $exit_code -eq 2 ]]; then
            skipped_vms+=("$vm_name")
        else
            failed_vms+=("$vm_name")
        fi
    done
    
    # Print summary
    print_summary "Stop VMs Results"
    if [[ ${#successful_vms[@]} -gt 0 ]]; then
        print_green "  DONE: ${#successful_vms[@]}/$total_vms"
        for vm in "${successful_vms[@]}"; do
            print_green "    - $vm"
        done
    fi
    if [[ ${#skipped_vms[@]} -gt 0 ]]; then
        print_yellow "  SKIP: ${#skipped_vms[@]}/$total_vms"
        for vm in "${skipped_vms[@]}"; do
            print_yellow "    - $vm"
        done
    fi
    if [[ ${#failed_vms[@]} -gt 0 ]]; then
        print_red "  FAIL: ${#failed_vms[@]}/$total_vms"
        for vm in "${failed_vms[@]}"; do
            print_red "    - $vm"
        done
    fi
    
    # Exit with appropriate code
    if [[ ${#failed_vms[@]} -eq 0 ]]; then
        exit 0
    else
        exit 1
    fi
fi

# Handle single host
# Use argument or prompt for hostname
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/input-hostname.sh "$vm_hostname_arg"

# Lab infra server protection
if [[ "$qemu_kvm_hostname" == "$lab_infra_server_hostname" ]]; then
    print_warning "You are about to forcefully power off the lab infra server: $lab_infra_server_hostname!"
    print_warning "This will immediately stop all lab services (DNS, DHCP, NFS, TFTP, Web)."
    print_warning "All VMs in the lab will lose connectivity to these services."
    read -r -p "If you understand the impact, confirm by typing 'stop-lab-infra-server': " confirmation
    if [[ "$confirmation" != "stop-lab-infra-server" ]]; then
        print_info "Operation cancelled by user."
        exit 1
    fi
elif [[ "$force_stop" == false ]]; then
    # Warning prompt unless force flag is used
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/confirm-vm-operation.sh
    if ! confirm_vm_operation "stop" "forcefully power off" "This is equivalent to pulling the power plug (may cause data loss)." 1 "$qemu_kvm_hostname"; then
        exit 0
    fi
fi
# Stop the VM
rc=0
stop_vm "$qemu_kvm_hostname" || rc=$?
if [[ $rc -eq 0 || $rc -eq 2 ]]; then
    exit 0
else
    exit 1
fi
