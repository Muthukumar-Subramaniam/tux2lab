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
    print_cyan "Usage: tux2lab vm install-golden [OPTIONS] [hostname]
Options:
  -c, --console        Attach console during installation (single VM only)
  -d, --distro         Specify OS distribution
                       (almalinux, rocky, oraclelinux, centos-stream, rhel, ubuntu-lts, opensuse-leap)
  -v, --version        Specify OS version number (e.g., 10, 9, 24.04, 15.6)
  -H, --hosts          Specify multiple hostnames (comma-separated)
  -h, --help           Show this help message

Arguments:
  hostname             Name of the VM to install via golden image disk (optional, will prompt if not given)

Examples:
  tux2lab vm install-golden vm1                              # Install single VM (will prompt for distro/version)
  tux2lab vm install-golden vm1 --console                    # Install and attach console
  tux2lab vm install-golden vm1 --distro almalinux           # Install with AlmaLinux (will prompt for version)
  tux2lab vm install-golden vm1 -d rocky -v 9                # Install with Rocky Linux 9
  tux2lab vm install-golden --hosts vm1,vm2,vm3              # Install multiple VMs
  tux2lab vm install-golden -H vm1,vm2,vm3 -d ubuntu-lts -v 24.04  # Install multiple with Ubuntu 24.04
"
}

# Parse and validate arguments
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/parse-vm-command-args.sh
parse_vm_command_args "$@"

# Validate: if --version is specified without --distro, warn user
if [[ -n "$VERSION_TYPE" && -z "$OS_DISTRO" ]]; then
    print_warning "The --version option is specified without --distro."
    print_info "The version will be applied if OS is auto-detected from hostname pattern."
    print_info "If auto-detection fails, you'll be prompted to select OS distribution interactively."
    echo ""
fi

# Save command-line distro and version if specified
CMDLINE_OS_DISTRO="$OS_DISTRO"
CMDLINE_VERSION_TYPE="$VERSION_TYPE"

# Main installation loop
CURRENT_VM=0
FAILED_VMS=()
SUCCESSFUL_VMS=()

for qemu_kvm_hostname in "${HOSTNAMES[@]}"; do
    # Reset OS_DISTRO and VERSION_TYPE to command-line values for each VM
    OS_DISTRO="$CMDLINE_OS_DISTRO"
    VERSION_TYPE="$CMDLINE_VERSION_TYPE"
    NORMALIZED_DISTRO=""
    
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/show-multi-vm-progress.sh
    show_multi_vm_progress "$qemu_kvm_hostname"

    # Check if VM exists
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/check-vm-exists.sh
    if ! check_vm_exists "$qemu_kvm_hostname" "install"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    # Check if golden image exists for specified distro and version
    if [[ -n "$OS_DISTRO" && -n "$VERSION_TYPE" ]]; then
        # Normalize OS distro name first for golden image check
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/normalize-os-distro.sh
        if ! normalize_os_distro "${OS_DISTRO}"; then
            print_error "Invalid OS distribution: $OS_DISTRO"
            FAILED_VMS+=("$qemu_kvm_hostname")
            continue
        fi
        NORMALIZED_DISTRO="$NORMALIZED_OS_DISTRO"
        
        # Golden images follow pattern: {distro}-{version}-golden-image.{domain}.qcow2
        golden_image_pattern="${NORMALIZED_DISTRO}-${VERSION_TYPE//\./-}-golden-image.*.qcow2"
        if ! ls /tux2lab-data/golden-images-disk-store/${golden_image_pattern} &>/dev/null; then
            print_error "Golden image not found for '${OS_DISTRO}' (${VERSION_TYPE})"
            print_info "Available golden images:"
            if ls /tux2lab-data/golden-images-disk-store/*.qcow2 &>/dev/null; then
                for f in /tux2lab-data/golden-images-disk-store/*.qcow2; do
                    local base
                    base=$(basename "$f" .qcow2)
                    local prefix="${base%%-golden-image.*}"
                    for known_distro in "${!DISTRO_DISPLAY_NAMES[@]}"; do
                        if [[ "$prefix" == "${known_distro}-"* ]]; then
                            local ver="${prefix#${known_distro}-}"
                            echo "  - ${known_distro} (${ver//-/.})"
                            break
                        fi
                    done
                done | sort -u
            else
                echo "  (none)"
            fi
            print_info "Use 'tux2lab golden-image build --distro ${OS_DISTRO} --version ${VERSION_TYPE}' to create it"
            FAILED_VMS+=("$qemu_kvm_hostname")
            continue
        fi
    fi

    # Run ksmanager and extract VM details
    print_task "Generating MAC address for VM \"${qemu_kvm_hostname}\"..."
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/generate-mac-address.sh
    if ! GENERATED_MAC=$(generate_unique_mac "${qemu_kvm_hostname}"); then
        print_task_fail
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi
    print_task_done

    print_info "Creating first boot environment for '${qemu_kvm_hostname}' using ksmanager..."

    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/run-ksmanager.sh
    ksmanager_opts="--qemu-kvm --golden-image --mac ${GENERATED_MAC}"
    [[ -n "$OS_DISTRO" ]] && ksmanager_opts="$ksmanager_opts --distro $OS_DISTRO"
    [[ -n "$VERSION_TYPE" ]] && ksmanager_opts="$ksmanager_opts --version $VERSION_TYPE"
    cleanup_on_cancel=true  # Cleanup DNS/MAC if user cancels during install
    if ! run_ksmanager "${qemu_kvm_hostname}" "$ksmanager_opts" "$cleanup_on_cancel"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    # Use the normalized distro from earlier validation, not the extracted OS name from ksmanager
    if [[ -n "$NORMALIZED_DISTRO" ]]; then
        OS_DISTRO="$NORMALIZED_DISTRO"
    else
        # If no --distro was specified, normalize the extracted OS name from ksmanager output
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/normalize-os-distro.sh
        if ! normalize_os_distro "${OS_DISTRO}"; then
            print_error "Failed to normalize OS distro for \"$qemu_kvm_hostname\"."
            FAILED_VMS+=("$qemu_kvm_hostname")
            continue
        fi
        OS_DISTRO="$NORMALIZED_OS_DISTRO"
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

    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/validate-golden-image-exists.sh
    if ! validate_golden_image_exists "$qemu_kvm_hostname" "${OS_DISTRO}" "${VERSION_TYPE}"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/clone-golden-image-disk.sh
    if ! clone_golden_image_disk "$qemu_kvm_hostname" "${OS_DISTRO}" "${VERSION_TYPE}"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    # Start installation process via golden image disk
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/start-vm-installation.sh
    if ! start_vm_installation "$qemu_kvm_hostname" "golden image disk"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    SUCCESSFUL_VMS+=("$qemu_kvm_hostname")

    # Show completion message for single VM
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/show-vm-completion-message.sh
    show_vm_completion_message "${qemu_kvm_hostname}" "${ATTACH_CONSOLE}" "${TOTAL_VMS}" "installation via golden image disk" "The VM will reboot once or twice during installation (~1 minute)."
done

# Summary for multiple VMs
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/show-vm-operation-summary.sh
if ! show_vm_operation_summary "${TOTAL_VMS}" "SUCCESSFUL_VMS" "FAILED_VMS" "installation via golden image disk" "All VMs will reboot once or twice during installation (~1 minute each)."; then
    exit 1
fi
