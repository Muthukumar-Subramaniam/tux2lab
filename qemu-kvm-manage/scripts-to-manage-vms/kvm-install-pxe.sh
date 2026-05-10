#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/select-ovmf.sh

ATTACH_CONSOLE="no"
OS_DISTRO=""
VERSION_TYPE=""
HOSTNAMES=()
SUPPORTS_DISTRO="yes"
SUPPORTS_VERSION="yes"

# Function to show help
fn_show_help() {
    print_cyan "Usage: tux2lab vm install-pxe [OPTIONS] [hostname]
Options:
  -c, --console        Attach console during installation (single VM only)
  -d, --distro         Specify OS distribution
                       (almalinux, rocky, oraclelinux, centos-stream, rhel, ubuntu-lts, opensuse-leap)
  -v, --version        Specify OS version number (e.g., 10, 9, 24.04, 15.6)
  -H, --hosts          Specify multiple hostnames (comma-separated)
  -h, --help           Show this help message

Arguments:
  hostname             Name of the VM to install via PXE boot (optional, will prompt if not given)

Examples:
  tux2lab vm install-pxe vm1                              # Install single VM (will prompt for distro/version)
  tux2lab vm install-pxe vm1 --console                    # Install and attach console
  tux2lab vm install-pxe vm1 --distro almalinux           # Install with AlmaLinux (will prompt for version)
  tux2lab vm install-pxe vm1 -d almalinux -v 9            # Install with AlmaLinux 9
  tux2lab vm install-pxe --hosts vm1,vm2,vm3              # Install multiple VMs
  tux2lab vm install-pxe -H vm1,vm2,vm3 -d ubuntu-lts -v 24.04  # Install multiple with Ubuntu 24.04
"
}

# Parse and validate arguments
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/parse-vm-command-args.sh
parse_vm_command_args "$@"

# Save command-line distro and version if specified
CMDLINE_OS_DISTRO="$OS_DISTRO"
CMDLINE_VERSION_TYPE="$VERSION_TYPE"

# Main installation loop
CURRENT_VM=0
FAILED_VMS=()
SUCCESSFUL_VMS=()

for qemu_kvm_hostname in "${HOSTNAMES[@]}"; do
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/show-multi-vm-progress.sh
    show_multi_vm_progress "$qemu_kvm_hostname"

    # Check if VM exists
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/check-vm-exists.sh
    if ! check_vm_exists "$qemu_kvm_hostname" "install"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    # Generate unique MAC address for the VM
    print_task "Generating MAC address for VM \"${qemu_kvm_hostname}\"..."
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/generate-mac-address.sh
    if ! GENERATED_MAC=$(generate_unique_mac "${qemu_kvm_hostname}"); then
        print_task_fail
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi
    print_task_done

    print_info "Creating PXE environment for '${qemu_kvm_hostname}' using ksmanager..."

    # Run ksmanager and extract VM details
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/run-ksmanager.sh
    ksmanager_opts="--qemu-kvm --mac ${GENERATED_MAC}"
    [[ -n "$CMDLINE_OS_DISTRO" ]] && ksmanager_opts="$ksmanager_opts --distro $CMDLINE_OS_DISTRO"
    [[ -n "$CMDLINE_VERSION_TYPE" ]] && ksmanager_opts="$ksmanager_opts --version $CMDLINE_VERSION_TYPE"
    cleanup_on_cancel=true  # Cleanup DNS/MAC if user cancels during install
    if ! run_ksmanager "${qemu_kvm_hostname}" "$ksmanager_opts" "$cleanup_on_cancel"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    # Create VM directory
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/create-vm-directory.sh
    if ! create_vm_directory "${qemu_kvm_hostname}"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    # Update /etc/hosts
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/update-etc-hosts.sh
    if ! update_etc_hosts "${qemu_kvm_hostname}" "${IPV4_ADDRESS}" "${IPV6_ADDRESS}"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    # Start installation process via PXE boot
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/start-vm-installation.sh
    if ! start_vm_installation "$qemu_kvm_hostname" "PXE boot"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    SUCCESSFUL_VMS+=("$qemu_kvm_hostname")

    # Show completion message for single VM
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/show-vm-completion-message.sh
    show_vm_completion_message "${qemu_kvm_hostname}" "${ATTACH_CONSOLE}" "${TOTAL_VMS}" "installation via PXE boot" "The VM will download OS files and install (this may take a few minutes)."
done

# Summary for multiple VMs
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/show-vm-operation-summary.sh
if ! show_vm_operation_summary "${TOTAL_VMS}" "SUCCESSFUL_VMS" "FAILED_VMS" "installation via PXE boot" "Installation via PXE boot may take a few minutes per VM."; then
    exit 1
fi


