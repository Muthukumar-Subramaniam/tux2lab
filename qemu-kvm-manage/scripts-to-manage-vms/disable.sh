#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: disable.sh                                                                #
# Description: Disable tux2lab lab infrastructure auto-start on boot                     #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# ====== HELP ======
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_cyan "USAGE:
    tux2lab disable

DESCRIPTION:
    Disables the lab infrastructure from auto-starting on boot.
    Requires confirmation before proceeding."
    exit 0
fi

if [[ $# -gt 0 ]]; then
    print_error "Unknown argument: $1"
    echo "Run 'tux2lab disable --help' for usage information."
    exit 1
fi

readonly SERVICE_NAME="tux2lab-lab-infra.service"

if ! systemctl list-unit-files "$SERVICE_NAME" &>/dev/null; then
    print_error "$SERVICE_NAME is not installed."
    print_info "Run the deploy script to install it."
    exit 1
fi

if ! sudo systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    print_info "Auto-start is already disabled."
    exit 0
fi

print_warning "Disabling auto-start means the lab infrastructure will NOT start on boot."
print_warning "You will need to run 'tux2lab start' manually after every reboot."
echo -n "Type CONFIRM to proceed: "
read -r confirmation
if [[ "${confirmation}" != "CONFIRM" ]]; then
    print_info "Operation cancelled."
    exit 0
fi

# ====== Disable the service ======
print_task "Disabling ${SERVICE_NAME}..."
if sudo systemctl disable "$SERVICE_NAME" >/dev/null 2>&1; then
    print_task_done
else
    print_task_fail
    print_error "Failed to disable ${SERVICE_NAME}."
    exit 1
fi

# ====== Disable libvirtd ======
if sudo systemctl is-enabled --quiet libvirtd 2>/dev/null; then
    print_task "Disabling libvirtd..."
    if sudo systemctl disable libvirtd >/dev/null 2>&1; then
        print_task_done
    else
        print_task_fail
        print_error "Failed to disable libvirtd."
        exit 1
    fi
else
    print_info "libvirtd auto-start is already disabled."
fi

print_success "Lab infrastructure will no longer auto-start on boot."
