#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/select-ovmf.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/validate-distro-version.sh

OS_DISTRO=""
VERSION_TYPE=""

# Function to show help
fn_show_help() {
    print_cyan "Usage: tux2lab golden-image build [distro] [OPTIONS]
Description:
    Creates a golden image disk by installing a VM via PXE boot.
    The VM will be automatically removed after the disk is created.

Options:
    -v, --version        Specify OS version number (e.g., 10, 9, 26.04, 15.6)
    -h, --help           Show this help message

Examples:
    tux2lab golden-image build                             # Build golden image (will prompt for distro/version)
    tux2lab golden-image build almalinux                   # Build AlmaLinux golden image (will prompt for version)
    tux2lab golden-image build rocky --version 9           # Build Rocky Linux 9 golden image
    tux2lab golden-image build ubuntu-lts -v 26.04         # Build Ubuntu LTS 26.04 golden image
"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            fn_show_help
            exit 0
            ;;
        -v|--version)
            if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                print_error "--version/-v requires a version number (e.g., 10, 9, 26.04, 15.6)."
                fn_show_help
                exit 1
            fi
            VERSION_TYPE="$2"
            shift 2
            ;;
        -*)
            print_error "No such option: $1"
            fn_show_help
            exit 1
            ;;
        *)
            if [[ -z "$OS_DISTRO" ]]; then
                OS_DISTRO="$1"
            else
                print_error "Unexpected argument: $1"
                fn_show_help
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate: --version requires --distro for golden image creation
if [[ -n "$VERSION_TYPE" && -z "$OS_DISTRO" ]]; then
    print_error "The --version option requires --distro to be specified for golden image creation."
    fn_show_help
    exit 1
fi

# Validate distro name and version locally before generating MAC or invoking ksmanager
validate_distro_version "$OS_DISTRO" "$VERSION_TYPE"

# Generate unique MAC address for the VM
print_task "Generating MAC address for golden image VM..."
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/generate-mac-address.sh
if ! GENERATED_MAC=$(generate_unique_mac "golden-image"); then
    print_task_fail
    exit 1
fi
print_task_done

print_info "Invoking ksmanager to create PXE environment for golden image..."

# Run ksmanager for golden image creation
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/run-ksmanager.sh
ksmanager_opts="--qemu-kvm --create-golden-image --mac ${GENERATED_MAC}"
[[ -n "$OS_DISTRO" ]] && ksmanager_opts="$ksmanager_opts --distro $OS_DISTRO"
[[ -n "$VERSION_TYPE" ]] && ksmanager_opts="$ksmanager_opts --version $VERSION_TYPE"
if ! run_ksmanager "" "$ksmanager_opts"; then
    print_error "Something went wrong while executing ksmanager!"
    print_info "Please check your Lab Infra Server for the root cause."
    exit 1
fi

qemu_kvm_hostname="$EXTRACTED_HOSTNAME"

# Acquire per-golden-image singleton lock (fail-fast if another build is running)
# This works for both interactive mode (distro resolved by ksmanager) and CLI mode.
GOLDEN_BUILD_LOCK_DIR="/tux2lab-data/.golden-image-build-${qemu_kvm_hostname}.lock"

fn_release_golden_build_lock() {
    rm -f "${GOLDEN_BUILD_LOCK_DIR}/pid" 2>/dev/null
    rmdir "${GOLDEN_BUILD_LOCK_DIR}" 2>/dev/null || true
}

if ! mkdir "${GOLDEN_BUILD_LOCK_DIR}" 2>/dev/null; then
    if [[ -f "${GOLDEN_BUILD_LOCK_DIR}/pid" ]]; then
        existing_pid=$(cat "${GOLDEN_BUILD_LOCK_DIR}/pid" 2>/dev/null)
        if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
            print_error "Another golden-image build for '${qemu_kvm_hostname}' is already in progress (PID ${existing_pid})."
            exit 1
        fi
        # Stale lock from a dead process — reclaim it
        rm -f "${GOLDEN_BUILD_LOCK_DIR}/pid"
        rmdir "${GOLDEN_BUILD_LOCK_DIR}" 2>/dev/null || true
    fi
    if ! mkdir "${GOLDEN_BUILD_LOCK_DIR}" 2>/dev/null; then
        print_error "Cannot acquire golden-image build lock. Please retry."
        exit 1
    fi
fi

printf '%s\n' "$$" > "${GOLDEN_BUILD_LOCK_DIR}/pid"
trap 'fn_release_golden_build_lock' EXIT
trap 'fn_release_golden_build_lock; trap - INT; kill -s INT $$' INT
trap 'fn_release_golden_build_lock; trap - TERM; kill -s TERM $$' TERM

mkdir -p /tux2lab-data/golden-images-disk-store

