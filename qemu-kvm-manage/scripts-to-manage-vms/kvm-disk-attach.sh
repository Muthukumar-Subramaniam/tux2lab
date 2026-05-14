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
    print_cyan "Usage: tux2lab vm disk-attach [OPTIONS] [hostname]
Options:
  -f, --force          Force power-off without prompt if VM is running
  -d, --disks <list>   Comma-separated list of disk files to attach from detached storage
  -h, --help           Show this help message

Arguments:
  hostname             Name of the VM to attach disks to (optional, will prompt if not given)

Examples:
  tux2lab vm disk-attach vm1                     # Interactive mode - select disks
  tux2lab vm disk-attach -f vm1                  # Force power-off if running
  tux2lab vm disk-attach -d disk1.qcow2,disk2.qcow2 vm1  # Attach specific disks
  tux2lab vm disk-attach -f -d disk1.qcow2 vm2   # Fully automated
"
}

# Parse arguments
force_poweroff=false
vm_hostname_arg=""
disks_arg=""

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
        -d|--disks)
            if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                print_error "Option -d/--disks requires a value."
                exit 1
            fi
            disks_arg="$2"
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

VM_DIR="/tux2lab-data/vms/${qemu_kvm_hostname}"
DETACHED_DIR="/tux2lab-data/detached-data-disks"

# Verify VM directory exists
if [[ ! -d "$VM_DIR" ]]; then
    print_error "VM directory does not exist: $VM_DIR"
    exit 1
fi

# Check detached disks directory
if [[ ! -d "$DETACHED_DIR" ]]; then
    print_error "Detached disks directory does not exist: $DETACHED_DIR"
    print_info "No detached disks available to attach."
    exit 1
fi

# Get list of available detached disks
print_info "Scanning detached disks..."
declare -a AVAILABLE_DISKS
while IFS= read -r disk_file; do
    AVAILABLE_DISKS+=("$(basename "$disk_file")")
done < <(sudo find "$DETACHED_DIR" -maxdepth 1 -type f -name "*.qcow2" 2>/dev/null)

