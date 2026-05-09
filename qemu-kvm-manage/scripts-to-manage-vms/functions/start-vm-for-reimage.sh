# start-vm-for-reimage.sh
# 
# Starts VM after reimage disk preparation
#
# Usage:
#   source /path/to/start-vm-for-reimage.sh
#   start_vm_for_reimage "vm-hostname" "reimage-description"
#
# Example:
#   start_vm_for_reimage "myvm" "reimaging via golden image disk"
#
# Returns:
#   0 - VM started successfully
#   1 - Failed to start VM

start_vm_for_reimage() {
    local vm_hostname="$1"
    local reimage_description="${2:-reimaging}"
    
    if [[ -z "$vm_hostname" ]]; then
        print_error "start_vm_for_reimage: VM hostname not provided."
        return 1
    fi
    
    print_task "Starting VM \"$vm_hostname\" (${reimage_description})..."
    if error_msg=$(sudo virsh start "$vm_hostname" 2>&1); then
        print_task_done
        return 0
    else
        print_task_fail
        print_error "Could not start VM \"$vm_hostname\"."
        print_error "$error_msg"
        return 1
    fi
}
