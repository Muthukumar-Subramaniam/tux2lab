# create-vm-directory.sh
# 
# Creates VM directory structure
#
# Usage:
#   source /path/to/create-vm-directory.sh
#   create_vm_directory "vm-hostname"
#
# Returns:
#   0 - Directory created successfully
#   1 - Failed to create directory

create_vm_directory() {
    local vm_hostname="$1"
    
    if [[ -z "$vm_hostname" ]]; then
        print_error "create_vm_directory: VM hostname not provided."
        return 1
    fi
    
    if ! mkdir -p "/kvm-hub/vms/${vm_hostname}"; then
        print_error "Failed to create VM directory: /kvm-hub/vms/${vm_hostname}"
        return 1
    fi
    
    return 0
}
