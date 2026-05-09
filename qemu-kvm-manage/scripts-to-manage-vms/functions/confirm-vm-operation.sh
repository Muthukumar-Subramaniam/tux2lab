#!/bin/bash
#
# confirm-vm-operation.sh
# 
# Shows confirmation prompt for VM operations
#
# Usage:
#   source /path/to/confirm-vm-operation.sh
#   confirm_vm_operation "operation_name" "description" "notify_message" vm_count [vm_list]
#
# Returns:
#   0 - User confirmed
#   1 - User cancelled

confirm_vm_operation() {
    local operation_name="$1"
    local description="$2"
    local notify_message="$3"
    local vm_count="$4"
    local vm_list="$5"
    
    if [[ -z "$operation_name" || -z "$description" || -z "$notify_message" ]]; then
        print_error "confirm_vm_operation: Missing required parameters."
        return 1
    fi
    
    if [[ "$vm_count" -gt 1 ]]; then
        print_warning "This will $description $vm_count VM(s): $vm_list"
    else
        print_warning "This will $description VM \"$vm_list\"."
    fi
    
    print_notify "$notify_message"
    read -p "Are you sure you want to continue? (yes/no): " confirmation
    echo -ne "\033[1A\033[2K"  # Move up one line and clear it
    
    if [[ "$confirmation" != "yes" ]]; then
        print_info "Operation cancelled by user."
        return 1
    fi
    
    return 0
}
