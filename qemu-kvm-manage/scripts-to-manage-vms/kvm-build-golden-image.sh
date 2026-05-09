#!/bin/bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/select-ovmf.sh

OS_DISTRO=""
VERSION_TYPE=""

# Function to show help
fn_show_help() {
    print_cyan "Usage: tux2lab golden-image create [OPTIONS]
Description:
    Creates a golden image disk by installing a VM via PXE boot.
    The VM will be automatically removed after the disk is created.

Options:
    -d, --distro         Specify OS distribution
                                            (almalinux, rocky, oraclelinux, centos-stream, rhel, ubuntu-lts, opensuse-leap)
    -v, --version        Specify OS version number (e.g., 10, 9, 24.04, 15.6)
    -h, --help           Show this help message

Examples:
    tux2lab golden-image create                             # Build golden image (will prompt for distro/version)
    tux2lab golden-image create -d almalinux                # Build AlmaLinux golden image (will prompt for version)
    tux2lab golden-image create -d rocky -v 9               # Build Rocky Linux 9 golden image
    tux2lab golden-image create -d ubuntu-lts -v 24.04      # Build Ubuntu LTS 24.04 golden image
"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            fn_show_help
            exit 0
            ;;
        -d|--distro)
            if [[ -z "$2" || "$2" == -* ]]; then
                print_error "--distro/-d requires a distribution name."
                fn_show_help
                exit 1
            fi
            OS_DISTRO="$2"
            shift 2
            ;;
        -v|--version)
            if [[ -z "$2" || "$2" == -* ]]; then
                print_error "--version/-v requires a version number (e.g., 10, 9, 24.04, 15.6)."
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
            print_error "'tux2lab golden-image create' does not accept positional arguments."
            fn_show_help
            exit 1
            ;;
    esac
done

# Validate: --version requires --distro for golden image creation
if [[ -n "$VERSION_TYPE" && -z "$OS_DISTRO" ]]; then
    print_error "The --version option requires --distro to be specified for golden image creation."
    fn_show_help
    exit 1
fi

# Default VERSION_TYPE if --distro is provided but --version is not
# (ksmanager will prompt for version interactively)

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

mkdir -p /tux2lab-data/golden-images-disk-store

# Golden image filename format: {hostname-fqdn}.qcow2
# Example: almalinux-golden-image-10.lab.local.qcow2
# The hostname from ksmanager already includes the version
golden_image_path="/tux2lab-data/golden-images-disk-store/${qemu_kvm_hostname}.qcow2"

# Check if golden image already exists
if [ -f "${golden_image_path}" ]; then
    print_warning "Golden image \"${qemu_kvm_hostname}\" already exists!"
    read -p "Do you want to delete and recreate it? (yes/no): " answer
    echo -ne "\033[1A\033[2K"  # Move up one line and clear it
    case "$answer" in
        yes|YES)
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
            if $lab_infra_server_mode_is_host; then
                /tux2lab/ks-manage/ksmanager.sh "$qemu_kvm_hostname" --remove-host || true
            else
                ssh -o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${lab_infra_admin_username}@${lab_infra_server_hostname}" "/tux2lab/ks-manage/ksmanager.sh $qemu_kvm_hostname --remove-host" || true
            fi
            exit 0
            ;;
    esac
fi

print_info "Starting installation of VM \"${qemu_kvm_hostname}\" to create golden image disk..."

# Set custom paths for golden image creation
DISK_PATH="${golden_image_path}"
NVRAM_PATH="/tux2lab-data/golden-images-disk-store/${qemu_kvm_hostname}_VARS.fd"
VENDORED_VIRT_MANAGER_DIR="/tux2lab/vendor/virt-manager"

# Run virt-install with console attachment (don't use shared function to avoid complexity)
if ! sudo PYTHONPATH="${VENDORED_VIRT_MANAGER_DIR}" python3 "${VENDORED_VIRT_MANAGER_DIR}/virt-install" \
    --name ${qemu_kvm_hostname} \
    --features acpi=on,apic=on \
    --memory 2048 \
    --vcpus 2 \
    --disk path=${DISK_PATH},size=20,bus=virtio,boot.order=1 \
    --os-variant almalinux9 \
    --network network=default,model=virtio,mac=${GENERATED_MAC},boot.order=2 \
    --graphics none \
    --console pty,target_type=serial \
    --machine q35 \
    --watchdog none \
    --cpu host-model \
    --boot loader=${OVMF_CODE_PATH},\
nvram.template=${OVMF_VARS_PATH},\
nvram=${NVRAM_PATH},\
menu=on; then
    print_error "VM installation failed."
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

# Clean up ksmanager databases (DNS, MAC cache, kickstart, iPXE, DHCP)
print_info "Cleaning up ksmanager databases for temporary VM..."
if $lab_infra_server_mode_is_host; then
    if ! /tux2lab/ks-manage/ksmanager.sh "$qemu_kvm_hostname" --remove-host; then
        print_warning "Could not clean up ksmanager databases."
    fi
else
    if ! ssh -o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${lab_infra_admin_username}@${lab_infra_server_hostname}" "/tux2lab/ks-manage/ksmanager.sh $qemu_kvm_hostname --remove-host"; then
        print_warning "Could not clean up ksmanager databases."
    fi
fi

print_success "Golden image disk created successfully: ${golden_image_path}"
