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
    print_cyan "Usage: tux2lab vm shutdown [OPTIONS] [hostname]
Options:
  -f, --force          Skip confirmation prompt and force graceful shutdown
  -H, --hosts <list>   Comma-separated list of VM hostnames to shutdown
  -h, --help           Show this help message

Arguments:
  hostname             Name of the VM to gracefully shutdown (optional, will prompt if not given)

Examples:
  tux2lab vm shutdown vm1                    # Shutdown single VM with confirmation
  tux2lab vm shutdown -f vm1                 # Shutdown single VM without confirmation
  tux2lab vm shutdown --hosts vm1,vm2,vm3    # Shutdown multiple VMs with confirmation
  tux2lab vm shutdown -f --hosts vm1,vm2     # Shutdown multiple VMs without confirmation
"
}

# Parse arguments
SUPPORTS_FORCE="yes"
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/parse-vm-control-args.sh
parse_vm_control_args "$@"

force_shutdown="$FORCE_FLAG"
hosts_list="$HOSTS_LIST"
vm_hostname_arg="$VM_HOSTNAME_ARG"

# Source the shutdown function
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/shutdown-vm.sh

# Wrapper function for consistent output
shutdown_vm_wrapper() {
    local vm_name="$1"
    
    print_task "Shutting down VM '$vm_name'..."
    
    # Check if VM exists in 'virsh list --all'
    if ! sudo virsh list --all | awk '{print $2}' | grep -Fxq "$vm_name"; then
        print_task_fail
        print_error "VM does not exist"
        return 1
    fi
    
    # Check if VM is running
    if ! sudo virsh list | awk '{print $2}' | grep -Fxq "$vm_name"; then
        print_task_skip
        print_info "VM is not running (already stopped)"
        return 2
    fi
    
    # Send shutdown signal
    if error_msg=$(sudo virsh shutdown "$vm_name" 2>&1); then
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
    
    # Warning prompt unless force flag is used
    if [[ "$force_shutdown" == false ]]; then
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/confirm-vm-operation.sh
        if ! confirm_vm_operation "shutdown" "send graceful shutdown signal to" "Guest OS will attempt to shutdown cleanly (requires guest tools)." "${#validated_hosts[@]}" "${validated_hosts[*]}"; then
            exit 0
        fi
    fi
    
    # Shutdown each VM
    failed_vms=()
    successful_vms=()
    skipped_vms=()
    total_vms=${#validated_hosts[@]}
    current=0
    
    for vm_name in "${validated_hosts[@]}"; do
        ((++current))
        print_info "Progress: $current/$total_vms"
        shutdown_vm_wrapper "$vm_name"
        exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            successful_vms+=("$vm_name")
        elif [[ $exit_code -eq 2 ]]; then
            skipped_vms+=("$vm_name")
        else
            failed_vms+=("$vm_name")
        fi
    done
    
    # Print summary
    print_summary "Shutdown VMs Results"
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
    print_warning "You are about to shutdown the lab infra server: $lab_infra_server_hostname!"
    print_warning "This will stop all lab services (DNS, DHCP, NFS, TFTP, Web)."
    print_warning "All VMs in the lab will lose connectivity to these services."
    read -r -p "If you understand the impact, confirm by typing 'shutdown-lab-infra-server': " confirmation
    if [[ "$confirmation" != "shutdown-lab-infra-server" ]]; then
        print_info "Operation cancelled by user."
        exit 1
    fi
elif [[ "$force_shutdown" == false ]]; then
    # Warning prompt unless force flag is used
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/confirm-vm-operation.sh
    if ! confirm_vm_operation "shutdown" "send graceful shutdown signal to" "Guest OS will attempt to shutdown cleanly (requires guest tools)." 1 "$qemu_kvm_hostname"; then
        exit 0
    fi
fi
# Shutdown the VM
if shutdown_vm_wrapper "$qemu_kvm_hostname"; then
    exit 0
else
    exit 1
fi