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
    print_cyan "Usage: tux2lab vm disk-detach [OPTIONS]
Options:
  -H, --host <host>    Hostname of the VM
  -f, --force          Force power-off without prompt if VM is running
  -d, --disks <list>   Comma-separated list of disk targets to detach (e.g., vdb,vdc)
  -h, --help           Show this help message

Examples:
  tux2lab vm disk-detach -H vm1                     # Interactive mode - select disks
  tux2lab vm disk-detach -f -H vm1                  # Force power-off if running
  tux2lab vm disk-detach -d vdb,vdc -H vm1          # Detach specific disks
  tux2lab vm disk-detach -f -d vdb,vdc -H vm1       # Fully automated
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
        -H|--host)
            if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                print_error "Option -H/--host requires a value."
                exit 1
            fi
            vm_hostname_arg="$2"
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

# Lab infra server protection
if [[ "$qemu_kvm_hostname" == "$lab_infra_server_hostname" ]]; then
    print_warning "You are about to detach disk(s) from the lab infra server: $lab_infra_server_hostname!"
    print_warning "This operation requires shutting down the lab infra server temporarily."
    print_warning "Boot disk (vda) cannot be detached and will be automatically excluded."
    read -r -p "If you understand the impact, confirm by typing 'detach-disk-from-lab-infra': " confirmation
    if [[ "$confirmation" != "detach-disk-from-lab-infra" ]]; then
        print_info "Operation cancelled by user."
        exit 1
    fi
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

VM_DIR="/tux2lab-data/vms/${qemu_kvm_hostname}"

# Verify VM directory exists
if [[ ! -d "$VM_DIR" ]]; then
    print_error "VM directory does not exist: $VM_DIR"
    exit 1
fi

# Get list of attached disks (excluding vda which is OS disk)
print_info "Scanning attached disks..."
ATTACHED_DISKS=()
while IFS= read -r disk_target; do
    [[ "$disk_target" != "vda" ]] && ATTACHED_DISKS+=("$disk_target")
done < <(sudo virsh domblklist "$qemu_kvm_hostname" --details | awk '$2 == "disk" {print $3}')

