#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# Function to show help
fn_show_help() {
    print_cyan "Usage: tux2lab vm disk-add [OPTIONS]
Options:
  -H, --host <host>    Hostname of the VM to add disks to
  -f, --force          Force power-off without prompt if VM is running
  -n, --count <num>    Number of disks to add (1-10, default: prompt)
  -s, --size <size>    Disk size in GiB (1-100, default: prompt)
  -h, --help           Show this help message

Examples:
  tux2lab vm disk-add -H vm1                        # Interactive mode with prompts
  tux2lab vm disk-add -f -H vm1                     # Force power-off if running
  tux2lab vm disk-add -n 2 -s 10 -H vm1             # Add 2x10 GiB disks
  tux2lab vm disk-add -f -n 3 -s 20 -H vm1          # Fully automated: 3x20 GiB disks
"
}

# Parse arguments
force_poweroff=false
vm_hostname_arg=""
disk_count_arg=""
disk_size_arg=""

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
        -H|--host)
            if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                print_error "Option -H/--host requires a hostname."
                exit 1
            fi
            vm_hostname_arg="$2"
            shift 2
            ;;
        -n|--count)
            if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                print_error "Option -n/--count requires a value."
                exit 1
            fi
            disk_count_arg="$2"
            shift 2
            ;;
        -s|--size)
            if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                print_error "Option -s/--size requires a value."
                exit 1
            fi
            disk_size_arg="$2"
            shift 2
            ;;
        -*)
            print_error "Unknown option: $1"
            fn_show_help
            exit 1
            ;;
        *)
            print_error "Unexpected argument: $1"
            print_info "Use -H/--host to specify the hostname."
            fn_show_help
            exit 1
            ;;
    esac
done

# Use argument or prompt for hostname
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/input-hostname.sh "$vm_hostname_arg"

# Lab infra server info (low risk operation)
if [[ "$qemu_kvm_hostname" == "$lab_infra_server_hostname" ]]; then
    print_info "Adding disk to lab infra server: $lab_infra_server_hostname"
fi

# Check if VM exists
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/check-vm-exists.sh
check_vm_exists "$qemu_kvm_hostname" "reimage"

fn_shutdown_or_poweroff() {
    # If force flag is set, try graceful shutdown first, then force if needed
    if [[ "$force_poweroff" == true ]]; then
        print_task "Shutting down VM (graceful then force if needed)..."
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/shutdown-vm.sh
        SHUTDOWN_VM_CONTEXT="Attempting graceful shutdown" SHUTDOWN_VM_STRICT=false shutdown_vm "$qemu_kvm_hostname" &>/dev/null

        # Wait for VM to shut down with timeout
        TIMEOUT=30
        ELAPSED=0
        while sudo virsh list | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; do
            if (( ELAPSED >= TIMEOUT )); then
                source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/poweroff-vm.sh
                if ! POWEROFF_VM_CONTEXT="Forcing power off after timeout" POWEROFF_VM_STRICT=true poweroff_vm "$qemu_kvm_hostname" &>/dev/null; then
                    print_task_fail
                    exit 1
                fi
                break
            fi
            sleep 2
            ((ELAPSED+=2))
        done

        if ! sudo virsh list | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; then
            print_task_done
        fi
        return 0
    fi

    print_warning "VM \"$qemu_kvm_hostname\" is still running!"
    print_info "Select an option to proceed:
  1) Try Graceful Shutdown
  2) Force Power Off
  q) Quit"

    read -rp "Enter your choice: " selected_choice

    case "$selected_choice" in
        1)
            print_task "Shutting down VM gracefully..."
            source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/shutdown-vm.sh
            if ! SHUTDOWN_VM_CONTEXT="Initiating graceful shutdown" shutdown_vm "$qemu_kvm_hostname" &>/dev/null; then
                print_task_fail
                exit 1
            fi

            # Wait for VM to shut down with timeout
            TIMEOUT=60
            ELAPSED=0
            while sudo virsh list | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; do
                if (( ELAPSED >= TIMEOUT )); then
                    print_task_fail
                    print_warning "VM did not shut down within ${TIMEOUT}s."
                    print_info "You may want to force power off instead."
                    exit 1
                fi
                sleep 2
                ((ELAPSED+=2))
            done
            print_task_done
            ;;
        2)
            print_task "Forcing power off VM..."
            source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/poweroff-vm.sh
            if ! POWEROFF_VM_CONTEXT="Forcing power off" POWEROFF_VM_STRICT=true poweroff_vm "$qemu_kvm_hostname" &>/dev/null; then
                print_task_fail
                exit 1
            fi
            print_task_done
            ;;
        q)
            print_info "Quitting without any action."
            exit 0
            ;;
        *)
            print_error "Invalid option!"
            exit 1
            ;;
    esac
}

if ! sudo virsh list | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; then
    print_info "VM \"$qemu_kvm_hostname\" is not running. Proceeding further."
else
    fn_shutdown_or_poweroff
fi

