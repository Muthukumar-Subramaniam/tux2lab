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
    print_cyan "Usage: tux2lab vm snapshot-revert [OPTIONS]
Options:
  -H, --hosts <list>       Comma-separated list of VM hostnames
  -n, --name <snapshot>    Snapshot name to revert to (e.g., 20260515-143022_pre-update)
  -f, --force              Force power-off and skip confirmation prompt
  -h, --help               Show this help message

Notes:
  - VM must be shut down before reverting (use -f to auto shutdown)
  - Current disk state will be OVERWRITTEN with snapshot data
  - This operation cannot be undone unless you create a snapshot first

Examples:
  tux2lab vm snapshot-revert -H vm1 -n 20260515-143022_pre-update
  tux2lab vm snapshot-revert -f -H vm1,vm2 -n 20260515-143022_baseline
"
}

# Parse arguments
hosts_list=""
snapshot_name=""
force_revert=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            fn_show_help
            exit 0
            ;;
        -f|--force)
            force_revert=true
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
    read -rp "Enter snapshot name to revert to: " snapshot_name
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
if [[ "$force_revert" == false ]]; then
    if [[ ${#validated_hosts[@]} -gt 1 ]]; then
        print_warning "This will revert ${#validated_hosts[@]} VM(s) to snapshot '$snapshot_name'."
    else
        print_warning "This will revert VM \"${validated_hosts[0]}\" to snapshot '$snapshot_name'."
    fi
    print_notify "Current disk state will be OVERWRITTEN. This cannot be undone."
    read -rp "Are you sure you want to continue? (YES/NO): " confirmation
    echo -ne "\033[1A\033[2K"

    if [[ "$confirmation" != "YES" ]]; then
        print_info "Operation cancelled by user."
        exit 0
    fi
fi

# Revert snapshot for each VM
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

    # Check if VM is running - must be offline for revert
    if fn_is_vm_running "$vm_name"; then
        if [[ "$force_revert" == true ]]; then
            print_task "Shutting down VM '$vm_name'..."
            if ! sudo virsh shutdown "$vm_name" &>/dev/null; then
                print_task_fail
                print_error "Failed to send shutdown signal to '$vm_name'."
                failed_vms+=("$vm_name")
                continue
            fi

            # Wait for shutdown with timeout
            timeout=60
            elapsed=0
            while fn_is_vm_running "$vm_name"; do
                if (( elapsed >= timeout )); then
                    # Force power off after timeout
                    if ! sudo virsh destroy "$vm_name" &>/dev/null; then
                        print_task_fail
                        print_error "Failed to force power-off '$vm_name'."
                        failed_vms+=("$vm_name")
                        continue 2
                    fi
                    break
                fi
                sleep 2
                ((elapsed+=2))
            done
            print_task_done
        else
            print_warning "VM \"$vm_name\" is running! It must be shut down for revert."
            print_info "Select an option to proceed:
  1) Try Graceful Shutdown
  2) Force Power Off
  q) Quit"

            read -rp "Enter your choice: " selected_choice

            case "$selected_choice" in
                1)
                    print_task "Shutting down VM '$vm_name' gracefully..."
                    if ! sudo virsh shutdown "$vm_name" &>/dev/null; then
                        print_task_fail
                        failed_vms+=("$vm_name")
                        continue
                    fi
                    timeout=60
                    elapsed=0
                    while fn_is_vm_running "$vm_name"; do
                        if (( elapsed >= timeout )); then
                            print_task_fail
                            print_warning "VM did not shut down within ${timeout}s."
                            failed_vms+=("$vm_name")
                            continue 2
                        fi
                        sleep 2
                        ((elapsed+=2))
                    done
                    print_task_done
                    ;;
                2)
                    print_task "Forcing power off VM '$vm_name'..."
                    if ! sudo virsh destroy "$vm_name" &>/dev/null; then
                        print_task_fail
                        failed_vms+=("$vm_name")
                        continue
                    fi
                    print_task_done
                    ;;
                q)
                    print_info "Quitting without any action."
                    exit 0
                    ;;
                *)
                    print_error "Invalid option!"
                    failed_vms+=("$vm_name")
                    continue
                    ;;
            esac
        fi
    fi

    # Verify snapshot exists
    fn_get_snapshots_dir "$vm_name"
    local_snapshot_dir="${SNAPSHOTS_DIR}/${snapshot_name}"

    if [[ ! -d "$local_snapshot_dir" ]]; then
        print_error "Snapshot '$snapshot_name' not found for VM '$vm_name'."
        failed_vms+=("$vm_name")
        continue
    fi

    # Read snapshot metadata
    if ! fn_read_snapshot_meta "$local_snapshot_dir"; then
        failed_vms+=("$vm_name")
        continue
    fi

    vm_dir="/tux2lab-data/vms/${vm_name}"

    print_task "Reverting VM '$vm_name' to snapshot '$snapshot_name'..."

    # Restore disk files from snapshot
    revert_failed=false
    for disk_entry in "${META_DISKS[@]}"; do
        disk_name="${disk_entry%%:*}"
        source_file="${local_snapshot_dir}/${disk_name}"
        target_file="${vm_dir}/${disk_name}"

        if [[ ! -f "$source_file" ]]; then
            print_task_fail
            print_error "Snapshot disk file missing: $disk_name"
            revert_failed=true
            break
        fi

        if ! sudo cp --reflink=auto "$source_file" "$target_file"; then
            print_task_fail
            print_error "Failed to restore disk: $disk_name"
            revert_failed=true
            break
        fi
    done

    if [[ "$revert_failed" == true ]]; then
        failed_vms+=("$vm_name")
        continue
    fi

    # Restore NVRAM if present in snapshot
    if [[ -n "$META_NVRAM" ]]; then
        nvram_source="${local_snapshot_dir}/${META_NVRAM}"
        nvram_target="${vm_dir}/${META_NVRAM}"

        if [[ -f "$nvram_source" ]]; then
            if ! sudo cp --reflink=auto "$nvram_source" "$nvram_target"; then
                print_task_fail
                print_error "Failed to restore NVRAM file."
                failed_vms+=("$vm_name")
                continue
            fi
        fi
    fi

    print_task_done
    print_info "VM '$vm_name' reverted to snapshot: $snapshot_name"

    # Start VM after successful revert
    print_task "Starting VM '$vm_name'..."
    if sudo virsh start "$vm_name" &>/dev/null; then
        print_task_done
    else
        print_task_fail
        print_warning "VM reverted successfully but failed to start."
    fi

    successful_vms+=("$vm_name")
done

# Print summary for multi-VM operations
if [[ $total_vms -gt 1 ]]; then
    echo
    print_summary "Snapshot Revert Results"
    if [[ ${#successful_vms[@]} -gt 0 ]]; then
        print_green "  DONE: ${#successful_vms[@]}/$total_vms"
        for vm in "${successful_vms[@]}"; do
            print_green "    - $vm"
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