# Golden image filename format: {hostname-fqdn}.qcow2
# Example: almalinux-golden-image-10.tux2lab.internal.qcow2
# The hostname from ksmanager already includes the version
golden_image_path="/tux2lab-data/golden-images-disk-store/${qemu_kvm_hostname}.qcow2"

# Check if golden image already exists
if [[ -f "${golden_image_path}" ]]; then
    print_warning "Golden image \"${qemu_kvm_hostname}\" already exists!"
    read -rp "Do you want to delete and recreate it? (YES/NO): " answer
    echo -ne "\033[1A\033[2K"  # Move up one line and clear it
    case "$answer" in
        YES)
            print_task "Deleting existing golden image..." nskip
            if sudo rm -f "${golden_image_path}"; then
                print_task_done
            else
                print_task_fail
                print_error "Could not delete existing golden image."
                exit 1
            fi
            ;;
        * )
            print_info "Keeping existing golden image \"${qemu_kvm_hostname}\". Cleaning up ksmanager databases..."
            /tux2lab/ks-manage/ksmanager.sh "$qemu_kvm_hostname" --remove-host || true
            exit 0
            ;;
    esac
fi

print_info "Starting installation of VM \"${qemu_kvm_hostname}\" to create golden image disk..."

# Azure Linux needs more RAM for golden image build (live squashfs loaded into RAM)
golden_build_memory=2048
if [[ "${OS_DISTRO}" == "azurelinux" ]]; then
    golden_build_memory=4096
fi

# Set custom paths for golden image creation
DISK_PATH="${golden_image_path}"
NVRAM_PATH="/tux2lab-data/golden-images-disk-store/${qemu_kvm_hostname}_VARS.fd"
VENDORED_VIRT_MANAGER_DIR="/tux2lab/vendor/virt-manager"

# Run virt-install with console attachment (don't use shared function to avoid complexity)
if ! sudo PYTHONPATH="${VENDORED_VIRT_MANAGER_DIR}" python3 "${VENDORED_VIRT_MANAGER_DIR}/virt-install" \
    --name "${qemu_kvm_hostname}" \
    --features acpi=on,apic=on \
    --memory ${golden_build_memory} \
    --vcpus 2 \
    --disk "path=${DISK_PATH},size=20,bus=virtio,boot.order=1" \
    --os-variant almalinux9 \
    --network "network=tux2lab,model=virtio,mac=${GENERATED_MAC},boot.order=2" \
    --graphics none \
    --console pty,target_type=serial \
    --machine q35 \
    --watchdog none \
    --cpu host-model \
    --boot "loader=${OVMF_CODE_PATH},nvram.template=${OVMF_VARS_PATH}${OVMF_NVRAM_TEMPLATE_FORMAT_OPT},nvram=${NVRAM_PATH},menu=on" \
    --xml ./os/nvram/@format=raw; then
    print_error "VM installation failed. Cleaning up..."
    sudo virsh destroy "$qemu_kvm_hostname" 2>/dev/null || true
    sudo virsh undefine "$qemu_kvm_hostname" --nvram 2>/dev/null || true
    sudo rm -f "${golden_image_path}" "${NVRAM_PATH}"
    /tux2lab/ks-manage/ksmanager.sh "$qemu_kvm_hostname" --remove-host 2>/dev/null || true
    exit 1
fi

print_info "VM installation of \"${qemu_kvm_hostname}\" completed."

# Cleanup: destroy and undefine the temporary VM
print_info "Cleaning up temporary VM \"${qemu_kvm_hostname}\"..."

# Destroy VM if running
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/poweroff-vm.sh
POWEROFF_VM_CONTEXT="Stopping temporary VM" poweroff_vm "$qemu_kvm_hostname"

# Undefine VM
if error_msg=$(sudo virsh undefine "$qemu_kvm_hostname" --nvram 2>&1); then
    print_info "Temporary VM \"${qemu_kvm_hostname}\" cleaned up successfully."
else
    print_warning "Could not cleanup temporary VM \"${qemu_kvm_hostname}\": $error_msg"
fi

# Remove auto-created storage pool (virt-install artifact, not needed)
if sudo virsh pool-info golden-images-disk-store &>/dev/null; then
    sudo virsh pool-destroy golden-images-disk-store &>/dev/null || true
    sudo virsh pool-undefine golden-images-disk-store &>/dev/null || true
fi

# Clean up ksmanager databases (DNS, MAC cache, kickstart, iPXE, DHCP)
print_info "Cleaning up ksmanager databases for temporary VM..."
if ! /tux2lab/ks-manage/ksmanager.sh "$qemu_kvm_hostname" --remove-host; then
    print_warning "Could not clean up ksmanager databases."
fi

print_success "Golden image disk created successfully: ${golden_image_path}"
