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

readonly SERVICE_NAME="tux2lab-lab-infra.service"

if ! systemctl list-unit-files "$SERVICE_NAME" &>/dev/null; then
    print_error "$SERVICE_NAME is not installed."
    print_info "Run the Ansible playbook to install it."
    exit 1
fi

if ! sudo systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    print_info "Auto-start is already disabled."
else
    print_warning "Disabling auto-start means the lab infrastructure will NOT start on boot."
    print_warning "You will need to run 'tux2lab start' manually after every reboot."
    echo -n "Are you sure you want to proceed? (yes/no): "
    read -r confirmation
    if [[ "${confirmation}" != "yes" ]]; then
        print_info "Operation cancelled."
        exit 0
    fi
    print_task "Disabling lab infrastructure auto-start on boot..." nskip
    if sudo systemctl disable "$SERVICE_NAME" >/dev/null 2>&1; then
        print_task_done
        print_success "Lab infrastructure will no longer auto-start on boot."
    else
        print_task_fail
        print_error "Failed to disable $SERVICE_NAME."
        exit 1
    fi
fi
