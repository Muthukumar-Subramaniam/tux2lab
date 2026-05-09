# start-vm-installation.sh
# 
# Starts VM installation using default-vm-install function with error handling
#
# Usage:
#   source /path/to/start-vm-installation.sh
#   start_vm_installation "vm-hostname" "installation-description"
#
# Example:
#   start_vm_installation "myvm" "installation via golden image disk"
#
# Returns:
#   0 - VM installation started successfully
#   1 - Failed to start VM installation

start_vm_installation() {
    local vm_hostname="$1"
    local install_description="${2:-VM installation}"
    
    if [[ -z "$vm_hostname" ]]; then
        print_error "start_vm_installation: VM hostname not provided."
        return 1
    fi
    
    print_info "Starting VM installation of \"$vm_hostname\" via ${install_description}..."
    if ! virt_install_output=$(source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/default-vm-install.sh 2>&1); then
        print_error "Failed to start VM installation for \"$vm_hostname\"."
        if [[ -n "$virt_install_output" ]]; then
            print_error "$virt_install_output"
        fi
        return 1
    fi
    
    return 0
}
