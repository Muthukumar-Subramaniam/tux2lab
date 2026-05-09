# delete-vm-disk.sh
# 
# Deletes existing VM qcow2 disk file
#
# Usage:
#   source /path/to/delete-vm-disk.sh
#   delete_vm_disk "vm-hostname"
#
# Returns:
#   0 - Always returns success (rm -f doesn't fail)

delete_vm_disk() {
    local vm_hostname="$1"
    
    if [[ -z "$vm_hostname" ]]; then
        print_error "delete_vm_disk: Missing VM hostname."
        return 1
    fi
    
    local vm_disk_path="/kvm-hub/vms/${vm_hostname}/${vm_hostname}.qcow2"
    sudo rm -f "${vm_disk_path}"
    
    return 0
}
