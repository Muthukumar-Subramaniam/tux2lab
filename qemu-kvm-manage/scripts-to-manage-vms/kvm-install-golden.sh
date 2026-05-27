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
    print_cyan "Usage: tux2lab vm install-golden [OPTIONS]
Options:
  -H, --hosts          Specify hostname(s) (comma-separated for multiple VMs)
  -c, --console        Attach console during installation (single VM only)
  -d, --distro         Specify OS distribution
                       (almalinux, rocky, oraclelinux, centos-stream, rhel, ubuntu-lts, opensuse-leap)
  -v, --version        Specify OS version number (e.g., 10, 9, 26.04, 15.6)
  -h, --help           Show this help message

Examples:
  tux2lab vm install-golden -H vm1                              # Install single VM (will prompt for distro/version)
  tux2lab vm install-golden -H vm1 --console                    # Install and attach console
  tux2lab vm install-golden -H vm1 --distro almalinux           # Install with AlmaLinux (will prompt for version)
  tux2lab vm install-golden -H vm1 -d rocky -v 9                # Install with Rocky Linux 9
  tux2lab vm install-golden -H vm1,vm2,vm3                      # Install multiple VMs
  tux2lab vm install-golden -H vm1,vm2,vm3 -d ubuntu-lts -v 26.04  # Install multiple with Ubuntu 26.04
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

