#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: enable.sh                                                                 #
# Description: Enable tux2lab lab infrastructure auto-start on boot                      #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# ====== HELP ======
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_cyan "USAGE:
    tux2lab enable

DESCRIPTION:
    Enables the lab infrastructure to auto-start on boot."
    exit 0
fi

if [[ $# -gt 0 ]]; then
    print_error "Unknown argument: $1"
    echo "Run 'tux2lab enable --help' for usage information."
    exit 1
fi

readonly SERVICE_NAME="tux2lab.service"

if ! systemctl list-unit-files "$SERVICE_NAME" &>/dev/null; then
    print_error "$SERVICE_NAME is not installed."
    print_info "Run the deploy script to install it."
    exit 1
fi

# ====== Enable the service ======
if sudo systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    print_info "${SERVICE_NAME} auto-start is already enabled."
else
    print_task "Enabling ${SERVICE_NAME}..."
    if sudo systemctl enable "$SERVICE_NAME" >/dev/null 2>&1; then
        print_task_done
    else
        print_task_fail
        print_error "Failed to enable ${SERVICE_NAME}."
        exit 1
    fi
fi

# ====== Enable libvirtd and sockets ======
if sudo systemctl is-enabled --quiet libvirtd 2>/dev/null; then
    print_info "libvirtd auto-start is already enabled."
else
    print_task "Enabling libvirtd and sockets..."
    if sudo systemctl enable libvirtd libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket >/dev/null 2>&1; then
        print_task_done
    else
        print_task_fail
        print_error "Failed to enable libvirtd."
        exit 1
    fi
fi

print_success "Lab infrastructure will auto-start on boot."
