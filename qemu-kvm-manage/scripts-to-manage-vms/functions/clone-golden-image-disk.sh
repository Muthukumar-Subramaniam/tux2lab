# clone-golden-image-disk.sh
# 
# Clones golden image disk to VM directory with verification
#
# Usage:
#   source /path/to/clone-golden-image-disk.sh
#   clone_golden_image_disk "vm-hostname" "os-distro" "version-type"
#
# Returns:
#   0 - Disk cloned successfully
#   1 - Failed to clone disk

clone_golden_image_disk() {
    local vm_hostname="$1"
    local os_distro="$2"
    local version="$3"
    
    if [[ -z "$vm_hostname" || -z "$os_distro" || -z "$version" ]]; then
        print_error "clone_golden_image_disk: Missing required parameters."
        return 1
    fi
    
    # Construct golden image FQDN matching ksmanager's format
    local golden_image_fqdn="${os_distro}-golden-image-${version}.${lab_infra_domain_name}"
    local golden_image_path="/tux2lab-data/golden-images-disk-store/${golden_image_fqdn}.qcow2"
    local vm_disk_path="/tux2lab-data/vms/${vm_hostname}/${vm_hostname}.qcow2"
    
    print_task "Cloning golden image disk for '${vm_hostname}'..."
    
    if error_msg=$(sudo qemu-img convert -O qcow2 "${golden_image_path}" "${vm_disk_path}" 2>&1); then
        # Verify the cloned disk exists and has size
        if [[ -f "${vm_disk_path}" ]] && \
           [[ $(stat -c%s "${vm_disk_path}" 2>/dev/null || echo 0) -gt 0 ]]; then
            print_task_done
            return 0
        else
            print_task_fail
            print_error "Disk file was not created properly for \"$vm_hostname\"."
            sudo rm -f "${vm_disk_path}"
            return 1
        fi
    else
        print_task_fail
        print_error "$error_msg"
        sudo rm -f "${vm_disk_path}"
        return 1
    fi
}
