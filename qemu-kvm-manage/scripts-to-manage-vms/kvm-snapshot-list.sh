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
    print_cyan "Usage: tux2lab vm snapshot-list [OPTIONS]
Options:
  -H, --hosts <list>   Comma-separated list of VM hostnames
  -h, --help           Show this help message

Examples:
  tux2lab vm snapshot-list -H vm1
  tux2lab vm snapshot-list -H vm1,vm2,vm3
"
}

# Parse arguments
hosts_list=""

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

# Parse and validate hostnames
IFS=',' read -ra hosts_array <<< "$hosts_list"

source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/validate-and-process-hostnames.sh
if ! validate_and_process_hostnames hosts_array; then
    exit 1
fi

validated_hosts=("${VALIDATED_HOSTS[@]}")

# List snapshots for each VM
for vm_name in "${validated_hosts[@]}"; do
    # Check if VM exists
    if ! sudo virsh list --all | awk '{print $2}' | grep -Fxq "$vm_name"; then
        print_error "VM \"$vm_name\" does not exist."
        continue
    fi

    fn_list_snapshots "$vm_name"

    if [[ ${#validated_hosts[@]} -gt 1 ]]; then
        echo
        print_cyan "VM: $vm_name"
    fi

    if [[ ${#AVAILABLE_SNAPSHOTS[@]} -eq 0 ]]; then
        print_info "No snapshots found."
        continue
    fi

    # Print header
    printf "  %-40s  %-20s  %-8s  %s\n" "SNAPSHOT NAME" "CREATED" "SIZE" "DESCRIPTION"
    printf "  %-40s  %-20s  %-8s  %s\n" "-------------" "-------" "----" "-----------"

    # List each snapshot
    fn_get_snapshots_dir "$vm_name"
    for snap_name in "${AVAILABLE_SNAPSHOTS[@]}"; do
        local_snapshot_dir="${SNAPSHOTS_DIR}/${snap_name}"

        if fn_read_snapshot_meta "$local_snapshot_dir"; then
            fn_get_snapshot_size "$local_snapshot_dir"
            printf "  %-40s  %-20s  %-8s  %s\n" \
                "$snap_name" \
                "$META_TIMESTAMP" \
                "$SNAPSHOT_SIZE_HUMAN" \
                "$META_DESCRIPTION"
        else
            printf "  %-40s  %-20s  %-8s  %s\n" \
                "$snap_name" \
                "unknown" \
                "?" \
                "(metadata missing)"
        fi
    done
done
