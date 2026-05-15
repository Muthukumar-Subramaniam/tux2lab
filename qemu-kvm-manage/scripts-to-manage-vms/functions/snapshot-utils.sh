#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
# Shared utility functions for VM snapshot management

readonly SNAPSHOT_DIR_NAME="snapshots"
readonly SNAPSHOT_META_FILE="snapshot.meta"
readonly SNAPSHOT_LABEL_REGEX='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
readonly SNAPSHOT_LABEL_MAX_LEN=40

# Get the snapshots base directory for a VM
# Usage: fn_get_snapshots_dir "hostname"
# Sets: SNAPSHOTS_DIR
fn_get_snapshots_dir() {
    local vm_hostname="$1"
    SNAPSHOTS_DIR="/tux2lab-data/vms/${vm_hostname}/${SNAPSHOT_DIR_NAME}"
}

# Validate a snapshot label
# Usage: fn_validate_snapshot_label "label"
# Returns: 0 on success, 1 on failure (with error printed)
fn_validate_snapshot_label() {
    local label="$1"

    if [[ -z "$label" ]]; then
        print_error "Snapshot label cannot be empty."
        return 1
    fi

    if [[ ${#label} -gt $SNAPSHOT_LABEL_MAX_LEN ]]; then
        print_error "Snapshot label exceeds maximum length of ${SNAPSHOT_LABEL_MAX_LEN} characters."
        return 1
    fi

    if [[ ! "$label" =~ $SNAPSHOT_LABEL_REGEX ]]; then
        print_error "Invalid snapshot label: '$label'"
        print_info "Label must contain only lowercase letters, numbers, and hyphens."
        print_info "Must not start or end with a hyphen."
        return 1
    fi

    return 0
}

# Generate snapshot directory name with timestamp prefix
# Usage: fn_generate_snapshot_name "label"
# Sets: SNAPSHOT_NAME
fn_generate_snapshot_name() {
    local label="$1"
    SNAPSHOT_NAME="$(date +%Y%m%d-%H%M%S)_${label}"
}

# Get all disk files for a VM (boot disk + additional disks)
# Usage: fn_get_vm_disk_files "hostname"
# Sets: VM_DISK_FILES (array)
fn_get_vm_disk_files() {
    local vm_hostname="$1"
    local vm_dir="/tux2lab-data/vms/${vm_hostname}"

    VM_DISK_FILES=()

    # Boot disk
    local boot_disk="${vm_dir}/${vm_hostname}.qcow2"
    if [[ -f "$boot_disk" ]]; then
        VM_DISK_FILES+=("$boot_disk")
    fi

    # Additional disks (vdb through vdz)
    local additional_disk
    for additional_disk in "${vm_dir}/${vm_hostname}"_vd[b-z].qcow2; do
        if [[ -f "$additional_disk" ]]; then
            VM_DISK_FILES+=("$additional_disk")
        fi
    done
}

# Get NVRAM file for a VM
# Usage: fn_get_vm_nvram_file "hostname"
# Sets: VM_NVRAM_FILE (empty string if not found)
fn_get_vm_nvram_file() {
    local vm_hostname="$1"
    local vm_dir="/tux2lab-data/vms/${vm_hostname}"
    local nvram_file="${vm_dir}/${vm_hostname}_VARS.fd"

    if [[ -f "$nvram_file" ]]; then
        VM_NVRAM_FILE="$nvram_file"
    else
        VM_NVRAM_FILE=""
    fi
}

# Check if a VM is running
# Usage: fn_is_vm_running "hostname"
# Returns: 0 if running, 1 if not running
fn_is_vm_running() {
    local vm_hostname="$1"
    if sudo virsh list | awk '{print $2}' | grep -Fxq "$vm_hostname"; then
        return 0
    fi
    return 1
}

# Write snapshot metadata file
# Usage: fn_write_snapshot_meta "snapshot_dir" "label" "description" disk_files_array nvram_file
fn_write_snapshot_meta() {
    local snapshot_dir="$1"
    local label="$2"
    local description="$3"
    local -n disk_files_ref=$4
    local nvram_file="$5"

    local meta_file="${snapshot_dir}/${SNAPSHOT_META_FILE}"

    {
        echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "label=${label}"
        echo "description=${description}"
        echo "created_by=$(whoami)"
        echo "disk_count=${#disk_files_ref[@]}"
        for df in "${disk_files_ref[@]}"; do
            local basename
            basename=$(basename "$df")
            local size
            size=$(sudo stat -c %s "$df" 2>/dev/null || echo "0")
            echo "disk=${basename}:${size}"
        done
        if [[ -n "$nvram_file" ]]; then
            echo "nvram=$(basename "$nvram_file")"
        fi
    } | sudo tee "$meta_file" > /dev/null
}

# Read snapshot metadata file
# Usage: fn_read_snapshot_meta "snapshot_dir"
# Sets: META_TIMESTAMP, META_LABEL, META_DESCRIPTION, META_CREATED_BY, META_DISK_COUNT, META_DISKS (array), META_NVRAM
fn_read_snapshot_meta() {
    local snapshot_dir="$1"
    local meta_file="${snapshot_dir}/${SNAPSHOT_META_FILE}"

    META_TIMESTAMP=""
    META_LABEL=""
    META_DESCRIPTION=""
    META_CREATED_BY=""
    META_DISK_COUNT=0
    META_DISKS=()
    META_NVRAM=""

    if [[ ! -f "$meta_file" ]]; then
        print_error "Metadata file not found: $meta_file"
        return 1
    fi

    while IFS='=' read -r key value; do
        case "$key" in
            timestamp)     META_TIMESTAMP="$value" ;;
            label)         META_LABEL="$value" ;;
            description)   META_DESCRIPTION="$value" ;;
            created_by)    META_CREATED_BY="$value" ;;
            disk_count)    META_DISK_COUNT="$value" ;;
            disk)          META_DISKS+=("$value") ;;
            nvram)         META_NVRAM="$value" ;;
        esac
    done < "$meta_file"

    return 0
}

