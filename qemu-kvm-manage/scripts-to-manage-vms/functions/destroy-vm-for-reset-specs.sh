# destroy-vm-for-reset-specs.sh
# 
# Destroys VM completely for reinstall with default specs (undefine + delete directory)
#
# Usage:
#   source /path/to/destroy-vm-for-reset-specs.sh
#   destroy_vm_for_reset_specs "vm-hostname"
#
# Returns:
#   0 - VM destroyed successfully
#   1 - Failed to destroy VM

destroy_vm_for_reset_specs() {
    local vm_hostname="$1"
    
    if [[ -z "$vm_hostname" ]]; then
        print_error "destroy_vm_for_reset_specs: VM hostname not provided."
        return 1
    fi
    
    # Undefine the VM
    print_task "Undefining VM \"$vm_hostname\"..."
    if error_msg=$(sudo virsh undefine "$vm_hostname" --nvram 2>&1); then
        print_task_done
    else
        print_task_fail
        print_error "$error_msg"
        return 1
    fi
    
    # Delete VM folder and contents
    print_task "Deleting VM folder /tux2lab-data/vms/${vm_hostname}..."
    if sudo rm -rf "/tux2lab-data/vms/${vm_hostname}"; then
        print_task_done
    else
        print_task_fail
        return 1
    fi
    
    return 0
}
