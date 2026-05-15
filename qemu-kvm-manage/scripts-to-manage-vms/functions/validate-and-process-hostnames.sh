#!/bin/bash
#
# validate-and-process-hostnames.sh
# 
# Validates, normalizes, and removes duplicates from hostname list
#
# Usage:
#   source /path/to/validate-and-process-hostnames.sh
#   validate_and_process_hostnames hosts_array[@]
#   # Result available in: VALIDATED_HOSTS array
#
# Sets global array:
#   VALIDATED_HOSTS - Array of validated, normalized, unique hostnames

validate_and_process_hostnames() {
    local -n input_array=$1
    
    # Validate and normalize all hostnames
    local validated_hosts=()
    local invalid_hosts=()
    for vm_name in "${input_array[@]}"; do
        vm_name=${vm_name// /}  # Trim all whitespace
        [[ -z "$vm_name" ]] && continue  # Skip empty entries
        # Validate and normalize inline (input-hostname.sh uses exit 1 which would kill the batch)
        local normalized=""
        if [[ "${vm_name}" == *.${lab_infra_domain_name} ]]; then
            local stripped="${vm_name%.${lab_infra_domain_name}}"
            if [[ "${stripped}" == *.* ]] || [[ ! "${stripped}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
                invalid_hosts+=("$vm_name")
                continue
            fi
            normalized="${vm_name}"
        elif [[ "${vm_name}" == *.* ]]; then
            invalid_hosts+=("$vm_name")
            continue
        else
            if [[ ! "${vm_name}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
                invalid_hosts+=("$vm_name")
                continue
            fi
            normalized="${vm_name}.${lab_infra_domain_name}"
        fi
        validated_hosts+=("$normalized")
    done
    
    # Fail if any hostnames were invalid
    if [[ ${#invalid_hosts[@]} -gt 0 ]]; then
        print_error "Invalid hostname(s) found:"
        for h in "${invalid_hosts[@]}"; do
            print_error "  - $h"
        done
        print_info "Hostnames must contain only lowercase letters, numbers, and hyphens."
        print_info "Domain must be '${lab_infra_domain_name}' or omitted (will be appended automatically)."
        return 1
    fi
    
    # Check if any valid hosts remain after validation
    if [[ ${#validated_hosts[@]} -eq 0 ]]; then
        print_error "No valid hostnames provided in --hosts list."
        return 1
    fi
    
    # Remove duplicates while preserving order
    declare -A seen_hosts
    local unique_hosts=()
    for vm_name in "${validated_hosts[@]}"; do
        if [[ -z "${seen_hosts[$vm_name]+x}" ]]; then
            seen_hosts[$vm_name]=1
            unique_hosts+=("$vm_name")
        fi
    done
    
    # Check if duplicates were found
    if [[ ${#unique_hosts[@]} -lt ${#validated_hosts[@]} ]]; then
        local duplicate_count=$((${#validated_hosts[@]} - ${#unique_hosts[@]}))
        print_warning "Removed $duplicate_count duplicate hostname(s) from the list."
    fi
    
    # Export result
    VALIDATED_HOSTS=("${unique_hosts[@]}")
    return 0
}
