#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: sync.sh                                                                  #
# Description: Sync project updates into the running tux2lab-engine container            #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# ====== HELP ======
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    print_cyan "USAGE:
    tux2lab sync

DESCRIPTION:
    Regenerates service configurations from lab_environment.json and
    restarts the tux2lab-engine container to pick up changes.

    Use this after pulling updates on the host (git pull) to apply
    the latest templates and configuration logic.

    The /tux2lab directory is already bind-mounted into the container
    as read-only, so code changes are visible immediately. This command
    regenerates derived configs (nginx, kea, DNS, etc.) and restarts
    services to apply them."
    exit 0
fi

if [[ $# -gt 0 ]]; then
    print_error "Unknown argument: $1"
    echo "Run 'tux2lab sync --help' for usage information."
    exit 1
fi

# ====== VALIDATE ======
if ! sudo podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
    print_error "Container '${CONTAINER_NAME}' does not exist."
    print_info "Run 'tux2lab deploy' first."
    exit 1
fi

# ====== VERSION INFO ======
local_version=$(jq -r '.version' /tux2lab/project_version.json)
print_info "Syncing tux2lab v${local_version} into running lab..."

# ====== STEP 1: Regenerate service configs ======
print_task "Regenerating service configurations..."
if [[ -x /tux2lab/setup/generate-service-configs.sh ]]; then
    bash /tux2lab/setup/generate-service-configs.sh
else
    print_task_fail
    print_error "generate-service-configs.sh not found."
    exit 1
fi

# ====== STEP 2: Regenerate DNS (if zone files need update) ======
print_task "Refreshing DNS configuration..."
if sudo podman ps --filter "name=${CONTAINER_NAME}" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
    sudo podman exec "${CONTAINER_NAME}" rndc reload &>/dev/null || true
fi
print_task_done

# ====== STEP 3: Restart container to pick up config changes ======
print_task "Restarting tux2lab-engine container..."
if sudo podman restart "${CONTAINER_NAME}" &>/dev/null; then
    sleep 2
    if sudo podman ps --filter "name=${CONTAINER_NAME}" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
        print_task_done
    else
        print_task_fail
        print_error "Container failed to restart. Check: sudo podman logs ${CONTAINER_NAME}"
        exit 1
    fi
else
    print_task_fail
    print_error "Failed to restart container."
    exit 1
fi

# ====== STEP 4: Health check ======
print_cyan "--------------------------------------------------------------"
if [[ -x /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/health.sh ]]; then
    /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/health.sh || true
fi

print_cyan "--------------------------------------------------------------"
print_success "Sync complete. Lab services updated to v${local_version}."
