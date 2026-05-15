#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# Initialize variables
vm_hostname_arg=""

# Function to show help
fn_show_help() {
    print_cyan "Usage: tux2lab vm console [-H hostname]

Options:
  -H, --host           Name of the VM to access console (optional, will prompt if not given)
  -h, --help           Show this help message

Examples:
  tux2lab vm console -H vm1               # Access console of VM
  
Note: Press Ctrl+] to exit the console.
"
}

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            fn_show_help
            exit 0
            ;;
        -H|--host)
            if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                print_error "'-H' requires a hostname value."
                exit 1
            fi
            vm_hostname_arg="$2"
            shift 2
            ;;
        -*)
            print_error "No such option: $1"
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

# Use argument or prompt for hostname
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/input-hostname.sh "$vm_hostname_arg" "ALLOW_SELF_REFERENCE"

# Check if VM exists in 'virsh list --all'
if ! sudo virsh list --all | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; then
    print_error "VM \"$qemu_kvm_hostname\" does not exist."
    exit 1
fi

# Check if VM is running
if ! sudo virsh list | awk '{print $2}' | grep -Fxq "$qemu_kvm_hostname"; then
    print_error "VM \"$qemu_kvm_hostname\" is not running."
    exit 1
fi

# Proceed to access console
print_info "Connecting to console of VM \"$qemu_kvm_hostname\"..."
print_notify "Press Ctrl+] to exit the console."
sudo virsh console "$qemu_kvm_hostname"