# If no distro/version specified on cmdline, select from available golden images
if [[ -z "$CMDLINE_OS_DISTRO" || -z "$CMDLINE_VERSION_TYPE" ]]; then
    source /tux2lab/ks-manage/distro-versions.conf
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/normalize-os-distro.sh

    # Discover available golden images
    declare -a GOLDEN_IMAGES_AVAILABLE=()
    if [[ -d /tux2lab-data/golden-images-disk-store ]]; then
        for f in /tux2lab-data/golden-images-disk-store/*.qcow2; do
            [[ -f "$f" ]] || continue
            base=$(basename "$f" .qcow2)
            # Strip the -golden-image.{domain} suffix
            prefix="${base%%-golden-image.*}"
            # Match against known distros to extract distro + version
            for known_distro in "${!DISTRO_DISPLAY_NAMES[@]}"; do
                if [[ "$prefix" == "${known_distro}-"* ]]; then
                    ver="${prefix#${known_distro}-}"
                    ver="${ver//-/.}"
                    GOLDEN_IMAGES_AVAILABLE+=("${known_distro}:${ver}")
                    break
                fi
            done
        done
    fi

    if [[ ${#GOLDEN_IMAGES_AVAILABLE[@]} -eq 0 ]]; then
        print_error "No golden images found in /tux2lab-data/golden-images-disk-store/"
        print_info "Build one first: tux2lab golden-image build"
        exit 1
    fi

    # If distro specified but not version, filter to that distro
    if [[ -n "$CMDLINE_OS_DISTRO" && -z "$CMDLINE_VERSION_TYPE" ]]; then
        normalize_os_distro "$CMDLINE_OS_DISTRO" || { print_error "Invalid distro: $CMDLINE_OS_DISTRO"; exit 1; }
        local_filter_distro="$NORMALIZED_OS_DISTRO"
        declare -a FILTERED_IMAGES=()
        for entry in "${GOLDEN_IMAGES_AVAILABLE[@]}"; do
            if [[ "${entry%%:*}" == "$local_filter_distro" ]]; then
                FILTERED_IMAGES+=("$entry")
            fi
        done
        if [[ ${#FILTERED_IMAGES[@]} -eq 0 ]]; then
            print_error "No golden images found for '${CMDLINE_OS_DISTRO}'"
            print_info "Available golden images:"
            for entry in "${GOLDEN_IMAGES_AVAILABLE[@]}"; do
                echo "  - ${entry%%:*} (${entry#*:})"
            done
            exit 1
        fi
        GOLDEN_IMAGES_AVAILABLE=("${FILTERED_IMAGES[@]}")
    fi

    # If only one golden image available, auto-select it
    if [[ ${#GOLDEN_IMAGES_AVAILABLE[@]} -eq 1 ]]; then
        CMDLINE_OS_DISTRO="${GOLDEN_IMAGES_AVAILABLE[0]%%:*}"
        CMDLINE_VERSION_TYPE="${GOLDEN_IMAGES_AVAILABLE[0]#*:}"
        print_info "Using golden image: ${DISTRO_DISPLAY_NAMES[$CMDLINE_OS_DISTRO]} ${CMDLINE_VERSION_TYPE}"
    else
        # Present interactive menu
        echo "Select golden image to deploy:"
        idx=1
        for entry in "${GOLDEN_IMAGES_AVAILABLE[@]}"; do
            gi_distro="${entry%%:*}"
            gi_version="${entry#*:}"
            printf "  %d)  %-30s (version %s)\n" "$idx" "${DISTRO_DISPLAY_NAMES[$gi_distro]}" "$gi_version"
            idx=$((idx + 1))
        done
        printf "  q)  Quit\n"

        while true; do
            read -rp "Enter option number: " gi_choice
            if [[ "$gi_choice" == "q" || "$gi_choice" == "Q" ]]; then
                print_info "Installation cancelled."
                exit 0
            fi
            if [[ "$gi_choice" =~ ^[0-9]+$ ]] && (( gi_choice >= 1 && gi_choice <= ${#GOLDEN_IMAGES_AVAILABLE[@]} )); then
                selected="${GOLDEN_IMAGES_AVAILABLE[$((gi_choice - 1))]}"
                CMDLINE_OS_DISTRO="${selected%%:*}"
                CMDLINE_VERSION_TYPE="${selected#*:}"
                break
            fi
            print_warning "Invalid choice. Please enter a number between 1 and ${#GOLDEN_IMAGES_AVAILABLE[@]}, or 'q' to quit."
        done
        print_info "Selected: ${DISTRO_DISPLAY_NAMES[$CMDLINE_OS_DISTRO]} ${CMDLINE_VERSION_TYPE}"
    fi
fi

# Verify golden image exists before any state-changing operations
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/normalize-os-distro.sh
normalize_os_distro "${CMDLINE_OS_DISTRO}" || { print_error "Invalid distro: $CMDLINE_OS_DISTRO"; exit 1; }
GOLDEN_IMAGE_CHECK_PATH="/tux2lab-data/golden-images-disk-store/${NORMALIZED_OS_DISTRO}-${CMDLINE_VERSION_TYPE//\./-}-golden-image.${lab_infra_domain_name}.qcow2"
if [[ ! -f "$GOLDEN_IMAGE_CHECK_PATH" ]]; then
    print_error "Golden image not found: ${NORMALIZED_OS_DISTRO}-${CMDLINE_VERSION_TYPE//\./-}-golden-image.${lab_infra_domain_name}.qcow2"
    print_info "Build one first: tux2lab golden-image build ${CMDLINE_OS_DISTRO} -v ${CMDLINE_VERSION_TYPE}"
    exit 1
fi

# Main installation loop
CURRENT_VM=0
FAILED_VMS=()
SUCCESSFUL_VMS=()

for qemu_kvm_hostname in "${HOSTNAMES[@]}"; do
    # Reset OS_DISTRO and VERSION_TYPE to command-line values for each VM
    OS_DISTRO="$CMDLINE_OS_DISTRO"
    VERSION_TYPE="$CMDLINE_VERSION_TYPE"
    
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/show-multi-vm-progress.sh
    show_multi_vm_progress "$qemu_kvm_hostname"

    # Check if VM exists
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/check-vm-exists.sh
    if ! check_vm_exists "$qemu_kvm_hostname" "install"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
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
    ksmanager_opts="--qemu-kvm --golden-image --mac ${GENERATED_MAC} --distro $OS_DISTRO --version $VERSION_TYPE"
    cleanup_on_cancel=true  # Cleanup DNS/MAC if user cancels during install
    if ! run_ksmanager "${qemu_kvm_hostname}" "$ksmanager_opts" "$cleanup_on_cancel"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    # Normalize OS distro name for golden image lookup
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/normalize-os-distro.sh
    if ! normalize_os_distro "${OS_DISTRO}"; then
        print_error "Failed to normalize OS distro for \"$qemu_kvm_hostname\"."
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi
    OS_DISTRO="$NORMALIZED_OS_DISTRO"

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
