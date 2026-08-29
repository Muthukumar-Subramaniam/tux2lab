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
SUPPORTS_STACK="yes"
SUPPORTS_MIN_RESOURCES="pxe"
STACK_MODE="dual"
STACK_MODE_EXPLICIT=false
VM_CPUS="2"
VM_CPUS_SPECIFIED=false
VM_MEMORY="2"
VM_MEMORY_SPECIFIED=false
VM_DISK_SIZE="30"
VM_DISK_SIZE_SPECIFIED=false

# Function to show help
fn_show_help() {
    print_cyan "USAGE:
    tux2lab vm install --via-pxe [OPTIONS]

DESCRIPTION:
    Deploy new VM(s) via PXE network boot (full OS installation). Supports
    per-VM stack mode selection (dual/IPv4/IPv6), custom resource specs
    (CPU, memory, disk), multi-VM batch deployment, and console attachment
    for monitoring the installation process.

OPTIONS:
    -H <hostnames>      Hostname(s) to deploy (comma-separated)
    -d <distro>         OS distribution
    -v <version>        OS version
    -c, --console       Attach to serial console during install (single VM only)
    --ipv4-only         Create IPv4-only VM
    --ipv6-only         Create IPv6-only VM
    --dual-stack        Create dual-stack VM (default if neither is specified)
    --cpu <n>           vCPUs (power of 2, min: 2, default: 2)
    --memory <n>        RAM in GiB (power of 2, min: 2, default: 2)
    --root-disk-size <n> Disk in GiB (multiple of 5, default: 30)
    -h, --help          Show this help message

EXAMPLES:
    tux2lab vm install --via-pxe -H testvm1
    tux2lab vm install --via-pxe -H testvm1 -d almalinux -v 10
    tux2lab vm install --via-pxe -H testvm1 --console
    tux2lab vm install --via-pxe -H testvm1 --ipv4-only -d almalinux -v 10
    tux2lab vm install --via-pxe -H testvm1 --cpu 4 --memory 8 --root-disk-size 50
    tux2lab vm install --via-pxe -H testvm1,testvm2,testvm3
    tux2lab vm install --via-pxe -H testvm1 -d ubuntu-lts -v 24.04 --console
"
}

# Parse and validate arguments
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/parse-vm-command-args.sh
parse_vm_command_args "$@"

# Save command-line distro and version if specified
CMDLINE_OS_DISTRO="$OS_DISTRO"
CMDLINE_VERSION_TYPE="$VERSION_TYPE"

# Validate distro and version locally before any work
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/validate-distro-version.sh
validate_distro_version "$CMDLINE_OS_DISTRO" "$CMDLINE_VERSION_TYPE"

# Interactive distro/version selection (resolved once, used for all VMs)
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/select-distro-version.sh
select_distro_version "$CMDLINE_OS_DISTRO" "$CMDLINE_VERSION_TYPE"
CMDLINE_OS_DISTRO="$SELECTED_DISTRO"
CMDLINE_VERSION_TYPE="$SELECTED_VERSION"

# Auto-setup distro if not prepared for PXE boot
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/auto-setup-distro.sh
auto_setup_distro "$CMDLINE_OS_DISTRO" "$CMDLINE_VERSION_TYPE"

# Main installation loop
CURRENT_VM=0
FAILED_VMS=()
SUCCESSFUL_VMS=()

source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/vm-hostname-lock.sh
trap 'fn_release_vm_hostname_lock' EXIT

for qemu_kvm_hostname in "${HOSTNAMES[@]}"; do
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/show-multi-vm-progress.sh
    show_multi_vm_progress "$qemu_kvm_hostname"

    # Check if VM exists
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/check-vm-exists.sh
    if ! check_vm_exists "$qemu_kvm_hostname" "install"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    # Acquire per-hostname lock to prevent duplicate operations
    if ! fn_acquire_vm_hostname_lock "$qemu_kvm_hostname"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    # Generate unique MAC address for the VM
    print_task "Generating MAC address..."
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/generate-mac-address.sh
    if ! GENERATED_MAC=$(generate_unique_mac "${qemu_kvm_hostname}"); then
        print_task_fail
        fn_release_vm_hostname_lock
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi
    print_task_done

    print_info "Creating PXE environment via ksmanager..."

    # Run ksmanager and extract VM details
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/run-ksmanager.sh
    ksmanager_opts="--qemu-kvm --mac ${GENERATED_MAC} --distro $CMDLINE_OS_DISTRO --version $CMDLINE_VERSION_TYPE"
    if [[ "${STACK_MODE_EXPLICIT}" == "true" ]] || [[ "${STACK_MODE}" != "dual" ]]; then
        [[ "${STACK_MODE}" == "dual" ]] && ksmanager_opts="${ksmanager_opts} --dual-stack" || ksmanager_opts="${ksmanager_opts} --${STACK_MODE}-only"
    fi
    cleanup_on_cancel=true  # Cleanup DNS/MAC if user cancels during install
    if ! run_ksmanager "${qemu_kvm_hostname}" "$ksmanager_opts" "$cleanup_on_cancel"; then
        fn_release_vm_hostname_lock
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    # Create VM directory
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/create-vm-directory.sh
    if ! create_vm_directory "${qemu_kvm_hostname}"; then
        fn_release_vm_hostname_lock
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    # Update /etc/hosts (skip temp IPv4 for --ipv6-only VMs)
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/update-etc-hosts.sh
    print_task "Updating /etc/hosts..."
    _etc_hosts_ipv4="${IPV4_ADDRESS}"
    [[ "${STACK_MODE}" == "ipv6" ]] && _etc_hosts_ipv4=""
    if ! add_etc_hosts_entry "${qemu_kvm_hostname}" "${_etc_hosts_ipv4}" "${IPV6_ADDRESS}"; then
        print_task_fail
        fn_release_vm_hostname_lock
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi
    print_task_done

    # Start installation process via PXE boot
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/start-vm-installation.sh
    if ! start_vm_installation "$qemu_kvm_hostname" "PXE boot"; then
        fn_release_vm_hostname_lock
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    fn_release_vm_hostname_lock
    SUCCESSFUL_VMS+=("$qemu_kvm_hostname")

    print_info "VM specs: ${VM_CPUS} vCPUs, ${VM_MEMORY} GiB RAM, ${VM_DISK_SIZE} GiB disk"

    # Show completion message for single VM
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/show-vm-completion-message.sh
    show_vm_completion_message "${qemu_kvm_hostname}" "${ATTACH_CONSOLE}" "${TOTAL_VMS}" "Installation" "Installation via PXE boot may take a few minutes per VM."
done

# Summary for multiple VMs
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/show-vm-operation-summary.sh
if ! show_vm_operation_summary "${TOTAL_VMS}" "SUCCESSFUL_VMS" "FAILED_VMS" "installation via PXE boot" "Installation via PXE boot may take a few minutes per VM."; then
    exit 1
fi


