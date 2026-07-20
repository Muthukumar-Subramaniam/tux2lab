#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: start.sh                                                             #
# Description: Start the tux2lab infrastructure and verify essential services            #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# ====== HELP ======
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_cyan "USAGE:
    tux2lab start

DESCRIPTION:
    Starts the tux2lab infrastructure: libvirtd, the virtual network,
    and the tux2lab-engine container.
    Verifies all essential services are reachable after startup."
    exit 0
fi

if [[ $# -gt 0 ]]; then
    print_error "Unknown argument: $1"
    echo "Run 'tux2lab start --help' for usage information."
    exit 1
fi

# ====== MAIN LOGIC ======
print_cyan "--------------------------------------------------------------"
print_cyan "tux2lab Infrastructure Startup"
print_cyan "  Container : ${CONTAINER_NAME}"
print_cyan "  Hostname  : ${lab_infra_server_hostname}"
print_cyan "--------------------------------------------------------------"

# ====== STEP 1: Start libvirtd ======
if sudo systemctl is-active --quiet libvirtd; then
    print_info "libvirtd is already running."
else
    print_task "Starting libvirtd..."
    if sudo systemctl start libvirtd; then
        print_task_done
    else
        print_task_fail
        print_error "Failed to start libvirtd."
        exit 1
    fi
fi

# ====== STEP 2: Wait for labbr0 ======
print_task "Waiting for ${lab_infra_bridge_interface} to be created..."
local_timeout=30
local_elapsed=0
net_start_attempted=false
until ip link show "${lab_infra_bridge_interface}" &>/dev/null; do
    if [[ $local_elapsed -ge $local_timeout ]]; then
        print_task_fail
        print_error "Timeout waiting for ${lab_infra_bridge_interface}."
        exit 1
    fi
    if [[ $local_elapsed -ge 5 ]] && ! $net_start_attempted; then
        sudo virsh net-start tux2lab &>/dev/null || true
        net_start_attempted=true
    fi
    sleep 1
    local_elapsed=$((local_elapsed + 1))
done
print_task_done

# ====== STEP 3: Start container ======
if sudo podman ps --filter "name=${CONTAINER_NAME}" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
    print_info "Container '${CONTAINER_NAME}' is already running."
else
    print_task "Starting tux2lab-engine container..."
    # Try starting existing stopped container first
    if sudo podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
        if sudo podman start "${CONTAINER_NAME}" &>/dev/null; then
            print_task_done
        else
            print_task_fail
            print_error "Failed to start container. Try: tux2lab rebuild"
            exit 1
        fi
    else
        # Container doesn't exist — need to run fresh (maybe after destroy)
        print_task_fail
        print_error "Container '${CONTAINER_NAME}' does not exist."
        print_info "Run 'tux2lab deploy' or 'tux2lab rebuild' to create it."
        exit 1
    fi

    # Wait for services to initialize
    sleep 2

    if ! sudo podman ps --filter "name=${CONTAINER_NAME}" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
        print_error "Container started but is no longer running."
        print_info "Check logs: sudo podman logs ${CONTAINER_NAME}"
        exit 1
    fi
fi

# ====== STEP 4: Configure DNS on host ======
print_task "Configuring DNS for ${lab_infra_bridge_interface}..."
if command -v resolvectl &>/dev/null; then
    sudo resolvectl dns "${lab_infra_bridge_interface}" "${lab_infra_server_ipv4_address}" "${lab_infra_server_ipv6_address}" 2>/dev/null || true
    sudo resolvectl domain "${lab_infra_bridge_interface}" "${lab_infra_domain_name}" 2>/dev/null || true
fi
print_task_done

# ====== STEP 5: Health check ======
print_cyan "--------------------------------------------------------------"
if [[ -x /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/health.sh ]]; then
    /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/health.sh || true
fi

print_cyan "--------------------------------------------------------------"
print_success "tux2lab infrastructure started."
print_info "Run 'tux2lab health' for full deep validation."
