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

    local dominfo
    dominfo=$(sudo virsh dominfo "$vm_hostname" 2>/dev/null) || return 0

    local current_vcpus
    current_vcpus=$(awk '/^CPU\(s\)/ {print $2}' <<< "$dominfo")
    local current_mem_kib
    current_mem_kib=$(awk '/^Max memory/ {print $3}' <<< "$dominfo")
    local current_mem_gib=$(( current_mem_kib / 1024 / 1024 ))

    local current_disk_gib
    local vm_disk_path="/tux2lab-data/vms/${vm_hostname}/${vm_hostname}.qcow2"
    current_disk_gib=$(sudo qemu-img info "$vm_disk_path" 2>/dev/null | awk '/virtual size/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $(i+1)=="GiB") {print $i; exit}}')
    current_disk_gib="${current_disk_gib:-30}"

    print_info "VM specs: ${current_vcpus} vCPUs, ${current_mem_gib} GiB RAM, ${current_disk_gib} GiB disk"

    return 0
}
