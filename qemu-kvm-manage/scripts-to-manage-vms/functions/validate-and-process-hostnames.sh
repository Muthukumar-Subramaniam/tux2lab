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
    for vm_name in "${input_array[@]}"; do
        vm_name=${vm_name// /}  # Trim all whitespace
        [[ -z "$vm_name" ]] && continue  # Skip empty entries
        # Use input-hostname.sh to validate and normalize
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/input-hostname.sh "$vm_name"
        validated_hosts+=("$qemu_kvm_hostname")
    done
    
    # Check if any valid hosts remain after validation
    if [[ ${#validated_hosts[@]} -eq 0 ]]; then
        print_error "No valid hostnames provided in --hosts list."
        return 1
    fi
    
    # Remove duplicates while preserving order
    declare -A seen_hosts
    local unique_hosts=()
    for vm_name in "${validated_hosts[@]}"; do
        if [[ -z "${seen_hosts[$vm_name]}" ]]; then
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
