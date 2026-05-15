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
    print_cyan "Usage: tux2lab vm snapshot-create [OPTIONS]
Options:
  -H, --hosts <list>   Comma-separated list of VM hostnames
  -l, --label <name>   Snapshot label (lowercase alphanumeric + hyphens, max 40 chars)
  -d, --desc <text>    Optional description for the snapshot
  -f, --force          Force power-off without prompt if VM is running
  -h, --help           Show this help message

Examples:
  tux2lab vm snapshot-create -H vm1 -l pre-update
  tux2lab vm snapshot-create -H vm1,vm2 -l baseline -d \"Clean install state\"
  tux2lab vm snapshot-create -f -H vm1 -l before-kernel-upgrade
"
}

# Parse arguments
force_poweroff=false
hosts_list=""
snapshot_label=""
snapshot_desc=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            fn_show_help
            exit 0
            ;;
        -f|--force)
            force_poweroff=true
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
        -l|--label)
            if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                print_error "Option -l/--label requires a value."
                exit 1
            fi
            snapshot_label="$2"
            shift 2
            ;;
        -d|--desc)
            if [[ -z "${2:-}" ]]; then
                print_error "Option -d/--desc requires a value."
                exit 1
            fi
            snapshot_desc="$2"
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

# Prompt for label if not provided
if [[ -z "$snapshot_label" ]]; then
    read -rp "Enter snapshot label: " snapshot_label
fi

# Validate label
if ! fn_validate_snapshot_label "$snapshot_label"; then
    exit 1
fi

# Parse and validate hostnames
IFS=',' read -ra hosts_array <<< "$hosts_list"

source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/validate-and-process-hostnames.sh
if ! validate_and_process_hostnames hosts_array; then
    exit 1
fi

validated_hosts=("${VALIDATED_HOSTS[@]}")

# Generate snapshot name (same for all VMs in this batch)
fn_generate_snapshot_name "$snapshot_label"
local_snapshot_name="$SNAPSHOT_NAME"

print_info "Snapshot name: $local_snapshot_name"

# Process each VM
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

    # Check if VM is running - must be offline for snapshot
    if fn_is_vm_running "$vm_name"; then
        if [[ "$force_poweroff" == true ]]; then
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
            print_error "VM \"$vm_name\" is running. Shut it down first or use -f/--force."
            failed_vms+=("$vm_name")
            continue
        fi
    fi

    # Get VM disk files and NVRAM
    fn_get_vm_disk_files "$vm_name"
    fn_get_vm_nvram_file "$vm_name"

    if [[ ${#VM_DISK_FILES[@]} -eq 0 ]]; then
        print_error "No disk files found for VM \"$vm_name\"."
        failed_vms+=("$vm_name")
        continue
    fi

    # Create snapshot directory
    fn_get_snapshots_dir "$vm_name"
    snapshot_path="${SNAPSHOTS_DIR}/${local_snapshot_name}"

    if [[ -d "$snapshot_path" ]]; then
        print_error "Snapshot already exists: $local_snapshot_name (VM: $vm_name)"
        failed_vms+=("$vm_name")
        continue
    fi

    print_task "Creating snapshot '$local_snapshot_name' for VM '$vm_name'..."

    if ! mkdir -p "$snapshot_path"; then
        print_task_fail
        print_error "Failed to create snapshot directory."
        failed_vms+=("$vm_name")
        continue
    fi

    # Copy disk files
    copy_failed=false
    for disk_file in "${VM_DISK_FILES[@]}"; do
        if ! cp --reflink=auto "$disk_file" "$snapshot_path/"; then
            print_task_fail
            print_error "Failed to copy disk: $(basename "$disk_file")"
            rm -rf "$snapshot_path"
            copy_failed=true
            break
        fi
    done

    if [[ "$copy_failed" == true ]]; then
        failed_vms+=("$vm_name")
        continue
    fi

    # Copy NVRAM if present
    if [[ -n "$VM_NVRAM_FILE" ]]; then
        if ! cp --reflink=auto "$VM_NVRAM_FILE" "$snapshot_path/"; then
            print_task_fail
            print_error "Failed to copy NVRAM file."
            rm -rf "$snapshot_path"
            failed_vms+=("$vm_name")
            continue
        fi
    fi

    # Write metadata
    fn_write_snapshot_meta "$snapshot_path" "$snapshot_label" "$snapshot_desc" VM_DISK_FILES "$VM_NVRAM_FILE"

    print_task_done

    # Show snapshot size
    fn_get_snapshot_size "$snapshot_path"
    print_info "Snapshot size: $SNAPSHOT_SIZE_HUMAN"

    successful_vms+=("$vm_name")
done

# Print summary for multi-VM operations
if [[ $total_vms -gt 1 ]]; then
    echo
    print_summary "Snapshot Create Results"
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
