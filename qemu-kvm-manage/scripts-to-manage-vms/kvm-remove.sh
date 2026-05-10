#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

ETC_HOSTS_FILE='/etc/hosts'

# Function to show help
fn_show_help() {
    print_cyan "Usage: tux2lab vm remove [OPTIONS] [hostname]
Options:
  -f, --force                      Skip confirmation prompt (except for lab infra server)
  --ignore-ksmanager-cleanup       Skip cleanup of ksmanager databases (DNS, MAC, kickstart, iPXE, DHCP)
  -H, --hosts <list>               Comma-separated list of VM hostnames to remove
  -h, --help                       Show this help message

Arguments:
  hostname                         Name of the VM to be deleted permanently (optional, will prompt if not given)

Examples:
  tux2lab vm remove vm1                             # Remove single VM with confirmation
  tux2lab vm remove -f vm1                          # Remove single VM without confirmation
  tux2lab vm remove --ignore-ksmanager-cleanup vm1  # Remove VM but keep ksmanager data
  tux2lab vm remove --hosts vm1,vm2,vm3             # Remove multiple VMs with confirmation
  tux2lab vm remove -f --hosts vm1,vm2              # Remove multiple VMs without confirmation

Note: Lab infra server always requires special confirmation regardless of -f flag.
"
}

# Parse arguments
SUPPORTS_FORCE="yes"
SUPPORTS_IGNORE_KSMANAGER="yes"
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/parse-vm-control-args.sh
parse_vm_control_args "$@"

force_remove="$FORCE_FLAG"
ignore_ksmanager_cleanup="$IGNORE_KSMANAGER_CLEANUP"
hosts_list="$HOSTS_LIST"
vm_hostname_arg="$VM_HOSTNAME_ARG"

# Function to remove a single VM
remove_vm() {
    local vm_name="$1"
    local skip_confirmation="${2:-false}"
    
    # Check if VM exists in 'virsh list --all'
    print_task "Checking if VM exists..."
    if ! sudo virsh list --all | awk '{print $2}' | grep -Fxq "$vm_name"; then
        print_task_fail
        print_error "VM \"$vm_name\" does not exist."
        return 1
    fi
    print_task_done
    
    # Special confirmation for lab infra server (always required)
    if [[ "$vm_name" == "$lab_infra_server_hostname" ]]; then
        print_warning "You are about to delete your lab infra server VM: $lab_infra_server_hostname!"
        read -r -p "If you know what you are doing, confirm by typing 'delete-lab-infra-server': " confirmation
        if [[ "$confirmation" != "delete-lab-infra-server" ]]; then
            print_info "Operation cancelled by user."
            return 1
        fi
    elif [[ "$skip_confirmation" == false ]]; then
        # Regular confirmation for other VMs
        print_warning "This will permanently delete VM \"$vm_name\" and all associated files!"
        read -rp "Are you sure you want to proceed? (yes/no): " confirmation
        if [[ "$confirmation" != "yes" ]]; then
            print_info "Operation cancelled by user."
            return 1
        fi
    fi
    
    # Stop VM if running
    if sudo virsh list | awk '{print $2}' | grep -Fxq "$vm_name"; then
        print_task "Stopping VM..."
        if sudo virsh destroy "$vm_name" &>/dev/null; then
            print_task_done
        else
            print_task_fail
            print_warning "Could not stop VM (may already be stopped)."
        fi
    fi
    
    # Undefine VM
    print_task "Undefining VM from libvirt..."
    if ! error_msg=$(sudo virsh undefine "$vm_name" --nvram 2>&1); then
        print_task_fail
        print_error "$error_msg"
        return 1
    fi
    print_task_done
    
    # Remove VM directory
    if [[ -n "$vm_name" ]] && [[ -d "/tux2lab-data/vms/$vm_name" ]]; then
        print_task "Removing VM directory..."
        if sudo rm -rf "/tux2lab-data/vms/$vm_name" 2>/dev/null; then
            print_task_done
        else
            print_task_fail
            print_warning "Could not remove VM directory."
        fi
    fi
    
    # Remove from /etc/hosts (escape dots for regex)
    local escaped_vm_name="${vm_name//./\\.}"
    if grep -q "${vm_name}" "$ETC_HOSTS_FILE" 2>/dev/null; then
        print_task "Removing from /etc/hosts..."
        if sudo sed -i.bak "/[[:space:]]${escaped_vm_name}$/d" "$ETC_HOSTS_FILE" 2>/dev/null; then
            print_task_done
        else
            print_task_fail
            print_warning "Could not update /etc/hosts."
        fi
    fi
    
    # Clean up ksmanager databases (DNS, MAC cache, kickstart, iPXE, DHCP)
    if [[ "$ignore_ksmanager_cleanup" == true ]]; then
        print_info "Skipping ksmanager cleanup (--ignore-ksmanager-cleanup flag)."
    else
        if $lab_infra_server_mode_is_host; then
            if ! /tux2lab/ks-manage/ksmanager.sh "$vm_name" --remove-host; then
                print_warning "Could not clean up ksmanager databases."
            fi
        else
            if ! ssh -o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${lab_infra_admin_username}@${lab_infra_server_hostname}" "/tux2lab/ks-manage/ksmanager.sh $vm_name --remove-host"; then
                print_warning "Could not clean up ksmanager databases."
            fi
        fi
    fi
    
    return 0
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
    
    # Warning prompt unless force flag is used (but each VM will have its own confirmation)
    if [[ "$force_remove" == false ]]; then
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/confirm-vm-operation.sh
        if ! confirm_vm_operation "remove" "permanently delete" "All VM data and associated files will be removed." "${#validated_hosts[@]}" "${validated_hosts[*]}"; then
            exit 0
        fi
    fi
    
    # Remove each VM
    failed_vms=()
    successful_vms=()
    total_vms=${#validated_hosts[@]}
    current=0
    
    for vm_name in "${validated_hosts[@]}"; do
        ((current++))
        print_info "Progress: $current/$total_vms"
        # Pass true to skip individual confirmation if force flag is set
        if remove_vm "$vm_name" "$force_remove"; then
            successful_vms+=("$vm_name")
        else
            failed_vms+=("$vm_name")
        fi
    done
    
    # Print summary
    print_summary "Remove VMs Results"
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

# Remove the VM
if remove_vm "$qemu_kvm_hostname" "$force_remove"; then
    print_success "VM '$qemu_kvm_hostname' removed successfully."
    exit 0
else
    exit 1
fi