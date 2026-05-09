# get-current-disk-size.sh
# 
# Extracts current disk size from existing VM disk
#
# Usage:
#   source /path/to/get-current-disk-size.sh
#   get_current_disk_size "vm-hostname"
#   echo "$CURRENT_DISK_SIZE"  # Size in GiB
#
# Returns:
#   0 - Size extracted successfully
#   1 - Failed to extract size
#
# Sets global variable:
#   CURRENT_DISK_SIZE - disk size in GiB (integer)

get_current_disk_size() {
    local vm_hostname="$1"
    
    if [[ -z "$vm_hostname" ]]; then
        print_error "get_current_disk_size: Missing VM hostname."
        return 1
    fi
    
    local vm_disk_path="/kvm-hub/vms/${vm_hostname}/${vm_hostname}.qcow2"
    
    if [ ! -f "${vm_disk_path}" ]; then
        print_warning "VM disk not found at: ${vm_disk_path}"
        CURRENT_DISK_SIZE=""
        return 1
    fi
    
    # Extract disk size from qemu-img info output
    CURRENT_DISK_SIZE=$(sudo qemu-img info "${vm_disk_path}" 2>/dev/null | awk '/virtual size/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $(i+1)=="GiB") {print $i; exit}}')
    
    if [[ -z "$CURRENT_DISK_SIZE" ]]; then
        print_warning "Could not determine current disk size for \"$vm_hostname\"."
        return 1
    fi
    
    return 0
}