if [[ ${#ATTACHED_DISKS[@]} -eq 0 ]]; then
    print_warning "No additional disks found to detach (only OS disk vda is present)."
    exit 0
fi

# Get disks to detach (from argument or prompt)
DISKS_TO_DETACH=()

if [[ -n "$disks_arg" ]]; then
    # Parse comma-separated disk list
    IFS=',' read -ra DISKS_TO_DETACH <<< "$disks_arg"
    
    # Validate each disk
    for disk in "${DISKS_TO_DETACH[@]}"; do
        # Remove whitespace
        disk="${disk#"${disk%%[![:space:]]*}"}"  # Trim leading
        disk="${disk%"${disk##*[![:space:]]}"}"  # Trim trailing
        
        if [[ "$disk" == "vda" ]]; then
            print_error "Cannot detach OS disk vda."
            exit 1
        fi
        
        # Check if disk is actually attached
        if ! printf '%s\n' "${ATTACHED_DISKS[@]}" | grep -Fxq "$disk"; then
            print_error "Disk $disk is not attached to VM \"$qemu_kvm_hostname\"."
            exit 1
        fi
    done
    print_info "Using specified disks: ${DISKS_TO_DETACH[*]}"
else
    # Interactive mode - show available disks
    print_notify "Available disks to detach:"
    for i in "${!ATTACHED_DISKS[@]}"; do
        disk="${ATTACHED_DISKS[$i]}"
        # Get disk size
        disk_path=$(sudo virsh domblklist "$qemu_kvm_hostname" | awk -v target="$disk" '$1 == target {print $2}')
        if [[ -f "$disk_path" ]]; then
            disk_size=$(sudo qemu-img info "$disk_path" | awk '/virtual size/ {print $3, $4}')
            echo "  $((i+1))) $disk ($disk_size)"
        else
            echo "  $((i+1))) $disk"
        fi
    done
    echo "  q) Quit"
    
    print_info "Enter disk numbers to detach (space-separated, e.g., '1 3' or 'all' for all disks):"
    read -rp "Selection: " selection
    
    if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
        print_info "Quitting without any action."
        exit 0
    fi
    
    if [[ "$selection" == "all" || "$selection" == "ALL" ]]; then
        DISKS_TO_DETACH=("${ATTACHED_DISKS[@]}")
        print_info "Selected all disks: ${DISKS_TO_DETACH[*]}"
    else
        # Parse space-separated numbers
        for num in $selection; do
            if [[ ! "$num" =~ ^[0-9]+$ ]]; then
                print_error "Invalid selection: $num"
                exit 1
            fi
            idx=$((num - 1))
            if (( idx < 0 || idx >= ${#ATTACHED_DISKS[@]} )); then
                print_error "Invalid disk number: $num"
                exit 1
            fi
            DISKS_TO_DETACH+=("${ATTACHED_DISKS[$idx]}")
        done
        print_info "Selected disks: ${DISKS_TO_DETACH[*]}"
    fi
fi

# Confirm detachment
print_warning "The following disk(s) will be detached and moved to detached storage:"
for disk in "${DISKS_TO_DETACH[@]}"; do
    disk_path=$(sudo virsh domblklist "$qemu_kvm_hostname" | awk -v target="$disk" '$1 == target {print $2}')
    if [[ -f "$disk_path" ]]; then
        disk_size=$(sudo qemu-img info "$disk_path" | awk '/virtual size/ {print $3, $4}')
        echo "  - $disk ($disk_size) at $disk_path"
    else
        echo "  - $disk at $disk_path"
    fi
done

read -rp "Type 'yes' to confirm: " confirm
if [[ "$confirm" != "yes" ]]; then
    print_info "Operation cancelled."
    exit 0
fi

# Shut down VM if running (only after confirming there's work to do)
if ! sudo virsh list | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; then
    print_info "VM \"$qemu_kvm_hostname\" is not running. Proceeding further."
else
    fn_shutdown_or_poweroff
fi

# Ensure detached disks directory exists
DETACHED_DIR="/tux2lab-data/detached-data-disks"
sudo mkdir -p "$DETACHED_DIR"
sudo chown "${lab_infra_admin_username}:$(id -gn "${lab_infra_admin_username}")" "$DETACHED_DIR"

# Detach and move disks
for disk in "${DISKS_TO_DETACH[@]}"; do
    disk_path=$(sudo virsh domblklist "$qemu_kvm_hostname" | awk -v target="$disk" '$1 == target {print $2}')
    disk_name=$(basename "$disk_path")
    detached_path="${DETACHED_DIR}/${disk_name}"
    
    # Detach disk
    print_task "Detaching $disk from VM \"$qemu_kvm_hostname\"..." nskip
    if error_msg=$(sudo virsh detach-disk "$qemu_kvm_hostname" "$disk" --persistent 2>&1); then
        print_task_done
    else
        print_task_fail
        print_error "$error_msg"
        continue
    fi
    
    # Move disk file to detached storage
    if [[ -f "$disk_path" ]]; then
        print_task "Moving $disk to detached storage..." nskip
        if error_msg=$(sudo mv "$disk_path" "$detached_path" 2>&1); then
            print_task_done
            print_info "Disk saved to: $detached_path"
        else
            print_task_fail
            print_error "$error_msg"
            print_warning "Disk was detached from VM but failed to move to detached storage."
        fi
    fi
done

print_task "Starting VM \"$qemu_kvm_hostname\"..." nskip

if error_msg=$(sudo virsh start "$qemu_kvm_hostname" 2>&1); then
    print_task_done
    print_success "Detached ${#DISKS_TO_DETACH[@]} disk(s) from VM \"$qemu_kvm_hostname\" and started successfully."
    print_info "Detached disks are stored in: $DETACHED_DIR"
else
    print_task_fail
    print_error "Could not start VM \"$qemu_kvm_hostname\"."
    print_error "$error_msg"
    exit 1
fi
