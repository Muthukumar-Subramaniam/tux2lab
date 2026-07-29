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

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            exec tux2lab golden-image --help
            ;;
        -v|--version)
            if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                print_error "--version/-v requires a version number (e.g., 10, 9, 26.04, 16.0)."
                exit 1
            fi
            VERSION_TYPE="$2"
            shift 2
            ;;
        -*)
            print_error "No such option: $1"
            print_info "Run 'tux2lab golden-image --help' for usage."
            exit 1
            ;;
        *)
            if [[ -z "$OS_DISTRO" ]]; then
                OS_DISTRO="$1"
            elif [[ -z "$VERSION_TYPE" ]]; then
                VERSION_TYPE="$1"
            else
                print_error "Unexpected argument: $1"
                print_info "Run 'tux2lab golden-image --help' for usage."
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate: --version requires --distro for golden image creation
if [[ -n "$VERSION_TYPE" && -z "$OS_DISTRO" ]]; then
    print_error "The --version option requires a distro to be specified."
    print_info "Run 'tux2lab golden-image --help' for usage."
    exit 1
fi

# Validate distro name and version locally before generating MAC or invoking ksmanager
validate_distro_version "$OS_DISTRO" "$VERSION_TYPE"

# Interactive distro/version selection (if not provided on command line)
# Selection happens HERE so ksmanager is always called non-interactively.
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/select-distro-version.sh
select_distro_version "$OS_DISTRO" "$VERSION_TYPE"
OS_DISTRO="$SELECTED_DISTRO"
VERSION_TYPE="$SELECTED_VERSION"

# Pre-flight: verify internet connectivity (golden image builds require package downloads)
print_task "Checking internet connectivity..."
if ! ping -4 -c1 -W3 8.8.8.8 &>/dev/null; then
    print_task_fail
    print_error "No internet connectivity. Golden image builds require internet access for package downloads."
    exit 1
fi
print_task_done

# Auto-setup distro if not prepared for PXE boot
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/auto-setup-distro.sh
auto_setup_distro "$OS_DISTRO" "$VERSION_TYPE"

# Sync tux2lab-sync to served location (ensures golden image gets the latest version)
cp -f /tux2lab/ksmanager/addons-for-kickstarts/tux2lab-sync /tux2lab-data/common-utils/tux2lab-sync

# Check if golden image already exists (early check before ksmanager work)
if [[ -n "$OS_DISTRO" && -n "$VERSION_TYPE" ]]; then
    _version_dashed="${VERSION_TYPE//./-}"
    _predicted_hostname="${OS_DISTRO}-${_version_dashed}-golden-image.${lab_infra_domain_name}"
    _predicted_path="/tux2lab-data/golden-images-disk-store/${_predicted_hostname}.qcow2"
    if [[ -f "$_predicted_path" ]]; then
        print_warning "Golden image \"${_predicted_hostname}\" already exists!"
        read -rp "Do you want to delete and recreate it? (YES/NO): " answer
        echo -ne "\033[1A\033[2K"
        case "$answer" in
            YES)
                print_task "Deleting existing golden image..." nskip
                sudo rm -f "$_predicted_path"
                sudo rm -f "/tux2lab-data/golden-images-disk-store/${_predicted_hostname}_VARS.fd"
                print_task_done
                ;;
            *)
                print_info "Keeping existing golden image. Aborted."
                exit 0
                ;;
        esac
    fi
fi

# Generate unique MAC address for the VM
print_task "Generating MAC address for golden image VM..."
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/generate-mac-address.sh
if ! GENERATED_MAC=$(generate_unique_mac "golden-image"); then
    print_task_fail
    exit 1
fi
print_task_done

print_info "Creating PXE environment for golden image..."

# Run ksmanager for golden image creation (always non-interactive — distro/version resolved above)
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/run-ksmanager.sh
ksmanager_opts="--qemu-kvm --create-golden-image --mac ${GENERATED_MAC} --distro $OS_DISTRO --version $VERSION_TYPE"
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

