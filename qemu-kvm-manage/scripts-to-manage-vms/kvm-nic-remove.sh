#!/bin/bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# Function to show help
fn_show_help() {
    print_cyan "Usage: qlabvmctl nic-remove [OPTIONS] [hostname]
Options:
  -f, --force          Force power-off without prompt if VM is running
  -m, --macs <list>    Comma-separated list of MAC addresses to remove
  -h, --help           Show this help message

Arguments:
  hostname             Name of the VM to remove NICs from (optional, will prompt if not given)

Examples:
  qlabvmctl nic-remove vm1                              # Interactive mode - select NICs
  qlabvmctl nic-remove -f vm1                           # Force power-off if running
  qlabvmctl nic-remove -m 52:54:00:aa:bb:cc vm1        # Remove specific NIC
  qlabvmctl nic-remove -f -m 52:54:00:11:22:33 vm2     # Fully automated
"
}

# Parse arguments
force_poweroff=false
vm_hostname_arg=""
macs_arg=""

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
        -m|--macs)
            if [[ -z "$2" || "$2" == -* ]]; then
                print_error "Option -m/--macs requires a value."
                exit 1
            fi
            macs_arg="$2"
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

# Lab infra server protection
if [[ "$qemu_kvm_hostname" == "$lab_infra_server_hostname" ]]; then
    print_warning "You are about to remove NIC(s) from the lab infra server: $lab_infra_server_hostname!"
    print_warning "Removing the primary network interface will break lab connectivity."
    print_warning "This operation requires shutting down the lab infra server temporarily."
    read -r -p "If you understand the impact, confirm by typing 'remove-nic-from-lab-infra': " confirmation
    if [[ "$confirmation" != "remove-nic-from-lab-infra" ]]; then
        print_info "Operation cancelled by user."
        exit 1
    fi
fi

# Check if VM exists
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

if ! sudo virsh list | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; then
    print_info "VM \"$qemu_kvm_hostname\" is not running. Proceeding further."
else
    fn_shutdown_or_poweroff
fi

