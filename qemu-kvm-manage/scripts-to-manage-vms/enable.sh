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

readonly SERVICE_NAME="tux2lab-lab-infra.service"

if ! systemctl list-unit-files "$SERVICE_NAME" &>/dev/null; then
    print_error "$SERVICE_NAME is not installed."
    print_info "Run the deploy script to install it."
    exit 1
fi

# ====== Enable the service ======
if sudo systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    print_info "${SERVICE_NAME} auto-start is already enabled."
else
    print_task "Enabling ${SERVICE_NAME}..." nskip
    if sudo systemctl enable "$SERVICE_NAME" >/dev/null 2>&1; then
        print_task_done
    else
        print_task_fail
        print_error "Failed to enable ${SERVICE_NAME}."
        exit 1
    fi
fi

# ====== VM mode: also enable libvirtd + virsh autostart ======
if ! $lab_infra_server_mode_is_host; then
    # Enable libvirtd
    if sudo systemctl is-enabled --quiet libvirtd 2>/dev/null; then
        print_info "libvirtd auto-start is already enabled."
    else
        print_task "Enabling libvirtd..." nskip
        if sudo systemctl enable libvirtd >/dev/null 2>&1; then
            print_task_done
        else
            print_task_fail
            print_error "Failed to enable libvirtd."
            exit 1
        fi
    fi

    # Set virsh autostart on infra VM
    if sudo virsh dominfo "$lab_infra_server_hostname" 2>/dev/null | grep -q "Autostart:.*enable"; then
        print_info "VM autostart is already enabled for ${lab_infra_server_hostname}."
    else
        print_task "Enabling VM autostart for ${lab_infra_server_hostname}..." nskip
        if sudo virsh autostart "$lab_infra_server_hostname" >/dev/null 2>&1; then
            print_task_done
        else
            print_task_fail
            print_error "Failed to enable VM autostart."
            exit 1
        fi
    fi
fi

print_success "Lab infrastructure will auto-start on boot."
