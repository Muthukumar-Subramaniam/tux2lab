#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh
DIR_PATH_SCRIPTS_TO_MANAGE_VMS='/tux2lab/qemu-kvm-manage/scripts-to-manage-vms'

ATTACH_CONSOLE="no"
CLEAN_INSTALL="no"
FORCE_REIMAGE="false"
OS_DISTRO=""
VERSION_TYPE=""
HOSTNAMES=()
SUPPORTS_CLEAN_INSTALL="yes"
SUPPORTS_FORCE="yes"
SUPPORTS_DISTRO="yes"
SUPPORTS_VERSION="yes"

# Function to show help
fn_show_help() {
    print_cyan "Usage: tux2lab vm reimage-pxe [OPTIONS]
Options:
  -H, --hosts          Specify hostname(s) (comma-separated for multiple VMs)
  -c, --console        Attach console during reimage (single VM only)
  -C, --clean-install  Destroy VM and reinstall with default specs (2 vCPUs, 2 GiB RAM, 20 GiB disk)
  -d, --distro         Specify OS distribution
                       (almalinux, rocky, oraclelinux, centos-stream, rhel, ubuntu-lts, opensuse-leap)
  -v, --version        Specify OS version number (e.g., 10, 9, 26.04, 15.6)
  -f, --force          Skip confirmation prompt
  -h, --help           Show this help message

Examples:
  tux2lab vm reimage-pxe -H vm1                                   # Reimage single VM
  tux2lab vm reimage-pxe -H vm1 --console                         # Reimage and attach console
  tux2lab vm reimage-pxe -H vm1 --clean-install                   # Reimage with default specs
  tux2lab vm reimage-pxe -H vm1 --distro almalinux                # Reimage with AlmaLinux (will prompt for version)
  tux2lab vm reimage-pxe -H vm1 -d rocky -v 9                     # Reimage with Rocky Linux 9
  tux2lab vm reimage-pxe -f -H vm1                                # Reimage without confirmation
  tux2lab vm reimage-pxe -H vm1,vm2,vm3 -d ubuntu-lts -v 26.04   # Reimage multiple with Ubuntu 26.04
  tux2lab vm reimage-pxe -H vm1,vm2,vm3 --clean-install           # Reimage multiple with defaults
"
}

# Parse and validate arguments
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/parse-vm-command-args.sh
parse_vm_command_args "$@"

# Save command-line distro and version if specified
CMDLINE_OS_DISTRO="$OS_DISTRO"
CMDLINE_VERSION_TYPE="$VERSION_TYPE"

# Main reimage loop
CURRENT_VM=0
FAILED_VMS=()
SUCCESSFUL_VMS=()
SKIPPED_VMS=()

