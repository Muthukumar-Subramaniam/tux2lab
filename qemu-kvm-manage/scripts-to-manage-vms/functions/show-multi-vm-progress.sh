# show-multi-vm-progress.sh
# 
# Displays progress counter for multi-VM operations
#
# Usage:
#   source /path/to/show-multi-vm-progress.sh
#   show_multi_vm_progress "vm-hostname"
#
# Uses global variables: CURRENT_VM, TOTAL_VMS
# Increments CURRENT_VM counter

show_multi_vm_progress() {
    local vm_hostname="$1"
    
    if [[ -z "$vm_hostname" ]]; then
        print_error "show_multi_vm_progress: VM hostname not provided."
        return 1
    fi
    
    ((CURRENT_VM++))
    
    if [[ ${TOTAL_VMS:-1} -gt 1 ]]; then
        print_info "Processing VM ${CURRENT_VM}/${TOTAL_VMS}: ${vm_hostname}"
    fi
    
    return 0
}