fn_cleanup_on_interrupt() {
    echo ""
    print_error "Build interrupted. Cleaning up..."
    print_task "Stopping and removing temporary VM..."
    sudo virsh destroy "$qemu_kvm_hostname" >/dev/null 2>&1 || true
    sudo virsh undefine "$qemu_kvm_hostname" --nvram >/dev/null 2>&1 || true
    print_task_done
    if [[ -n "${golden_image_path:-}" ]]; then
        print_task "Removing golden image disk..."
        sudo rm -f "${golden_image_path}" 2>/dev/null || true
        print_task_done
    fi
    [[ -n "${NVRAM_PATH:-}" ]] && sudo rm -f "${NVRAM_PATH}" 2>/dev/null || true
    if sudo virsh pool-info golden-images-disk-store >/dev/null 2>&1; then
        sudo virsh pool-destroy golden-images-disk-store >/dev/null 2>&1 || true
        sudo virsh pool-undefine golden-images-disk-store >/dev/null 2>&1 || true
    fi
    /tux2lab/ksmanager/ksmanager.sh "$qemu_kvm_hostname" --remove-host 2>/dev/null || true
    fn_release_golden_build_lock
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
trap 'fn_cleanup_on_interrupt; trap - INT; kill -s INT $$' INT
trap 'fn_cleanup_on_interrupt; trap - TERM; kill -s TERM $$' TERM

mkdir -p /tux2lab-data/golden-images-disk-store

# Golden image filename format: {hostname-fqdn}.qcow2
# Example: almalinux-golden-image-10.tux2lab.internal.qcow2
# The hostname from ksmanager already includes the version
golden_image_path="/tux2lab-data/golden-images-disk-store/${qemu_kvm_hostname}.qcow2"

print_info "Starting installation of VM \"${qemu_kvm_hostname}\" to create golden image disk..."

# Golden image builds use higher specs (SELinux policy compilation, dracut, depmod are heavy)
golden_build_memory=4096
golden_build_vcpus=4

# Set custom paths for golden image creation
DISK_PATH="${golden_image_path}"
NVRAM_PATH="/tux2lab-data/golden-images-disk-store/${qemu_kvm_hostname}_VARS.fd"
VENDORED_VIRT_MANAGER_DIR="/tux2lab/vendor/virt-manager"

# Run virt-install in background (no console attachment)
# --events on_reboot=destroy: when installer reboots, libvirt destroys the domain and
# virt-install exits cleanly. This avoids hangs where QEMU fails to process the reset
# signal (common with Ubuntu's squashfs/loop-device-heavy installer).
if ! sudo PYTHONPATH="${VENDORED_VIRT_MANAGER_DIR}" python3 "${VENDORED_VIRT_MANAGER_DIR}/virt-install" \
    --name "${qemu_kvm_hostname}" \
    --features acpi=on,apic=on \
    --memory ${golden_build_memory} \
    --vcpus ${golden_build_vcpus} \
    --disk "path=${DISK_PATH},size=30,bus=virtio,boot.order=1" \
    --os-variant almalinux9 \
    --network "network=tux2lab,model=virtio,mac=${GENERATED_MAC},boot.order=2" \
    --graphics none \
    --console pty,target_type=serial \
    --machine q35 \
    --watchdog none \
    --cpu host-model \
    --events on_reboot=destroy \
    --noautoconsole \
    --boot "loader=${OVMF_CODE_PATH},nvram.template=${OVMF_VARS_PATH}${OVMF_NVRAM_TEMPLATE_FORMAT_OPT},nvram=${NVRAM_PATH},menu=on" \
    --xml ./os/nvram/@format=raw >/dev/null; then
    print_error "Failed to create VM. Cleaning up..."
    sudo virsh destroy "$qemu_kvm_hostname" 2>/dev/null || true
    sudo virsh undefine "$qemu_kvm_hostname" --nvram 2>/dev/null || true
    sudo rm -f "${golden_image_path}" "${NVRAM_PATH}"
    /tux2lab/ksmanager/ksmanager.sh "$qemu_kvm_hostname" --remove-host 2>/dev/null || true
    exit 1
fi

# --- Stage 1: OS Installation ---
print_cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_cyan "Preparing Golden Image with OS Installation via PXE Network Boot"
print_cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_yellow "  To monitor: tux2lab vm console -H ${qemu_kvm_hostname}"
print_yellow "  This may take several minutes depending on the distribution and internet speed."

# Poll until VM is destroyed (on_reboot=destroy triggers after installer reboots)
stage_start=$SECONDS
network_detected=false
while sudo virsh domstate "$qemu_kvm_hostname" &>/dev/null && \
      [[ "$(sudo virsh domstate "$qemu_kvm_hostname" 2>/dev/null)" != "shut off" ]]; do
    elapsed=$(( SECONDS - stage_start ))
    minutes=$(( elapsed / 60 ))
    seconds=$(( elapsed % 60 ))

    if ! $network_detected; then
        if ping -4 -c1 -W1 "$qemu_kvm_hostname" &>/dev/null || ping -6 -c1 -W1 "$qemu_kvm_hostname" &>/dev/null; then
            network_detected=true
        fi
    fi

    if $network_detected; then
        printf "\r  OS installation in progress... (elapsed: %dm %02ds)\033[K" "$minutes" "$seconds"
    else
        printf "\r  Booting and loading installer... (elapsed: %dm %02ds)\033[K" "$minutes" "$seconds"
    fi

    sleep 4

    # Timeout: 30 minutes
    if [[ $elapsed -ge 1800 ]]; then
        echo ""
        print_error "Stage 1 timed out after 30 minutes. Cleaning up..."
        sudo virsh destroy "$qemu_kvm_hostname" 2>/dev/null || true
        sudo virsh undefine "$qemu_kvm_hostname" --nvram 2>/dev/null || true
        sudo rm -f "${golden_image_path}" "${NVRAM_PATH}"
        /tux2lab/ksmanager/ksmanager.sh "$qemu_kvm_hostname" --remove-host 2>/dev/null || true
        exit 1
    fi
done

elapsed=$(( SECONDS - stage_start ))
minutes=$(( elapsed / 60 ))
seconds=$(( elapsed % 60 ))
printf "\r\033[K"
print_green "  ✓ Golden image preparation completed (${minutes}m ${seconds}s)"

# Cleanup: remove provisioning configs and temporary VM definition
print_task "Cleaning up provisioning environment..."
/tux2lab/ksmanager/ksmanager.sh "$qemu_kvm_hostname" --remove-host >/dev/null 2>&1 || true
print_task_done
print_task "Cleaning up temporary VM..."
sudo virsh undefine "$qemu_kvm_hostname" --nvram >/dev/null 2>&1 || true
if sudo virsh pool-info golden-images-disk-store >/dev/null 2>&1; then
    sudo virsh pool-destroy golden-images-disk-store >/dev/null 2>&1 || true
    sudo virsh pool-undefine golden-images-disk-store >/dev/null 2>&1 || true
fi
print_task_done

print_success "Golden image created successfully for ${OS_DISTRO} ${VERSION_TYPE}"
