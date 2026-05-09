# confirm-reimage-operation.sh
# 
# Prompts user for confirmation before reimaging a VM (unless --force flag is used)
#
# Usage:
#   source /path/to/confirm-reimage-operation.sh
#   confirm_reimage_operation "vm-hostname" "golden image" # or "PXE boot"
#
# Environment Variables:
#   FORCE_REIMAGE - Set to "true" to skip confirmation prompt
#
# Returns:
#   0 - User confirmed or force flag is set
#   (exits if user declined)

confirm_reimage_operation() {
    local vm_hostname="$1"
    local reimage_method="$2"  # "golden image" or "PXE boot"
    local total_vms="${TOTAL_VMS:-1}"
    
    if [[ -z "$vm_hostname" || -z "$reimage_method" ]]; then
        print_error "confirm_reimage_operation: Missing required parameters."
        exit 1
    fi
    
    # Skip confirmation if force flag is set
    if [[ "${FORCE_REIMAGE}" == "true" ]]; then
        return 0
    fi
    
    print_warning "This will reimage VM \"$vm_hostname\" using $reimage_method!"
    print_warning "All existing data on this VM will be permanently lost."
    read -rp "Are you sure you want to proceed? (yes/no): " confirmation
    if [[ "$confirmation" != "yes" ]]; then
        print_info "Reimage of \"$vm_hostname\" skipped by user."
        return 1
    fi
    
    return 0
}
