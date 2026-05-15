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
    print_cyan "Usage: tux2lab vm snapshot-delete [OPTIONS]
Options:
  -H, --hosts <list>       Comma-separated list of VM hostnames
  -n, --name <snapshot>    Snapshot name to delete (e.g., 20260515-143022_pre-update)
  -f, --force              Skip confirmation prompt
  -h, --help               Show this help message

Examples:
  tux2lab vm snapshot-delete -H vm1 -n 20260515-143022_pre-update
  tux2lab vm snapshot-delete -f -H vm1,vm2 -n 20260515-143022_baseline
"
}

# Parse arguments
hosts_list=""
snapshot_name=""
force_delete=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            fn_show_help
            exit 0
            ;;
        -f|--force)
            force_delete=true
            shift
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
    read -rp "Enter snapshot name to delete: " snapshot_name
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

# Confirmation prompt (unless forced)
if [[ "$force_delete" == false ]]; then
    if [[ ${#validated_hosts[@]} -gt 1 ]]; then
        print_warning "This will permanently delete snapshot '$snapshot_name' from ${#validated_hosts[@]} VM(s)."
    else
        print_warning "This will permanently delete snapshot '$snapshot_name' from VM \"${validated_hosts[0]}\"."
    fi
    print_notify "This action cannot be undone."
    read -rp "Are you sure you want to continue? (yes/no): " confirmation
    echo -ne "\033[1A\033[2K"

    if [[ "$confirmation" != "yes" ]]; then
        print_info "Operation cancelled by user."
        exit 0
    fi
fi

# Delete snapshot for each VM
failed_vms=()
successful_vms=()
skipped_vms=()
total_vms=${#validated_hosts[@]}
current=0

for vm_name in "${validated_hosts[@]}"; do
    ((++current))
    if [[ $total_vms -gt 1 ]]; then
        print_info "Progress: $current/$total_vms - $vm_name"
    fi

    # Check if VM exists
    if ! sudo virsh list --all | awk '{print $2}' | grep -Fxq "$vm_name"; then
        print_error "VM \"$vm_name\" does not exist."
        failed_vms+=("$vm_name")
        continue
    fi

    fn_get_snapshots_dir "$vm_name"
    local_snapshot_dir="${SNAPSHOTS_DIR}/${snapshot_name}"

    if [[ ! -d "$local_snapshot_dir" ]]; then
        print_warning "Snapshot '$snapshot_name' not found for VM '$vm_name'."
        skipped_vms+=("$vm_name")
        continue
    fi

    # Get size before deletion for reporting
    fn_get_snapshot_size "$local_snapshot_dir"
    freed_size="$SNAPSHOT_SIZE_HUMAN"

    print_task "Deleting snapshot '$snapshot_name' from VM '$vm_name'..."

    if ! sudo rm -rf "$local_snapshot_dir"; then
        print_task_fail
        print_error "Failed to delete snapshot directory."
        failed_vms+=("$vm_name")
        continue
    fi

    print_task_done
    print_info "Freed: $freed_size"
    successful_vms+=("$vm_name")
done

# Print summary for multi-VM operations
if [[ $total_vms -gt 1 ]]; then
    echo
    print_summary "Snapshot Delete Results"
    if [[ ${#successful_vms[@]} -gt 0 ]]; then
        print_green "  DONE: ${#successful_vms[@]}/$total_vms"
        for vm in "${successful_vms[@]}"; do
            print_green "    - $vm"
        done
    fi
    if [[ ${#skipped_vms[@]} -gt 0 ]]; then
        print_yellow "  SKIP: ${#skipped_vms[@]}/$total_vms"
        for vm in "${skipped_vms[@]}"; do
            print_yellow "    - $vm"
        done
    fi
    if [[ ${#failed_vms[@]} -gt 0 ]]; then
        print_red "  FAIL: ${#failed_vms[@]}/$total_vms"
        for vm in "${failed_vms[@]}"; do
            print_red "    - $vm"
        done
    fi
fi

# Exit with appropriate code
if [[ ${#failed_vms[@]} -gt 0 ]]; then
    exit 1
fi
exit 0
