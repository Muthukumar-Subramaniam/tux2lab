# report-retained-resources.sh
# 
# Reports retained CPU and memory if above default specs (2 vCPUs, 2 GiB RAM)
#
# Usage:
#   source /path/to/report-retained-resources.sh
#   report_retained_resources "vm-hostname"
#
# Returns:
#   0 - Always returns success (reporting only)

report_retained_resources() {
    local vm_hostname="$1"

    if [[ -z "$vm_hostname" ]]; then
        return 0
    fi

    local current_vcpus
    current_vcpus=$(sudo virsh dominfo "$vm_hostname" 2>/dev/null | awk '/^CPU\(s\)/ {print $2}')
    if [[ -n "$current_vcpus" && "$current_vcpus" -gt 2 ]]; then
        print_info "Retained vCPU count of ${current_vcpus} for VM \"$vm_hostname\"."
    fi

    local current_mem_kib
    current_mem_kib=$(sudo virsh dominfo "$vm_hostname" 2>/dev/null | awk '/^Max memory/ {print $3}')
    if [[ -n "$current_mem_kib" ]]; then
        local current_mem_gib=$(( current_mem_kib / 1024 / 1024 ))
        if [[ "$current_mem_gib" -gt 2 ]]; then
            print_info "Retained memory of ${current_mem_gib} GiB for VM \"$vm_hostname\"."
        fi
    fi

    return 0
}
