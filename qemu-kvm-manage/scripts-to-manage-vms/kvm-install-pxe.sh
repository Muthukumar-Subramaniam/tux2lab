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
    print_cyan "Usage: tux2lab vm install-pxe [OPTIONS]
Options:
  -H, --hosts          Specify hostname(s) (comma-separated for multiple VMs)
  -c, --console        Attach console during installation (single VM only)
  -d, --distro         Specify OS distribution
                       (almalinux, rocky, oraclelinux, centos-stream, rhel, ubuntu-lts, debian, opensuse-leap)
  -v, --version        Specify OS version number (e.g., 10, 9, 26.04, 16.0)
  --ipv4-only          Create IPv4-only VM (no AAAA record, no IPv6 config)
  --ipv6-only          Create IPv6-only VM (AAAA only; temp IPv4 for PXE boot)
  --dual-stack         Force dual-stack (override auto-detected single-stack on reimage)
  --cpu <n>             Number of vCPUs (default: 2)
  --memory <n>        RAM in GiB (power of 2, default: 2)
  --root-disk-size <GiB>  Root disk size in GiB (default: 30)
  -h, --help           Show this help message

Examples:
  tux2lab vm install-pxe -H vm1                              # Install single VM (will prompt for distro/version)
  tux2lab vm install-pxe -H vm1 --console                    # Install and attach console
  tux2lab vm install-pxe -H vm1 --distro almalinux           # Install with AlmaLinux (will prompt for version)
  tux2lab vm install-pxe -H vm1 -d almalinux -v 9            # Install with AlmaLinux 9
  tux2lab vm install-pxe -H vm1,vm2,vm3                      # Install multiple VMs
  tux2lab vm install-pxe -H vm1 -d almalinux -v 10 --ipv4-only  # IPv4-only VM
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
    print_task "Generating MAC address for VM \"${qemu_kvm_hostname}\"..."
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/generate-mac-address.sh
    if ! GENERATED_MAC=$(generate_unique_mac "${qemu_kvm_hostname}"); then
        print_task_fail
        fn_release_vm_hostname_lock
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi
    print_task_done

    print_info "Creating PXE environment for '${qemu_kvm_hostname}' using ksmanager..."

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
    print_task "Updating /etc/hosts for ${qemu_kvm_hostname}..."
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

    # Clean up temp PXE bootstrap record for --ipv6-only
    if [[ -n "${PXE_BOOTSTRAP_HOSTNAME:-}" ]]; then
        print_task "Removing temporary PXE bootstrap record '${PXE_BOOTSTRAP_HOSTNAME}'..."
        sudo /tux2lab/named-manage/dnsbinder.sh -dy "${PXE_BOOTSTRAP_HOSTNAME}" &>/dev/null && print_task_done || print_task_fail
    fi

    # Show completion message for single VM
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/show-vm-completion-message.sh
    show_vm_completion_message "${qemu_kvm_hostname}" "${ATTACH_CONSOLE}" "${TOTAL_VMS}" "installation via PXE boot" "Installation via PXE boot may take a few minutes per VM."
done

# Summary for multiple VMs
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/show-vm-operation-summary.sh
if ! show_vm_operation_summary "${TOTAL_VMS}" "SUCCESSFUL_VMS" "FAILED_VMS" "installation via PXE boot" "Installation via PXE boot may take a few minutes per VM."; then
    exit 1
fi


