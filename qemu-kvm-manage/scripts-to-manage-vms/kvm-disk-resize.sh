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
    print_cyan "Usage: tux2lab vm disk-resize [OPTIONS]
Options:
  -H, --host <host>    Hostname of the VM
  -f, --force          Force power-off without prompt if VM is running
  -d, --disk <disk>    Disk target to resize (e.g., vdb, vdc, vdd, all, default: prompt)
  -g, --gib <size>     Size in GiB to increase (1-100, default: prompt)
  -h, --help           Show this help message

Examples:
  tux2lab vm disk-resize -H vm1                      # Interactive mode with prompts
  tux2lab vm disk-resize -f -H vm1                   # Force power-off if running
  tux2lab vm disk-resize -d vdb -g 5 -H vm1          # Add 5 GiB to vdb
  tux2lab vm disk-resize -f -d vdc -g 10 -H vm1      # Fully automated: add 10 GiB to vdc
  tux2lab vm disk-resize -f -d vdc,vdd -g 10 -H vm1  # Fully automated: add 10 GiB to vdc and vdd
  tux2lab vm disk-resize -f -d all -g 10 -H vm1      # Fully automated: add 10 GiB to all additional disks

Note: This script only resizes additional disks (vdb, vdc, etc.).
      Use 'tux2lab vm resize disk <GiB> -H <hostname>' for OS disk (vda) resizing.
"
}

# Parse arguments
force_poweroff=false
vm_hostname_arg=""
disk_target_arg=""
gib_arg=""

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
        -d|--disk)
            if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                print_error "Option -d/--disk requires a value."
                exit 1
            fi
            disk_target_arg="$2"
            shift 2
            ;;
        -g|--gib)
            if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                print_error "Option -g/--gib requires a value."
                exit 1
            fi
            gib_arg="${2%[gG]}"
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

# Validate CLI-provided -g value early (before hostname/shutdown)
if [[ -n "$gib_arg" ]]; then
    if [[ ! "$gib_arg" =~ ^[1-9][0-9]*$ ]] || (( gib_arg > 100 )); then
        print_error "Invalid disk increase size: ${gib_arg}. Must be between 1 and 100 GiB."
        exit 1
    fi
fi

# Use argument or prompt for hostname
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/input-hostname.sh "$vm_hostname_arg"

# Lab infra server warning (not blocking, just notify)
if [[ "$qemu_kvm_hostname" == "$lab_infra_server_hostname" ]]; then
    print_warning "You are resizing a disk on the lab infra server: $lab_infra_server_hostname"
    print_info "This requires shutting down the lab infra server temporarily."
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

