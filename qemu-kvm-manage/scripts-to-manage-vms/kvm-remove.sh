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
    print_cyan "USAGE:
    tux2lab vm remove [OPTIONS]

DESCRIPTION:
    Permanently delete one or more VMs and all associated data — disk images,
    DNS records, DHCP reservations, MAC cache, and kickstart configs.

OPTIONS:
    -H, --hosts <hosts>             Hostname(s) to remove (comma-separated)
    -f, --force                     Skip confirmation prompt
    --ignore-ksmanager-cleanup      Skip DNS/DHCP/MAC/kickstart cleanup
    --ksmanager-cleanup-only        Only clean ksmanager data (DNS, DHCP, MAC, kickstart)
    -h, --help                      Show this help message

EXAMPLES:
    tux2lab vm remove -H testvm1
    tux2lab vm remove -f -H testvm1,testvm2,testvm3
    tux2lab vm remove --ignore-ksmanager-cleanup -H testvm1
    tux2lab vm remove --ksmanager-cleanup-only -H testvm1
"
}

# Parse arguments
SUPPORTS_FORCE="yes"
SUPPORTS_IGNORE_KSMANAGER="yes"
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/parse-vm-control-args.sh
parse_vm_control_args "$@"

force_remove="$FORCE_FLAG"
ignore_ksmanager_cleanup="$IGNORE_KSMANAGER_CLEANUP"
ksmanager_cleanup_only="$KSMANAGER_CLEANUP_ONLY"
hosts_list="$HOSTS_LIST"
vm_hostname_arg="$VM_HOSTNAME_ARG"

# Function to remove a single VM
remove_vm() {
    local vm_name="$1"
    local skip_confirmation="${2:-false}"
    
    # --ksmanager-cleanup-only: only clean ksmanager data, skip VM operations
    if [[ "$ksmanager_cleanup_only" == true ]]; then
        print_info "Removing host '$vm_name' from all ksmanager databases..."
        if /tux2lab/ksmanager/ksmanager.sh "$vm_name" --remove-host; then
            return 0
        else
            print_warning "Could not clean up ksmanager databases for '$vm_name'."
            return 1
        fi
    fi

    # Check if VM exists in 'virsh list --all'
    print_task "Checking if VM exists..."
    if ! sudo virsh list --all | awk '{print $2}' | grep -Fxq "$vm_name"; then
        print_task_skip
        print_info "VM \"$vm_name\" does not exist."
        return 2
    fi
    print_task_done
    
    if [[ "$skip_confirmation" == false ]]; then
        print_warning "This will permanently delete VM \"$vm_name\" and all associated files!"
        read -rp "Are you sure you want to proceed? (YES/NO): " confirmation
        if [[ "$confirmation" != "YES" ]]; then
            print_info "Operation cancelled by user."
            return 3
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
    
    # Remove libvirt storage pool (virt-install auto-creates one per VM directory)
    if sudo virsh pool-info "$vm_name" &>/dev/null; then
        print_task "Removing storage pool..."
        sudo virsh pool-destroy "$vm_name" &>/dev/null || true
        if sudo virsh pool-undefine "$vm_name" &>/dev/null; then
            print_task_done
        else
            print_task_fail
            print_warning "Could not remove storage pool."
        fi
    fi
    
    # Remove from /etc/hosts
    if grep -q "${vm_name}" /etc/hosts 2>/dev/null; then
        print_task "Removing from /etc/hosts..."
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/update-etc-hosts.sh
        if remove_etc_hosts_entry "${vm_name}"; then
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
        if ! /tux2lab/ksmanager/ksmanager.sh "$vm_name" --remove-host; then
            print_warning "Could not clean up ksmanager databases."
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
    skipped_vms=()
    total_vms=${#validated_hosts[@]}
    current=0
    
    for vm_name in "${validated_hosts[@]}"; do
        ((++current))
        if [[ ${total_vms} -gt 1 ]]; then
            print_info "Processing VM ${current}/${total_vms}: ${vm_name}"
        fi
        # Pass true to skip individual confirmation (bulk confirmation already handled above)
        exit_code=0
        remove_vm "$vm_name" true || exit_code=$?
        if [[ $exit_code -eq 0 ]]; then
            successful_vms+=("$vm_name")
        elif [[ $exit_code -eq 2 || $exit_code -eq 3 ]]; then
            skipped_vms+=("$vm_name")
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

# Remove the VM
exit_code=0
remove_vm "$qemu_kvm_hostname" "$force_remove" || exit_code=$?
if [[ $exit_code -eq 0 ]]; then
    print_success "VM '$qemu_kvm_hostname' removed successfully."
    exit 0
elif [[ $exit_code -eq 2 || $exit_code -eq 3 ]]; then
    # VM doesn't exist (2) or user cancelled (3) — already printed info
    exit 0
else
    exit 1
fi