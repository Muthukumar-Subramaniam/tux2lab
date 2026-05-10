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
    print_cyan "Usage: tux2lab vm disk-add [OPTIONS] [hostname]
Options:
  -f, --force          Force power-off without prompt if VM is running
  -n, --count <num>    Number of disks to add (1-10, default: prompt)
  -s, --size <size>    Disk size in GB (multiple of 5, range: 5-50, default: prompt)
  -h, --help           Show this help message

Arguments:
  hostname             Name of the VM to add disks to (optional, will prompt if not given)

Examples:
  tux2lab vm disk-add vm1                        # Interactive mode with prompts
  tux2lab vm disk-add -f vm1                     # Force power-off if running
  tux2lab vm disk-add -n 2 -s 10 vm1             # Add 2x10GB disks with prompts
  tux2lab vm disk-add -f -n 3 -s 20 vm1          # Fully automated: 3x20GB disks
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
        -n|--count)
            if [[ -z "$2" || "$2" == -* ]]; then
                print_error "Option -n/--count requires a value."
                exit 1
            fi
            disk_count_arg="$2"
            shift 2
            ;;
        -s|--size)
            if [[ -z "$2" || "$2" == -* ]]; then
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
            if [[ -n "$vm_hostname_arg" ]]; then
                print_error "Multiple hostnames provided. Only one VM can be processed at a time."
                fn_show_help
                exit 1
            fi
            vm_hostname_arg="$1"
            shift
            ;;
    esac
done

# Use argument or prompt for hostname
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/input-hostname.sh "$vm_hostname_arg"

# Lab infra server info (low risk operation)
if [[ "$qemu_kvm_hostname" == "$lab_infra_server_hostname" ]]; then
    print_info "Adding disk to lab infra server: $lab_infra_server_hostname"
fi

# Check if VM exists in 'virsh list --all'
if ! sudo virsh list --all | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; then
    print_error "VM \"$qemu_kvm_hostname\" does not exist."
    exit 1
fi

fn_shutdown_or_poweroff() {
    # If force flag is set, try graceful shutdown first, then force if needed
    if [[ "$force_poweroff" == true ]]; then
        print_info "Force flag detected. Attempting graceful shutdown first..."
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/shutdown-vm.sh
        SHUTDOWN_VM_CONTEXT="Attempting graceful shutdown" SHUTDOWN_VM_STRICT=false shutdown_vm "$qemu_kvm_hostname"
        
        # Wait for VM to shut down with timeout
        print_info "Waiting for VM \"${qemu_kvm_hostname}\" to shut down (timeout: 30s)..."
        TIMEOUT=30
        ELAPSED=0
        while sudo virsh list | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; do
            if (( ELAPSED >= TIMEOUT )); then
                print_warning "Graceful shutdown timed out. Forcing power off..."
                source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/poweroff-vm.sh
                if ! POWEROFF_VM_CONTEXT="Forcing power off after timeout" POWEROFF_VM_STRICT=true poweroff_vm "$qemu_kvm_hostname"; then
                    exit 1
                fi
                break
            fi
            sleep 2
            ((ELAPSED+=2))
        done
        
        if ! sudo virsh list | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; then
            print_success "VM has been shut down successfully. Proceeding further."
        fi
        return 0
    fi
    
    print_warning "VM \"$qemu_kvm_hostname\" is still running!"
    print_notify "Select an option to proceed:
	1) Try Graceful Shutdown
	2) Force Power Off
	q) Quit"

    read -rp "Enter your choice: " selected_choice

    case "$selected_choice" in
        1)
            print_info "Initiating graceful shutdown..."
            source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/shutdown-vm.sh
            if ! SHUTDOWN_VM_CONTEXT="Initiating graceful shutdown" shutdown_vm "$qemu_kvm_hostname"; then
                exit 1
            fi
            
            # Wait for VM to shut down with timeout
            print_info "Waiting for VM \"${qemu_kvm_hostname}\" to shut down (timeout: 60s)..."
            TIMEOUT=60
            ELAPSED=0
            while sudo virsh list | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; do
                if (( ELAPSED >= TIMEOUT )); then
                    print_warning "VM did not shut down within ${TIMEOUT}s."
                    print_info "You may want to force power off instead."
                    exit 1
                fi
                sleep 2
                ((ELAPSED+=2))
            done
            print_success "VM has been shut down successfully. Proceeding further."
            ;;
        2)
            print_info "Forcing power off..."
            source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/poweroff-vm.sh
            if ! POWEROFF_VM_CONTEXT="Forcing power off" POWEROFF_VM_STRICT=true poweroff_vm "$qemu_kvm_hostname"; then
                exit 1
            fi
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