# Get disk count (from argument or prompt)
if [[ -n "$disk_count_arg" ]]; then
    # Validate provided disk count
    if [[ ! "$disk_count_arg" =~ ^[1-9][0-9]*$ ]] || (( disk_count_arg > 10 )); then
        print_error "Invalid disk count: $disk_count_arg. Must be between 1 and 10."
        exit 1
    fi
    DISK_COUNT="$disk_count_arg"
    print_info "Using disk count: $DISK_COUNT"
else
    # Prompt for disk count
    print_info "Select number of disks to add (1-10):"
    while true; do
        read -rp "Enter disk count: " DISK_COUNT
        if [[ "$DISK_COUNT" =~ ^[1-9][0-9]*$ ]] && (( DISK_COUNT <= 10 )); then
            print_info "Selected $DISK_COUNT disk(s)."
            break
        else
            print_error "Invalid input! Enter a number between 1 and 10."
        fi
    done
fi

# Get disk size (from argument or prompt)
if [[ -n "$disk_size_arg" ]]; then
    # Validate provided disk size
    if [[ ! "$disk_size_arg" =~ ^[1-9][0-9]*$ ]] || (( disk_size_arg > 100 )); then
        print_error "Invalid disk size: ${disk_size_arg}. Must be between 1 and 100 GiB."
        exit 1
    fi
    DISK_SIZE_GB="$disk_size_arg"
    print_info "Using disk size: ${DISK_SIZE_GB} GiB"
else
    # Prompt for disk size
    print_info "Allowed disk size: 1-100 GiB"
    while true; do
        read -rp "Enter disk size in GiB (default 5): " DISK_SIZE_GB
        DISK_SIZE_GB=${DISK_SIZE_GB:-5}
        if [[ "$DISK_SIZE_GB" =~ ^[1-9][0-9]*$ ]] && (( DISK_SIZE_GB <= 100 )); then
            print_info "Selected ${DISK_SIZE_GB} GiB disk size."
            break
        else
            print_error "Invalid size! Enter a number between 1 and 100."
        fi
    done
fi

VM_DIR="/tux2lab-data/vms/${qemu_kvm_hostname}"

# Verify VM directory exists
if [[ ! -d "$VM_DIR" ]]; then
    print_error "VM directory does not exist: $VM_DIR"
    exit 1
fi

# Determine existing disks using associative array for O(1) lookup
declare -A EXISTING_DISKS
for disk_file in "$VM_DIR"/*.qcow2; do
    [[ -e "$disk_file" ]] || continue
    BASENAME=$(basename "$disk_file")
    EXISTING_DISKS["$BASENAME"]=1
done

# Function to get next available disk letter
get_next_disk_letter() {
    local letter
    for letter in {b..z}; do
        if [[ -z "${EXISTING_DISKS[${qemu_kvm_hostname}_vd${letter}.qcow2]+isset}" ]]; then
            echo "$letter"
            return 0
        fi
    done
    return 1
}

DISKS_ADDED=0

for ((i=1; i<=DISK_COUNT; i++)); do
    # Get next available letter
    if ! NEXT_DISK_LETTER=$(get_next_disk_letter); then
        print_error "Maximum disk letters reached (vdb-vdz)."
        break
    fi

    DISK_NAME="${qemu_kvm_hostname}_vd${NEXT_DISK_LETTER}.qcow2"
    DISK_PATH="$VM_DIR/$DISK_NAME"

    # Create disk
    print_task "Creating disk vd${NEXT_DISK_LETTER} (${DISK_SIZE_GB} GiB)..." nskip
    if error_msg=$(sudo qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE_GB}G" 2>&1); then
        print_task_done
    else
        print_task_fail
        print_error "$error_msg"
        break
    fi

    # Attach disk
    print_task "Attaching vd${NEXT_DISK_LETTER} (${DISK_SIZE_GB} GiB) to VM \"$qemu_kvm_hostname\"..." nskip
    if error_msg=$(sudo virsh attach-disk "$qemu_kvm_hostname" "$DISK_PATH" "vd$NEXT_DISK_LETTER" --subdriver qcow2 --persistent 2>&1); then
        print_task_done
    else
        print_task_fail
        print_error "$error_msg"
        # Clean up the created disk that couldn't be attached
        sudo rm -f "$DISK_PATH"
        break
    fi

    # Mark disk as used
    EXISTING_DISKS["$DISK_NAME"]=1
    ((DISKS_ADDED++))
done

print_task "Starting VM \"$qemu_kvm_hostname\"..." nskip

if error_msg=$(sudo virsh start "$qemu_kvm_hostname" 2>&1); then
    print_task_done
else
    print_task_fail
    print_error "Could not start VM \"$qemu_kvm_hostname\"."
    print_error "$error_msg"
    exit 1
fi

if (( DISKS_ADDED == DISK_COUNT )); then
    print_success "Added ${DISKS_ADDED} ${DISK_SIZE_GB} GiB disk(s) to VM \"$qemu_kvm_hostname\" and started successfully."
elif (( DISKS_ADDED > 0 )); then
    print_warning "Only ${DISKS_ADDED} of ${DISK_COUNT} disk(s) were added. VM started with partial changes."
    exit 1
else
    print_error "No disks were added."
    exit 1
fi
