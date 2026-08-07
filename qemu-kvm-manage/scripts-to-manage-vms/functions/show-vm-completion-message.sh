################################################################################
# Function: show_vm_completion_message
# Description: Show completion message for single VM operations
# Parameters:
#   $1 - VM hostname
#   $2 - Attach console flag ("yes" or "no")
#   $3 - Total VMs count
#   $4 - Operation description (e.g., "installation via golden image disk")
#   $5 - Time/duration message (e.g., "takes ~1 minute")
# Returns:
#   0 - Success
################################################################################

show_vm_completion_message() {
    local vm_hostname="$1"
    local attach_console="$2"
    local total_vms="$3"
    local operation_desc="$4"
    local time_message="$5"

    if [[ "$attach_console" == "yes" ]]; then
        print_info "Attaching to VM console. Press Ctrl+] to exit console."
        sudo virsh console "${vm_hostname}"
    elif [[ $total_vms -eq 1 ]]; then
        print_success "VM \"${vm_hostname}\" ${operation_desc} initiated successfully."
        if [[ -n "$time_message" ]]; then
            print_yellow "    ▸ ${time_message}"
        fi
        print_yellow "    ▸ To monitor progress: tux2lab vm console -H ${vm_hostname}"
        print_yellow "    ▸ To check VM status:  tux2lab vm list"
    fi

    return 0
}