# List available snapshots for a VM
# Usage: fn_list_snapshots "hostname"
# Sets: AVAILABLE_SNAPSHOTS (array of directory names)
fn_list_snapshots() {
    local vm_hostname="$1"
    fn_get_snapshots_dir "$vm_hostname"

    AVAILABLE_SNAPSHOTS=()

    if [[ ! -d "$SNAPSHOTS_DIR" ]]; then
        return 0
    fi

    local entry
    for entry in "$SNAPSHOTS_DIR"/*/; do
        if [[ -d "$entry" ]] && [[ -f "${entry}${SNAPSHOT_META_FILE}" ]]; then
            AVAILABLE_SNAPSHOTS+=("$(basename "$entry")")
        fi
    done
}

# Calculate total size of a snapshot directory
# Usage: fn_get_snapshot_size "snapshot_dir"
# Sets: SNAPSHOT_SIZE_HUMAN
fn_get_snapshot_size() {
    local snapshot_dir="$1"
    SNAPSHOT_SIZE_HUMAN=$(sudo du -sh "$snapshot_dir" 2>/dev/null | awk '{print $1}')
}

# Check if there's enough disk space to create a snapshot
# Usage: fn_check_disk_space_for_snapshot disk_files_array nvram_file
# Returns: 0 if enough space, 1 if not (with error printed)
fn_check_disk_space_for_snapshot() {
    local -n disk_files_check=$1
    local nvram_file="$2"

    # Calculate total size needed (in bytes)
    local total_needed=0
    for df in "${disk_files_check[@]}"; do
        local file_size
        file_size=$(sudo stat -c %s "$df" 2>/dev/null || echo "0")
        ((total_needed += file_size))
    done
    if [[ -n "$nvram_file" ]] && [[ -f "$nvram_file" ]]; then
        local nvram_size
        nvram_size=$(sudo stat -c %s "$nvram_file" 2>/dev/null || echo "0")
        ((total_needed += nvram_size))
    fi

    # Get available space on the filesystem where VMs are stored (in bytes)
    local available_space
    available_space=$(df --output=avail -B1 /tux2lab-data 2>/dev/null | tail -1 | tr -d ' ')

    if [[ -z "$available_space" ]] || [[ "$available_space" -eq 0 ]]; then
        print_error "Unable to determine available disk space on /tux2lab-data."
        return 1
    fi

    # Require at least the needed size + 1 GiB headroom
    local headroom=$((1024 * 1024 * 1024))
    local required=$((total_needed + headroom))

    if (( available_space < required )); then
        local needed_human
        local available_human
        needed_human=$(numfmt --to=iec "$total_needed" 2>/dev/null || echo "$total_needed bytes")
        available_human=$(numfmt --to=iec "$available_space" 2>/dev/null || echo "$available_space bytes")
        print_error "Not enough disk space to create snapshot."
        print_info "Required: $needed_human + 1 GiB headroom"
        print_info "Available: $available_human"
        return 1
    fi

    return 0
}
