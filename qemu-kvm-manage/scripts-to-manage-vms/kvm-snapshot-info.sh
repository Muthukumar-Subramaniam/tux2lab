#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/snapshot-utils.sh

# Function to show help
fn_show_help() {
    print_cyan "Usage: tux2lab vm snapshot-info [OPTIONS]
Options:
  -H, --hosts <list>       Comma-separated list of VM hostnames
  -n, --name <snapshot>    Snapshot name (e.g., 20260515-143022_pre-update)
  -h, --help               Show this help message

Examples:
  tux2lab vm snapshot-info -H vm1 -n 20260515-143022_pre-update
  tux2lab vm snapshot-info -H vm1,vm2 -n 20260515-143022_baseline
"
}

# Parse arguments
hosts_list=""
snapshot_name=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            fn_show_help
            exit 0
            ;;
        -H|--hosts)
            if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                print_error "Option -H/--hosts requires a comma-separated list of hostnames."
                exit 1
            fi
            hosts_list="$2"
            shift 2
            ;;
        -n|--name)
            if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                print_error "Option -n/--name requires a snapshot name."
                exit 1
            fi
            snapshot_name="$2"
            shift 2
            ;;
        -*)
            print_error "Unknown option: $1"
            fn_show_help
            exit 1
            ;;
        *)
            print_error "Unexpected argument: $1"
            fn_show_help
            exit 1
            ;;
    esac
done

# Prompt for hosts if not provided
if [[ -z "$hosts_list" ]]; then
    read -rp "Enter hostname(s) (comma-separated): " hosts_list
    if [[ -z "$hosts_list" ]]; then
        print_error "No hostnames provided."
        exit 1
    fi
fi

# Prompt for snapshot name if not provided
if [[ -z "$snapshot_name" ]]; then
    read -rp "Enter snapshot name: " snapshot_name
    if [[ -z "$snapshot_name" ]]; then
        print_error "No snapshot name provided."
        exit 1
    fi
fi

# Parse and validate hostnames
IFS=',' read -ra hosts_array <<< "$hosts_list"

source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/validate-and-process-hostnames.sh
if ! validate_and_process_hostnames hosts_array; then
    exit 1
fi

validated_hosts=("${VALIDATED_HOSTS[@]}")

# Show info for each VM
exit_code=0
for vm_name in "${validated_hosts[@]}"; do
    # Check if VM exists
    if ! sudo virsh list --all | awk '{print $2}' | grep -Fxq "$vm_name"; then
        print_error "VM \"$vm_name\" does not exist."
        exit_code=1
        continue
    fi

    fn_get_snapshots_dir "$vm_name"
    local_snapshot_dir="${SNAPSHOTS_DIR}/${snapshot_name}"

    if [[ ${#validated_hosts[@]} -gt 1 ]]; then
        echo
        print_cyan "VM: $vm_name"
    fi

    if [[ ! -d "$local_snapshot_dir" ]]; then
        print_error "Snapshot not found: $snapshot_name"
        exit_code=1
        continue
    fi

    if ! fn_read_snapshot_meta "$local_snapshot_dir"; then
        exit_code=1
        continue
    fi

    fn_get_snapshot_size "$local_snapshot_dir"

    # Display detailed information
    echo
    print_cyan "Snapshot Details:"
    echo "  Name        : $snapshot_name"
    echo "  Label       : $META_LABEL"
    echo "  Created     : $META_TIMESTAMP"
    echo "  Created by  : $META_CREATED_BY"
    echo "  Description : ${META_DESCRIPTION:-"(none)"}"
    echo "  Total size  : $SNAPSHOT_SIZE_HUMAN"
    echo "  Disk count  : $META_DISK_COUNT"
    echo
    echo "  Disk files:"
    for disk_entry in "${META_DISKS[@]}"; do
        disk_name="${disk_entry%%:*}"
        disk_size="${disk_entry##*:}"
        disk_size_human=$(numfmt --to=iec "$disk_size" 2>/dev/null || echo "${disk_size} bytes")
        echo "    - $disk_name ($disk_size_human)"
    done
    if [[ -n "$META_NVRAM" ]]; then
        echo "  NVRAM       : $META_NVRAM"
    fi
    echo "  Path        : $local_snapshot_dir"
done

exit $exit_code
