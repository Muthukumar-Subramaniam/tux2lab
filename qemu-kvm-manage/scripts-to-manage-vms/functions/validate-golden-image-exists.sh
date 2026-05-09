# validate-golden-image-exists.sh
# 
# Validates that golden image disk exists for given OS distro
#
# Usage:
#   source /path/to/validate-golden-image-exists.sh
#   validate_golden_image_exists "vm-hostname" "os-distro" "version-type"
#
# Returns:
#   0 - Golden image exists
#   1 - Golden image not found

validate_golden_image_exists() {
    local vm_hostname="$1"
    local os_distro="$2"
    local version="$3"
    
    if [[ -z "$vm_hostname" || -z "$os_distro" || -z "$version" ]]; then
        print_error "validate_golden_image_exists: Missing required parameters."
        return 1
    fi
    
    # Construct golden image FQDN matching ksmanager's format
    local golden_image_fqdn="${os_distro}-golden-image-${version}.${lab_infra_domain_name}"
    local golden_image_path="/tux2lab-data/golden-images-disk-store/${golden_image_fqdn}.qcow2"
    
    if [ ! -f "${golden_image_path}" ]; then
        print_error "Golden image disk not found for \"$vm_hostname\"!"
        print_info "Expected at: ${golden_image_path}"
        print_info "To build the golden image disk, run: tux2lab vm build-golden-image"
        return 1
    fi
    
    return 0
}