# Get list of NICs attached to VM
print_info "Scanning NICs attached to VM \"$qemu_kvm_hostname\"..."
declare -a AVAILABLE_NICS
while IFS='|' read -r type network model mac; do
    # Skip header and empty lines
    [[ -z "$mac" || "$mac" == "-" ]] && continue
    # Clean up whitespace
    mac="${mac#"${mac%%[![:space:]]*}"}"; mac="${mac%"${mac##*[![:space:]]}"}"  # Trim
    type="${type#"${type%%[![:space:]]*}"}"; type="${type%"${type##*[![:space:]]}"}"  # Trim
    network="${network#"${network%%[![:space:]]*}"}"; network="${network%"${network##*[![:space:]]}"}"  # Trim
    [[ -z "$mac" ]] && continue
    AVAILABLE_NICS+=("$mac|$type|$network")
done < <(sudo virsh domiflist "$qemu_kvm_hostname" | awk 'NR>2 && NF>=5 {print $2"|"$3"|"$4"|"$5}')

if [[ ${#AVAILABLE_NICS[@]} -eq 0 ]]; then
    print_warning "No NICs found attached to VM \"$qemu_kvm_hostname\""
    exit 0
fi

# Check if VM has only one NIC
if [[ ${#AVAILABLE_NICS[@]} -eq 1 ]]; then
    print_error "Cannot remove the last NIC from VM \"$qemu_kvm_hostname\""
    print_info "VMs must have at least one network interface."
    exit 1
fi

# Get NICs to remove (from argument or prompt)
declare -a MACS_TO_REMOVE

if [[ -n "$macs_arg" ]]; then
    # Parse comma-separated MAC list
    IFS=',' read -ra MACS_TO_REMOVE <<< "$macs_arg"
    
    # Get primary NIC MAC (first one)
    primary_mac="${AVAILABLE_NICS[0]%%|*}"
    
    # Validate each MAC
    for mac in "${MACS_TO_REMOVE[@]}"; do
        # Remove whitespace
        mac="${mac#"${mac%%[![:space:]]*}"}"  # Trim leading
        mac="${mac%"${mac##*[![:space:]]}"}"  # Trim trailing
        
        # Check if trying to remove primary NIC
        if [[ "$mac" == "$primary_mac" ]]; then
            print_error "Cannot remove primary NIC with MAC $mac"
            print_info "The first NIC is the primary interface and must remain attached."
            exit 1
        fi
        
        # Check if MAC exists
        found=false
        for nic in "${AVAILABLE_NICS[@]}"; do
            nic_mac="${nic%%|*}"
            if [[ "$nic_mac" == "$mac" ]]; then
                found=true
                break
            fi
        done
        
        if [[ "$found" == false ]]; then
            print_error "MAC address $mac not found on VM \"$qemu_kvm_hostname\""
            exit 1
        fi
    done
    print_info "Using specified MACs: ${MACS_TO_REMOVE[*]}"
else
    # Interactive mode - show available NICs
    print_notify "NICs attached to VM \"$qemu_kvm_hostname\":"
    for i in "${!AVAILABLE_NICS[@]}"; do
        IFS='|' read -r mac type network <<< "${AVAILABLE_NICS[$i]}"
        if [[ $i -eq 0 ]]; then
            echo "  $((i+1))) MAC: $mac, Type: $type, Network: $network [PRIMARY - Cannot be removed]"
        else
            echo "  $((i+1))) MAC: $mac, Type: $type, Network: $network"
        fi
    done
    echo "  q) Quit"
    
    print_info "Enter NIC numbers to remove (space-separated, e.g., '2 3'):"
    print_warning "Note: NIC #1 is the primary interface and cannot be removed."
    read -rp "Selection: " selection
    
    if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
        print_info "Quitting without any action."
        exit 0
    fi
    
    # Parse space-separated numbers
    for num in $selection; do
        if [[ ! "$num" =~ ^[0-9]+$ ]]; then
            print_error "Invalid selection: $num"
            exit 1
        fi
        
        # Prevent removal of primary NIC (index 0)
        if [[ $num -eq 1 ]]; then
            print_error "Cannot remove NIC #1 - it is the primary interface."
            exit 1
        fi
        
        idx=$((num - 1))
        if (( idx < 0 || idx >= ${#AVAILABLE_NICS[@]} )); then
            print_error "Invalid NIC number: $num"
            exit 1
        fi
        mac="${AVAILABLE_NICS[$idx]%%|*}"
        MACS_TO_REMOVE+=("$mac")
    done
    print_info "Selected MACs: ${MACS_TO_REMOVE[*]}"
fi

# Check if removing all NICs
if [[ ${#MACS_TO_REMOVE[@]} -ge ${#AVAILABLE_NICS[@]} ]]; then
    print_error "Cannot remove all NICs from VM \"$qemu_kvm_hostname\""
    print_info "VMs must have at least one network interface."
    exit 1
fi

# Confirm removal
print_warning "The following NIC(s) will be permanently removed from VM \"$qemu_kvm_hostname\":"
for mac in "${MACS_TO_REMOVE[@]}"; do
    for nic in "${AVAILABLE_NICS[@]}"; do
        IFS='|' read -r nic_mac type network <<< "$nic"
        if [[ "$nic_mac" == "$mac" ]]; then
            echo "  - MAC: $mac, Type: $type, Network: $network"
            break
        fi
    done
done

read -rp "Type 'yes' to confirm: " confirm
if [[ "$confirm" != "yes" ]]; then
    print_info "Operation cancelled."
    exit 0
fi

# Remove NICs
removed_count=0
for mac in "${MACS_TO_REMOVE[@]}"; do
    print_task "Removing NIC with MAC $mac from VM \"$qemu_kvm_hostname\"..." nskip
    if error_msg=$(sudo virsh detach-interface "$qemu_kvm_hostname" network --mac "$mac" --config 2>&1); then
        print_task_done
        ((removed_count++))
    else
        print_task_fail
        print_error "$error_msg"
    fi
done

if [[ $removed_count -eq 0 ]]; then
    print_error "Failed to remove any NICs."
    exit 1
fi

print_task "Starting VM \"$qemu_kvm_hostname\"..." nskip

if error_msg=$(sudo virsh start "$qemu_kvm_hostname" 2>&1); then
    print_task_done
    print_success "Removed $removed_count NIC(s) from VM \"$qemu_kvm_hostname\" and started successfully."
else
    print_task_fail
    print_error "Could not start VM \"$qemu_kvm_hostname\"."
    print_error "$error_msg"
    exit 1
fi