for qemu_kvm_hostname in "${HOSTNAMES[@]}"; do
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/show-multi-vm-progress.sh
    show_multi_vm_progress "$qemu_kvm_hostname"

    # Check if VM exists
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/check-vm-exists.sh
    if ! check_vm_exists "$qemu_kvm_hostname" "reimage"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    # Prevent reimaging of lab infra server
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/check-lab-infra-protection.sh
    if ! check_lab_infra_protection "$qemu_kvm_hostname"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi
    
    # Confirm reimage operation
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/confirm-reimage-operation.sh
    if ! confirm_reimage_operation "$qemu_kvm_hostname" "PXE boot"; then
        SKIPPED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    # PXE installation requires minimum 2 GiB memory and 2 vCPUs
    if [[ "$CLEAN_INSTALL" != "yes" ]]; then
        current_mem_kib=$(sudo virsh dominfo "$qemu_kvm_hostname" | awk '/^Max memory/ {print $3}')
        current_mem_gib=$(( current_mem_kib / 1024 / 1024 ))
        current_vcpus=$(sudo virsh dominfo "$qemu_kvm_hostname" | awk '/^CPU\(s\)/ {print $2}')
        if (( current_mem_gib < 2 || current_vcpus < 2 )); then
            print_error "VM '${qemu_kvm_hostname}' has ${current_vcpus} vCPU(s) and ${current_mem_gib} GiB memory — minimum 2 vCPUs and 2 GiB required for PXE installation."
            print_info "Run 'tux2lab vm resize cpu 2 memory 2 -H ${qemu_kvm_hostname}' first, or use --clean-install to reset to defaults."
            FAILED_VMS+=("$qemu_kvm_hostname")
            continue
        fi
    fi

    # If --distro not specified, look up previous provisioning data
    if [[ -z "$CMDLINE_OS_DISTRO" ]]; then
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/lookup-previous-provision.sh
        if lookup_previous_provision "$qemu_kvm_hostname"; then
            REIMAGE_OS_DISTRO="$PREVIOUS_OS_DISTRO"
            REIMAGE_VERSION_TYPE="$PREVIOUS_VERSION"
            print_info "Auto-detected previous OS: ${REIMAGE_OS_DISTRO} ${REIMAGE_VERSION_TYPE}"
        else
            REIMAGE_OS_DISTRO=""
            REIMAGE_VERSION_TYPE=""
        fi
    else
        REIMAGE_OS_DISTRO="$CMDLINE_OS_DISTRO"
        REIMAGE_VERSION_TYPE="$CMDLINE_VERSION_TYPE"
    fi

    # Handle MAC address based on operation type
    if [[ "$CLEAN_INSTALL" == "yes" ]]; then
        # For clean install, generate new MAC (VM will be destroyed and recreated)
        print_task "Generating MAC address for VM \"${qemu_kvm_hostname}\"..."
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/generate-mac-address.sh
        if ! GENERATED_MAC=$(generate_unique_mac "${qemu_kvm_hostname}"); then
            print_task_fail
            FAILED_VMS+=("$qemu_kvm_hostname")
            continue
        fi
        print_task_done
    else
        # For regular reimage, preserve existing MAC
        print_task "Getting MAC address from existing VM \"${qemu_kvm_hostname}\"..."
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/get-vm-mac-address.sh
        if ! GENERATED_MAC=$(get_vm_mac_address "${qemu_kvm_hostname}"); then
            print_task_fail
            print_error "Failed to get MAC address from VM \"${qemu_kvm_hostname}\"."
            FAILED_VMS+=("$qemu_kvm_hostname")
            continue
        fi
        print_task_done
    fi

    print_info "Creating PXE environment for '${qemu_kvm_hostname}' using ksmanager..."

    # Run ksmanager and extract VM details
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/run-ksmanager.sh
    ksmanager_opts="--qemu-kvm --mac ${GENERATED_MAC}"
    [[ -n "$REIMAGE_OS_DISTRO" ]] && ksmanager_opts="$ksmanager_opts --distro $REIMAGE_OS_DISTRO"
    [[ -n "$REIMAGE_VERSION_TYPE" ]] && ksmanager_opts="$ksmanager_opts --version $REIMAGE_VERSION_TYPE"
    if ! run_ksmanager "${qemu_kvm_hostname}" "$ksmanager_opts"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    # Update /etc/hosts
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/update-etc-hosts.sh
    if ! update_etc_hosts "${qemu_kvm_hostname}" "${IPV4_ADDRESS}" "${IPV6_ADDRESS}"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    # Shut down VM if running
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/poweroff-vm.sh
    if ! POWEROFF_VM_CONTEXT="Powering off before reimaging" POWEROFF_VM_STRICT=true poweroff_vm "$qemu_kvm_hostname"; then
        FAILED_VMS+=("$qemu_kvm_hostname")
        continue
    fi

    # If --clean-install is specified, destroy and reinstall VM with default specs
    if [[ "$CLEAN_INSTALL" == "yes" ]]; then
        print_info "Using --clean-install: VM will be destroyed and reinstalled with default specs (2 vCPUs, 2 GiB RAM, 20 GiB disk)."
        
        # Destroy VM and delete directory
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/destroy-vm-for-clean-install.sh
        if ! destroy_vm_for_clean_install "$qemu_kvm_hostname"; then
            FAILED_VMS+=("$qemu_kvm_hostname")
            continue
        fi
        
        # Create fresh VM directory
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/create-vm-directory.sh
        if ! create_vm_directory "${qemu_kvm_hostname}"; then
            FAILED_VMS+=("$qemu_kvm_hostname")
            continue
        fi
        
        # Create new disk with default size
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/create-vm-disk.sh
        if ! create_vm_disk "${qemu_kvm_hostname}" 20; then
            FAILED_VMS+=("$qemu_kvm_hostname")
            continue
        fi
        
        # Install VM with default specs using default-vm-install function
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/select-ovmf.sh
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/start-vm-installation.sh
        if ! start_vm_installation "$qemu_kvm_hostname" "PXE boot with default specs"; then
            FAILED_VMS+=("$qemu_kvm_hostname")
            continue
        fi
    else
        # Default path: preserve disk size
        print_info "Reimaging VM \"$qemu_kvm_hostname\" by replacing its qcow2 disk with a new one..."
        
        vm_qcow2_disk_path="/tux2lab-data/vms/${qemu_kvm_hostname}/${qemu_kvm_hostname}.qcow2"
        
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/get-current-disk-size.sh
        get_current_disk_size "$qemu_kvm_hostname"
        current_disk_gib="${CURRENT_DISK_SIZE:-20}"
        
        # Delete existing qcow2 disk and recreate with appropriate size
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/delete-vm-disk.sh
        delete_vm_disk "$qemu_kvm_hostname"
        
        if ! sudo qemu-img create -f qcow2 "${vm_qcow2_disk_path}" "20G" >/dev/null 2>&1; then
            print_error "Failed to create qcow2 disk for \"$qemu_kvm_hostname\"."
            FAILED_VMS+=("$qemu_kvm_hostname")
            continue
        fi
        
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/resize-disk-if-larger.sh
        resize_disk_if_larger "$qemu_kvm_hostname" "$current_disk_gib" "20"
        
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/report-retained-resources.sh
        report_retained_resources "$qemu_kvm_hostname"
        
        # Start reimaging process
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/start-vm-for-reimage.sh
        if ! start_vm_for_reimage "$qemu_kvm_hostname" "reimaging via PXE boot"; then
            FAILED_VMS+=("$qemu_kvm_hostname")
            continue
        fi
    fi

    SUCCESSFUL_VMS+=("$qemu_kvm_hostname")

    # Show completion message for single VM
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/show-vm-completion-message.sh
    show_vm_completion_message "${qemu_kvm_hostname}" "${ATTACH_CONSOLE}" "${TOTAL_VMS}" "reimaging via PXE boot" "Reimaging via PXE boot takes a few minutes."
done

# Summary for multiple VMs
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/show-vm-operation-summary.sh
if ! show_vm_operation_summary "${TOTAL_VMS}" "SUCCESSFUL_VMS" "FAILED_VMS" "reimaging via PXE boot" "Reimaging via PXE boot takes a few minutes per VM." "SKIPPED_VMS"; then
    exit 1
fi
