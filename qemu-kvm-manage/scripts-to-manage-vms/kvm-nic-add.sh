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
    print_cyan "Usage: tux2lab vm nic-add [OPTIONS]
Options:
  -H, --host <name>    Name of the VM to add NICs to (will prompt if not given)
  -f, --force          Force power-off without prompt if VM is running
  -c, --count <num>    Number of NICs to add (1-10, default: 1)
  -n, --network <name> Network/bridge to attach to (default: tux2lab)
  -h, --help           Show this help message

Examples:
  tux2lab vm nic-add -H vm1                      # Interactive mode - add 1 NIC
  tux2lab vm nic-add -f -H vm1                   # Force power-off if running
  tux2lab vm nic-add -c 2 -H vm1                 # Add 2 NICs
  tux2lab vm nic-add -n br0 -H vm1               # Add NIC to specific bridge
  tux2lab vm nic-add -f -c 3 -n tux2lab -H vm2   # Fully automated
"
}

# Parse arguments
force_poweroff=false
vm_hostname_arg=""
nic_count=1
nic_count_provided=false
network_name="tux2lab"

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
                print_error "Option -H/--host requires a value."
                exit 1
            fi
            vm_hostname_arg="$2"
            shift 2
            ;;
        -c|--count)
            if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                print_error "Option -c/--count requires a value."
                exit 1
            fi
            nic_count="$2"
            nic_count_provided=true
            shift 2
            ;;
        -n|--network)
            if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                print_error "Option -n/--network requires a value."
                exit 1
            fi
            network_name="$2"
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
    print_info "Adding NIC to lab infra server: $lab_infra_server_hostname"
fi

# Check if VM exists
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/check-vm-exists.sh
check_vm_exists "$qemu_kvm_hostname" "nic-add"

# Prompt for NIC count if not provided via -c flag
if [[ "$nic_count_provided" == false ]]; then
    print_info "How many NICs do you want to add? (1-10, default: 1)"
    read -rp "Enter count: " user_nic_count
    if [[ -n "$user_nic_count" ]]; then
        nic_count="$user_nic_count"
    fi
fi

# Validate NIC count
if ! [[ "$nic_count" =~ ^[0-9]+$ ]] || (( nic_count < 1 || nic_count > 10 )); then
    print_error "NIC count must be a number between 1 and 10."
    exit 1
fi

# Check if network/bridge exists (check both libvirt networks and system bridges)
network_exists=false
if sudo virsh net-list --all | awk '{print $1}' | grep -Fxq "$network_name"; then
    network_exists=true
elif ip link show "$network_name" &>/dev/null; then
    # It's a system bridge
    network_exists=true
fi

if [[ "$network_exists" == false ]]; then
    print_error "Network/bridge \"$network_name\" does not exist."
    print_info "Available libvirt networks:"
    sudo virsh net-list --all | tail -n +3 | awk 'NF>0 {print "  - " $1}'
    print_info "Available bridge interfaces:"
    ip link show type bridge 2>/dev/null | grep -oP '^\d+: \K[^:]+' | awk '{print "  - " $1}' || true
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

# Confirm NIC addition
print_warning "About to add $nic_count NIC(s) to VM \"$qemu_kvm_hostname\" on network \"$network_name\""
read -rp "Type 'yes' to confirm: " confirm
if [[ "$confirm" != "yes" ]]; then
    print_info "Operation cancelled."
    exit 0
fi

# Source MAC address generation functions
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/generate-mac-address.sh

# Add NICs
added_count=0
for ((i=1; i<=nic_count; i++)); do
    # Generate unique MAC address
    print_task "Generating MAC address for NIC #$i..."
    if ! mac=$(generate_unique_mac "$qemu_kvm_hostname"); then
        print_task_fail
        break
    fi
    print_task_done
    
    # Determine interface type (network or bridge)
    interface_type="network"
    if ! sudo virsh net-list --all | awk '{print $1}' | grep -Fxq "$network_name"; then
        # Not a libvirt network, must be a bridge
        interface_type="bridge"
    fi
    
    print_task "Adding NIC #$i with MAC $mac to $interface_type \"$network_name\"..." nskip
    if error_msg=$(sudo virsh attach-interface "$qemu_kvm_hostname" "$interface_type" "$network_name" \
        --mac "$mac" --model virtio --config 2>&1); then
        print_task_done
        USED_MACS+=("$mac")
        ((++added_count))
    else
        print_task_fail
        print_error "$error_msg"
    fi
done

if [[ $added_count -eq 0 ]]; then
    print_error "Failed to add any NICs."
    exit 1
fi

print_task "Starting VM \"$qemu_kvm_hostname\"..." nskip

if error_msg=$(sudo virsh start "$qemu_kvm_hostname" 2>&1); then
    print_task_done
    print_success "Added $added_count NIC(s) to VM \"$qemu_kvm_hostname\" and started successfully."
else
    print_task_fail
    print_error "Could not start VM \"$qemu_kvm_hostname\"."
    print_error "$error_msg"
    exit 1
fi