if ! sudo virsh list  | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; then
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
    print_notify "Select number of disks to add (1-10):"
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
    if [[ ! "$disk_size_arg" =~ ^[0-9]+$ ]] || (( disk_size_arg < 5 || disk_size_arg % 5 != 0 || disk_size_arg > 50 )); then
        print_error "Invalid disk size: $disk_size_arg. Must be a multiple of 5 between 5 and 50."
        exit 1
    fi
    DISK_SIZE_GB="$disk_size_arg"
    print_info "Using disk size: ${DISK_SIZE_GB}GB"
else
    # Prompt for disk size
    print_info "Allowed disk size: Steps of 5GB (5, 10, 15 ... up to 50GB)"
    while true; do
        read -rp "Enter disk size in GB (default 5): " DISK_SIZE_GB
        DISK_SIZE_GB=${DISK_SIZE_GB:-5}
        if [[ "$DISK_SIZE_GB" =~ ^[0-9]+$ ]] && (( DISK_SIZE_GB >= 5 && DISK_SIZE_GB % 5 == 0 && DISK_SIZE_GB <= 50 )); then
            print_info "Selected ${DISK_SIZE_GB}GB disk size."
            break
        else
            print_error "Invalid size! Enter a multiple of 5 between 5 and 50."
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
        if [[ -z "${EXISTING_DISKS[${qemu_kvm_hostname}_vd${letter}.qcow2]}" ]]; then
            echo "$letter"
            return 0
        fi
    done
    return 1
}

for ((i=1; i<=DISK_COUNT; i++)); do
    # Get next available letter
    if ! NEXT_DISK_LETTER=$(get_next_disk_letter); then
        print_error "Maximum disk letters reached (vdb-vdz)."
        exit 1
    fi

    DISK_NAME="${qemu_kvm_hostname}_vd${NEXT_DISK_LETTER}.qcow2"
    DISK_PATH="$VM_DIR/$DISK_NAME"

    # Create disk
    print_task "Creating disk vd${NEXT_DISK_LETTER} (${DISK_SIZE_GB}GB)..." nskip
    if error_msg=$(qemu-img create -f qcow2 "$DISK_PATH" "${DISK_SIZE_GB}G" 2>&1); then
        print_task_done
    else
        print_task_fail
        print_error "$error_msg"
        exit 1
    fi

    # Attach disk
    print_task "Attaching vd${NEXT_DISK_LETTER} (${DISK_SIZE_GB}GB) to VM \"$qemu_kvm_hostname\"..." nskip
    if error_msg=$(sudo virsh attach-disk "$qemu_kvm_hostname" "$DISK_PATH" "vd$NEXT_DISK_LETTER" --subdriver qcow2 --persistent 2>&1); then
        print_task_done
    else
        print_task_fail
        print_error "$error_msg"
        exit 1
    fi

    # Mark disk as used
    EXISTING_DISKS["$DISK_NAME"]=1
done

print_task "Starting VM \"$qemu_kvm_hostname\"..." nskip

if error_msg=$(sudo virsh start "$qemu_kvm_hostname" 2>&1); then
    print_task_done
    print_success "Added $DISK_COUNT ${DISK_SIZE_GB}GB disk(s) to VM \"$qemu_kvm_hostname\" and started successfully."
else
    print_task_fail
    print_error "Could not start VM \"$qemu_kvm_hostname\"."
    print_error "$error_msg"
    exit 1
fi
