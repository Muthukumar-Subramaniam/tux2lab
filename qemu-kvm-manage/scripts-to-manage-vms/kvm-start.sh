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
    print_cyan "Usage: tux2lab vm start [OPTIONS]
Options:
  -H, --hosts <list>   Comma-separated list of VM hostnames to start
  -h, --help           Show this help message

Examples:
  tux2lab vm start -H vm1                    # Start single VM
  tux2lab vm start -H vm1,vm2,vm3            # Start multiple VMs
"
}

# Parse arguments
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/parse-vm-control-args.sh
parse_vm_control_args "$@"

hosts_list="$HOSTS_LIST"
vm_hostname_arg="$VM_HOSTNAME_ARG"

# Function to start a single VM
start_vm() {
    local vm_name="$1"
    
    print_task "Starting VM '$vm_name'..."
    
    # Check if VM exists in 'virsh list --all'
    if ! sudo virsh list --all | awk '{print $2}' | grep -Fxq "$vm_name"; then
        print_task_fail
        print_error "VM does not exist"
        return 1
    fi
    
    # Check if VM is already running
    if sudo virsh list | awk '{print $2}' | grep -Fxq "$vm_name"; then
        print_task_skip
        print_info "VM is already running"
        return 2
    fi
    
    # Start the VM
    if error_msg=$(sudo virsh start "$vm_name" 2>&1); then
        print_task_done
        return 0
    else
        print_task_fail
        print_error "$error_msg"
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
    
    # Start each VM
    failed_vms=()
    successful_vms=()
    skipped_vms=()
    total_vms=${#validated_hosts[@]}
    current=0
    
    for vm_name in "${validated_hosts[@]}"; do
        ((++current))
        print_info "Progress: $current/$total_vms"
        exit_code=0
        start_vm "$vm_name" || exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            successful_vms+=("$vm_name")
        elif [[ $exit_code -eq 2 ]]; then
            skipped_vms+=("$vm_name")
        else
            failed_vms+=("$vm_name")
        fi
    done
    
    # Print summary
    print_summary "Start VMs Results"
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

# Start the VM
rc=0
start_vm "$qemu_kvm_hostname" || rc=$?
if [[ $rc -eq 0 || $rc -eq 2 ]]; then
    exit 0
else
    exit 1
fi
