#!/bin/bash
#
# check-lab-infra-protection.sh
# 
# Prevents reimaging of the lab infrastructure server VM
#
# Usage:
#   source /path/to/check-lab-infra-protection.sh
#   check_lab_infra_protection "vm-hostname"
#
# Returns:
#   0 - VM is not the lab infra server (safe to proceed)
#   1 - VM is the lab infra server (operation blocked)

check_lab_infra_protection() {
    local vm_hostname="$1"
    local total_vms="${TOTAL_VMS:-1}"
    
    if [[ -z "$vm_hostname" ]]; then
        print_error "check_lab_infra_protection: VM hostname not provided."
        return 1
    fi
    
    if [[ "$vm_hostname" == "$lab_infra_server_hostname" ]]; then
        print_error "Cannot reimage Lab Infra Server!"
        print_warning "You are attempting to reimage the lab infrastructure server VM: $lab_infra_server_hostname"
        print_info "This VM hosts critical services and must not be destroyed."
        if [[ $total_vms -eq 1 ]]; then
            exit 1
        fi
        return 1
    fi
    
    return 0
}