# Get list of additional disks (excluding vda/OS disk)
declare -a ADDITIONAL_DISKS
declare -A DISK_PATHS
declare -A SEEN_DISKS
for disk_file in "$VM_DIR"/*.qcow2; do
    [[ -e "$disk_file" ]] || continue
    BASENAME=$(basename "$disk_file")
    # Skip OS disk (vda)
    if [[ "$BASENAME" == "${qemu_kvm_hostname}.qcow2" || "$BASENAME" == "${qemu_kvm_hostname}_vda.qcow2" ]]; then
        continue
    fi
    # Extract disk target (e.g., vdb, vdc)
    if [[ "$BASENAME" =~ ${qemu_kvm_hostname}_(vd[b-z])\.qcow2 ]]; then
        DISK_TARGET="${BASH_REMATCH[1]}"
        # Only add if not already seen (avoid duplicates)
        if [[ -z "${SEEN_DISKS[$DISK_TARGET]+isset}" ]]; then
            ADDITIONAL_DISKS+=("$DISK_TARGET")
            DISK_PATHS["$DISK_TARGET"]="$disk_file"
            SEEN_DISKS["$DISK_TARGET"]=1
        fi
    fi
done

# Check if there are any additional disks
if (( ${#ADDITIONAL_DISKS[@]} == 0 )); then
    print_error "No additional disks found for VM \"$qemu_kvm_hostname\"."
    print_info "This script only resizes additional disks (vdb, vdc, etc.)."
    print_info "Use 'tux2lab vm resize disk <GiB> -H <hostname>' to resize the OS disk."
    exit 1
fi

# Track if we're in interactive mode
INTERACTIVE_MODE=false
if [[ -z "$disk_target_arg" ]]; then
    INTERACTIVE_MODE=true
fi

# Track resized disks for interactive multi-resize
RESIZED_DISKS=()
declare -A DISK_NEW_SIZES

# Main resize loop (for interactive mode with multiple disks)
while true; do
    # Validate disk target argument if provided
    if [[ -n "$disk_target_arg" ]]; then
        # Normalize to lowercase
        disk_target_arg=${disk_target_arg,,}
        
        # Check if user wants to resize all disks
        if [[ "$disk_target_arg" == "all" ]]; then
            RESIZE_ALL=true
        elif [[ "$disk_target_arg" == *,* ]]; then
            # Comma-separated list of disks
            RESIZE_ALL=false
            RESIZE_MULTIPLE=true
            IFS=',' read -ra SELECTED_DISKS_ARRAY <<< "$disk_target_arg"
            
            # Validate each disk in the list
            for disk in "${SELECTED_DISKS_ARRAY[@]}"; do
                disk="${disk#"${disk%%[![:space:]]*}"}"  # Trim leading
                disk="${disk%"${disk##*[![:space:]]}"}"  # Trim trailing
                FOUND=false
                for available_disk in "${ADDITIONAL_DISKS[@]}"; do
                    if [[ "$disk" == "$available_disk" ]]; then
                        FOUND=true
                        break
                    fi
                done
                
                if [[ "$FOUND" == false ]]; then
                    print_error "Disk \"$disk\" not found or is not an additional disk."
                    print_info "Available additional disks: ${ADDITIONAL_DISKS[*]}"
                    exit 1
                fi
            done
        else
            # Single disk
            FOUND=false
            for disk in "${ADDITIONAL_DISKS[@]}"; do
                if [[ "$disk" == "$disk_target_arg" ]]; then
                    FOUND=true
                    break
                fi
            done
            
            if [[ "$FOUND" == false ]]; then
                print_error "Disk \"$disk_target_arg\" not found or is not an additional disk."
                print_info "Available additional disks: ${ADDITIONAL_DISKS[*]}"
                exit 1
            fi
            
            SELECTED_DISK="$disk_target_arg"
            RESIZE_ALL=false
            RESIZE_MULTIPLE=false
        fi
    else
        # Prompt for disk selection
        # Filter out already resized disks
        AVAILABLE_DISKS=()
        for disk in "${ADDITIONAL_DISKS[@]}"; do
            ALREADY_RESIZED=false
            for resized in "${RESIZED_DISKS[@]}"; do
                if [[ "$disk" == "$resized" ]]; then
                    ALREADY_RESIZED=true
                    break
                fi
            done
            if [[ "$ALREADY_RESIZED" == false ]]; then
                AVAILABLE_DISKS+=("$disk")
            fi
        done
        
        # Check if any disks left to resize
        if (( ${#AVAILABLE_DISKS[@]} == 0 )); then
            print_info "All additional disks have been resized."
            break
        fi
        
        print_info "Available additional disks for VM \"$qemu_kvm_hostname\":"
        for i in "${!AVAILABLE_DISKS[@]}"; do
            disk="${AVAILABLE_DISKS[$i]}"
            echo "  $((i+1))) $disk"
        done
        
        # Only show "all" option if more than one disk available and this is first iteration
        if (( ${#AVAILABLE_DISKS[@]} > 1 && ${#RESIZED_DISKS[@]} == 0 )); then
            echo "  a) All additional disks"
        fi
        
        while true; do
            if (( ${#AVAILABLE_DISKS[@]} > 1 && ${#RESIZED_DISKS[@]} == 0 )); then
                read -rp "Select disk to resize (1-${#AVAILABLE_DISKS[@]}, a): " disk_choice
            else
                read -rp "Select disk to resize (1-${#AVAILABLE_DISKS[@]}): " disk_choice
            fi
            
            if [[ "$disk_choice" == "a" || "$disk_choice" == "A" ]] && (( ${#AVAILABLE_DISKS[@]} > 1 && ${#RESIZED_DISKS[@]} == 0 )); then
                RESIZE_ALL=true
                print_info "Selected: All additional disks"
                break
            elif [[ "$disk_choice" =~ ^[0-9]+$ ]] && (( disk_choice >= 1 && disk_choice <= ${#AVAILABLE_DISKS[@]} )); then
                SELECTED_DISK="${AVAILABLE_DISKS[$((disk_choice-1))]}"
                print_info "Selected disk: $SELECTED_DISK"
                RESIZE_ALL=false
                break
            else
                if (( ${#AVAILABLE_DISKS[@]} > 1 && ${#RESIZED_DISKS[@]} == 0 )); then
                    print_error "Invalid selection! Enter a number between 1 and ${#AVAILABLE_DISKS[@]}, or 'a' for all."
                else
                    print_error "Invalid selection! Enter a number between 1 and ${#AVAILABLE_DISKS[@]}."
                fi
            fi
        done
    fi

    # Shutdown VM if running (only once, before first resize operation)
    if [[ "${VM_SHUTDOWN_DONE:-false}" == false ]]; then
        if ! sudo virsh list | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; then
            print_info "VM \"$qemu_kvm_hostname\" is not running. Proceeding further."
        else
            fn_shutdown_or_poweroff
        fi
        VM_SHUTDOWN_DONE=true
    fi

    # Validate gib argument if provided (only first iteration in interactive mode)
    if [[ -n "$gib_arg" ]] || [[ "$INTERACTIVE_MODE" == false ]]; then
        if [[ -n "$gib_arg" ]]; then
            grow_size_gib="$gib_arg"
            print_info "Using increase size: ${grow_size_gib} GiB"
        fi
    else
        # Prompt for disk increase size - show current sizes now that VM is stopped
        if [[ "$RESIZE_ALL" == true ]]; then
            print_info "Resizing all additional disks:"
            for disk in "${AVAILABLE_DISKS[@]}"; do
                disk_path="${DISK_PATHS[$disk]}"
                disk_size=$(sudo qemu-img info "$disk_path" | awk '/virtual size/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $(i+1)=="GiB") {print $i; exit}}')
                echo "  - $disk: ${disk_size} GiB"
            done
        else
            # Show current size for single disk
            SELECTED_DISK_PATH="${DISK_PATHS[$SELECTED_DISK]}"
            current_disk_gib=$(sudo qemu-img info "$SELECTED_DISK_PATH" | awk '/virtual size/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $(i+1)=="GiB") {print $i; exit}}')
            print_info "Current size of $SELECTED_DISK: ${current_disk_gib} GiB"
        fi
        print_info "Allowed increase size: 1-100 GiB"

        while true; do
            read -rp "Enter increase size (GiB): " grow_size_gib

            if [[ "$grow_size_gib" =~ ^[1-9][0-9]*$ ]] && (( grow_size_gib <= 100 )); then
                break
            else
                print_error "Invalid size! Enter a number between 1 and 100."
            fi
        done
    fi

    # Perform the disk resize
    if [[ "$RESIZE_ALL" == true ]]; then
        # Resize all additional disks
        # Use AVAILABLE_DISKS in interactive mode, ADDITIONAL_DISKS in automated mode
        DISKS_TO_RESIZE=("${AVAILABLE_DISKS[@]}")
        if [[ "$INTERACTIVE_MODE" == false ]]; then
            DISKS_TO_RESIZE=("${ADDITIONAL_DISKS[@]}")
        fi
        
        for disk in "${DISKS_TO_RESIZE[@]}"; do
            disk_path="${DISK_PATHS[$disk]}"
            current_disk_gib=$(sudo qemu-img info "$disk_path" | awk '/virtual size/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $(i+1)=="GiB") {print $i; exit}}')
            
            print_task "Growing $disk by ${grow_size_gib} GiB..." nskip
            if error_msg=$(sudo qemu-img resize "$disk_path" +${grow_size_gib}G 2>&1); then
                print_task_done
                new_disk_size=$(( current_disk_gib + grow_size_gib ))
                print_info "Disk $disk resized from ${current_disk_gib} GiB to ${new_disk_size} GiB."
                RESIZED_DISKS+=("$disk")
                DISK_NEW_SIZES["$disk"]="$new_disk_size"
            else
                print_task_fail
                print_error "$error_msg"
                break
            fi
        done
        # After resizing all, we're done
        break
    elif [[ "${RESIZE_MULTIPLE:-false}" == true ]]; then
        # Resize multiple specific disks (comma-separated)
        for disk in "${SELECTED_DISKS_ARRAY[@]}"; do
            disk="${disk#"${disk%%[![:space:]]*}"}"  # Trim leading
            disk="${disk%"${disk##*[![:space:]]}"}"  # Trim trailing
            disk_path="${DISK_PATHS[$disk]}"
            current_disk_gib=$(sudo qemu-img info "$disk_path" | awk '/virtual size/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $(i+1)=="GiB") {print $i; exit}}')
            
            print_task "Growing $disk by ${grow_size_gib} GiB..." nskip
            if error_msg=$(sudo qemu-img resize "$disk_path" +${grow_size_gib}G 2>&1); then
                print_task_done
                new_disk_size=$(( current_disk_gib + grow_size_gib ))
                print_info "Disk $disk resized from ${current_disk_gib} GiB to ${new_disk_size} GiB."
                RESIZED_DISKS+=("$disk")
                DISK_NEW_SIZES["$disk"]="$new_disk_size"
            else
                print_task_fail
                print_error "$error_msg"
                break
            fi
        done
        # After resizing multiple, we're done
        break
    else
        # Resize single disk
        SELECTED_DISK_PATH="${DISK_PATHS[$SELECTED_DISK]}"
        current_disk_gib=$(sudo qemu-img info "$SELECTED_DISK_PATH" | awk '/virtual size/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $(i+1)=="GiB") {print $i; exit}}')
        
        print_task "Growing $SELECTED_DISK by ${grow_size_gib} GiB..." nskip
        if error_msg=$(sudo qemu-img resize "$SELECTED_DISK_PATH" +${grow_size_gib}G 2>&1); then
            print_task_done
            new_disk_size=$(( current_disk_gib + grow_size_gib ))
            print_info "Disk $SELECTED_DISK resized from ${current_disk_gib} GiB to ${new_disk_size} GiB."
            RESIZED_DISKS+=("$SELECTED_DISK")
            DISK_NEW_SIZES["$SELECTED_DISK"]="$new_disk_size"
        else
            print_task_fail
            print_error "$error_msg"
        fi
    fi
    
    # In automated mode or after resizing all, exit loop
    if [[ "$INTERACTIVE_MODE" == false ]] || [[ "$RESIZE_ALL" == true ]]; then
        break
    fi
    
    # In interactive mode, check if there are more disks available and ask if user wants to resize another
    REMAINING_DISKS=()
    for disk in "${ADDITIONAL_DISKS[@]}"; do
        ALREADY_RESIZED=false
        for resized in "${RESIZED_DISKS[@]}"; do
            if [[ "$disk" == "$resized" ]]; then
                ALREADY_RESIZED=true
                break
            fi
        done
        if [[ "$ALREADY_RESIZED" == false ]]; then
            REMAINING_DISKS+=("$disk")
        fi
    done
    
    # If no more disks to resize, exit
    if (( ${#REMAINING_DISKS[@]} == 0 )); then
        break
    fi
    
    # Ask if user wants to resize another disk
    echo
    while true; do
        read -rp "Do you want to resize another disk? (y/n): " resize_another
        case "$resize_another" in
            y|Y|yes|Yes|YES)
                # Continue loop
                break
                ;;
            n|N|no|No|NO)
                # Exit loop
                break 2
                ;;
            *)
                print_error "Invalid input! Enter 'y' for yes or 'n' for no."
                ;;
        esac
    done
done

# Start the VM
print_task "Starting VM \"$qemu_kvm_hostname\"..." nskip
if error_msg=$(sudo virsh start "$qemu_kvm_hostname" 2>&1); then
    print_task_done
    if (( ${#RESIZED_DISKS[@]} > 1 )); then
        print_success "[VM: $qemu_kvm_hostname] Successfully resized ${#RESIZED_DISKS[@]} disk(s) and started."
        for disk in "${RESIZED_DISKS[@]}"; do
            print_info "  - $disk: Final size ${DISK_NEW_SIZES[$disk]} GiB"
        done
    elif (( ${#RESIZED_DISKS[@]} == 1 )); then
        disk="${RESIZED_DISKS[0]}"
        print_success "[VM: $qemu_kvm_hostname] Disk $disk successfully resized to ${DISK_NEW_SIZES[$disk]} GiB and VM started."
    else
        print_warning "[VM: $qemu_kvm_hostname] No disks were resized, but VM started successfully."
    fi
    print_info "You may need to resize the partitions and filesystems at the operating system level."
else
    print_task_fail
    print_error "Could not start VM \"$qemu_kvm_hostname\"."
    print_error "$error_msg"
    exit 1
fi
