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
    print_cyan "Usage: tux2lab vm restart [OPTIONS] [hostname]
Options:
  -f, --force          Skip confirmation prompt and force cold restart
  -H, --hosts <list>   Comma-separated list of VM hostnames to restart
  -h, --help           Show this help message

Arguments:
  hostname             Name of the VM to do cold restart (optional, will prompt if not given)

Examples:
  tux2lab vm restart vm1                    # Restart single VM with confirmation
  tux2lab vm restart -f vm1                 # Restart single VM without confirmation
  tux2lab vm restart --hosts vm1,vm2,vm3    # Restart multiple VMs with confirmation
  tux2lab vm restart -f --hosts vm1,vm2     # Restart multiple VMs without confirmation
"
}

# Parse arguments
SUPPORTS_FORCE="yes"
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/parse-vm-control-args.sh
parse_vm_control_args "$@"

force_restart="$FORCE_FLAG"
hosts_list="$HOSTS_LIST"
vm_hostname_arg="$VM_HOSTNAME_ARG"

# Function to restart a single VM
restart_vm() {
    local vm_name="$1"
    
    print_task "Restarting VM '$vm_name'..."
    
    # Check if VM exists in 'virsh list --all'
    if ! sudo virsh list --all | awk '{print $2}' | grep -Fxq "$vm_name"; then
        print_task_fail
        print_error "VM does not exist"
        return 1
    fi
    
    # Check if VM is running
    if ! sudo virsh list | awk '{print $2}' | grep -Fxq "$vm_name"; then
        print_task_fail
        print_error "VM is not running"
        print_info "If you want to start the VM, use: tux2lab vm start $vm_name"
        return 1
    fi
    
    # Perform cold restart (reset)
    if error_msg=$(sudo virsh reset "$vm_name" 2>&1); then
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
    if [[ "$force_restart" == false ]]; then
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/confirm-vm-operation.sh
        if ! confirm_vm_operation "restart" "perform cold restart on" "This is equivalent to pressing the reset button (may cause data loss)." "${#validated_hosts[@]}" "${validated_hosts[*]}"; then
            exit 0
        fi
    fi
    
    # Restart each VM
    failed_vms=()
    successful_vms=()
    total_vms=${#validated_hosts[@]}
    current=0
    
    for vm_name in "${validated_hosts[@]}"; do
        ((current++))
        print_info "Progress: $current/$total_vms"
        if restart_vm "$vm_name"; then
            successful_vms+=("$vm_name")
        else
            failed_vms+=("$vm_name")
        fi
    done
    
    # Print summary
    print_summary "Restart VMs Results"
    if [[ ${#successful_vms[@]} -gt 0 ]]; then
        print_green "  DONE: ${#successful_vms[@]}/$total_vms"
        for vm in "${successful_vms[@]}"; do
            print_green "    - $vm"
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
    print_warning "You are about to hard restart the lab infra server: $lab_infra_server_hostname!"
    print_warning "This will abruptly restart all lab services (DNS, DHCP, NFS, TFTP, Web)."
    print_warning "All VMs in the lab will experience service interruption."
    read -r -p "If you understand the impact, confirm by typing 'restart-lab-infra-server': " confirmation
    if [[ "$confirmation" != "restart-lab-infra-server" ]]; then
        print_info "Operation cancelled by user."
        exit 1
    fi
elif [[ "$force_restart" == false ]]; then
    # Warning prompt unless force flag is used
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/confirm-vm-operation.sh
    if ! confirm_vm_operation "restart" "perform cold restart on" "This is equivalent to pressing the reset button (may cause data loss)." 1 "$qemu_kvm_hostname"; then
        exit 0
    fi
fi
# Restart the VM
if restart_vm "$qemu_kvm_hostname"; then
    exit 0
else
    exit 1
fi