if [[ ${#AVAILABLE_DISKS[@]} -eq 0 ]]; then
    print_warning "No detached disks found in $DETACHED_DIR"
    exit 0
fi

# Now that we confirmed there are disks to attach, check VM state and shut down if needed
if ! sudo virsh list  | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; then
    print_info "VM \"$qemu_kvm_hostname\" is not running. Proceeding further."
else
    fn_shutdown_or_poweroff
fi

# Get currently attached disk targets to find next available target
declare -a USED_TARGETS
while IFS= read -r target; do
    USED_TARGETS+=("$target")
done < <(sudo virsh domblklist "$qemu_kvm_hostname" --details | awk '$2 == "disk" {print $3}')

# Function to get next available disk target
get_next_disk_target() {
    local letters=({b..z})
    for letter in "${letters[@]}"; do
        local target="vd${letter}"
        if ! printf '%s\n' "${USED_TARGETS[@]}" | grep -Fxq "$target"; then
            echo "$target"
            return 0
        fi
    done
    return 1
}

# Get disks to attach (from argument or prompt)
declare -a DISKS_TO_ATTACH

if [[ -n "$disks_arg" ]]; then
    # Parse comma-separated disk list
    IFS=',' read -ra DISKS_TO_ATTACH <<< "$disks_arg"
    
    # Validate each disk
    for disk in "${DISKS_TO_ATTACH[@]}"; do
        # Remove whitespace
        disk="${disk#"${disk%%[![:space:]]*}"}"  # Trim leading
        disk="${disk%"${disk##*[![:space:]]}"}"  # Trim trailing
        
        # Check if disk exists in detached directory
        if [[ ! -f "$DETACHED_DIR/$disk" ]]; then
            print_error "Disk $disk not found in detached storage: $DETACHED_DIR"
            exit 1
        fi
    done
    print_info "Using specified disks: ${DISKS_TO_ATTACH[*]}"
else
    # Interactive mode - show available disks
    print_notify "Available detached disks:"
    for i in "${!AVAILABLE_DISKS[@]}"; do
        disk="${AVAILABLE_DISKS[$i]}"
        disk_path="$DETACHED_DIR/$disk"
        if [[ -f "$disk_path" ]]; then
            disk_size=$(du -h "$disk_path" | awk '{print $1}')
            echo "  $((i+1))) $disk ($disk_size)"
        else
            echo "  $((i+1))) $disk"
        fi
    done
    echo "  q) Quit"
    
    print_info "Enter disk numbers to attach (space-separated, e.g., '1 3' or 'all' for all disks):"
    read -rp "Selection: " selection
    
    if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
        print_info "Quitting without any action."
        exit 0
    fi
    
    if [[ "$selection" == "all" || "$selection" == "ALL" ]]; then
        DISKS_TO_ATTACH=("${AVAILABLE_DISKS[@]}")
        print_info "Selected all disks: ${DISKS_TO_ATTACH[*]}"
    else
        # Parse space-separated numbers
        for num in $selection; do
            if [[ ! "$num" =~ ^[0-9]+$ ]]; then
                print_error "Invalid selection: $num"
                exit 1
            fi
            idx=$((num - 1))
            if (( idx < 0 || idx >= ${#AVAILABLE_DISKS[@]} )); then
                print_error "Invalid disk number: $num"
                exit 1
            fi
            DISKS_TO_ATTACH+=("${AVAILABLE_DISKS[$idx]}")
        done
        print_info "Selected disks: ${DISKS_TO_ATTACH[*]}"
    fi
fi

# Confirm attachment
print_warning "The following disk(s) will be attached to VM \"$qemu_kvm_hostname\" and renamed:"
for disk in "${DISKS_TO_ATTACH[@]}"; do
    disk_path="$DETACHED_DIR/$disk"
    if [[ -f "$disk_path" ]]; then
        disk_size=$(du -h "$disk_path" | awk '{print $1}')
        echo "  - $disk ($disk_size)"
    else
        echo "  - $disk"
    fi
done

read -rp "Type 'yes' to confirm: " confirm
if [[ "$confirm" != "yes" ]]; then
    print_info "Operation cancelled."
    exit 0
fi

# Attach and rename disks
attached_count=0
for disk in "${DISKS_TO_ATTACH[@]}"; do
    detached_path="$DETACHED_DIR/$disk"
    
    # Get next available target
    next_target=$(get_next_disk_target)
    if [[ -z "$next_target" ]]; then
        print_error "No more available disk targets. Maximum disks reached."
        break
    fi
    
    # Generate new disk name based on VM hostname
    new_disk_name="${qemu_kvm_hostname}_${next_target}.qcow2"
    new_disk_path="$VM_DIR/$new_disk_name"
    
    # Move disk to VM directory (rename only if needed)
    if [[ "$disk" == "$new_disk_name" ]]; then
        # Disk already has correct name, just move it
        print_task "Moving $disk to VM directory..." nskip
    else
        # Disk needs renaming
        print_task "Moving $disk to VM directory as $new_disk_name..." nskip
    fi
    
    if error_msg=$(sudo mv "$detached_path" "$new_disk_path" 2>&1); then
        print_task_done
    else
        print_task_fail
        print_error "$error_msg"
        continue
    fi
    
    # Attach disk to VM
    print_task "Attaching $new_disk_name to VM \"$qemu_kvm_hostname\" as $next_target..." nskip
    if error_msg=$(sudo virsh attach-disk "$qemu_kvm_hostname" "$new_disk_path" "$next_target" \
        --subdriver qcow2 --persistent 2>&1); then
        print_task_done
        USED_TARGETS+=("$next_target")
        ((++attached_count))
    else
        print_task_fail
        print_error "$error_msg"
        # Try to move disk back to detached directory
        sudo mv "$new_disk_path" "$detached_path" 2>/dev/null
        continue
    fi
done

if [[ $attached_count -eq 0 ]]; then
    print_error "Failed to attach any disks."
    exit 1
fi

print_task "Starting VM \"$qemu_kvm_hostname\"..." nskip

if error_msg=$(sudo virsh start "$qemu_kvm_hostname" 2>&1); then
    print_task_done
    print_success "Attached $attached_count disk(s) to VM \"$qemu_kvm_hostname\" and started successfully."
else
    print_task_fail
    print_error "Could not start VM \"$qemu_kvm_hostname\"."
    print_error "$error_msg"
    exit 1
fi
