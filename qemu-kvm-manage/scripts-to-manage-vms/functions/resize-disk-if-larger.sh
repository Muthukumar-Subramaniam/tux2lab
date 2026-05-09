# resize-disk-if-larger.sh
# 
# Resizes VM disk if current size is larger than base disk size
#
# Usage:
#   source /path/to/resize-disk-if-larger.sh
#   resize_disk_if_larger "vm-hostname" current_size_gib base_size_gib
#
# Returns:
#   0 - Always returns success (resize is optional)

resize_disk_if_larger() {
    local vm_hostname="$1"
    local current_disk_gib="$2"
    local base_disk_gib="$3"
    
    if [[ -z "$vm_hostname" || -z "$current_disk_gib" || -z "$base_disk_gib" ]]; then
        print_error "resize_disk_if_larger: Missing required parameters."
        return 1
    fi
    
    local vm_disk_path="/kvm-hub/vms/${vm_hostname}/${vm_hostname}.qcow2"
    
    if [[ "$current_disk_gib" -gt "$base_disk_gib" ]]; then
        if sudo qemu-img resize "${vm_disk_path}" "${current_disk_gib}G" >/dev/null 2>&1; then
            print_info "Retained OS disk size of ${current_disk_gib} GiB for VM \"$vm_hostname\"."
        fi
    fi
    
    return 0
}
