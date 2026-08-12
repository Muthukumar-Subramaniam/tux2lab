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
    Start the lab infrastructure. Ensures the bridge is up, opens firewall,
    starts the tux2lab-engine container, mounts ISOs, and configures DNS."
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

# ====== STEP 2: Ensure virtual network exists and is started ======
if ! sudo virsh net-info tux2lab &>/dev/null; then
    print_task "Defining tux2lab virtual network..."
    if sudo virsh net-define /tux2lab/qemu-kvm-manage/labbr0.xml &>/dev/null; then
        sudo virsh net-start tux2lab &>/dev/null || true
        sudo virsh net-autostart tux2lab &>/dev/null || true
        print_task_done
    else
        print_task_fail
        print_error "Failed to define virtual network."
        exit 1
    fi
elif ! sudo virsh net-list --name 2>/dev/null | grep -q '^tux2lab$'; then
    print_task "Starting tux2lab virtual network..."
    sudo virsh net-start tux2lab &>/dev/null || true
    print_task_done
fi

# ====== STEP 3: Wait for labbr0 ======
if ! ip link show "${lab_infra_bridge_interface}" &>/dev/null; then
    print_task "Waiting for ${lab_infra_bridge_interface}..."
    local_timeout=15
    local_elapsed=0
    until ip link show "${lab_infra_bridge_interface}" &>/dev/null; do
        if [[ $local_elapsed -ge $local_timeout ]]; then
            print_task_fail
            print_error "Timeout waiting for ${lab_infra_bridge_interface}."
            exit 1
        fi
        sleep 1
        local_elapsed=$((local_elapsed + 1))
    done
    print_task_done
fi

# ====== STEP 4: Ensure bridge is UP ======
source /tux2lab/shared-functions/lablink0.sh
ensure_lablink0 "${lab_infra_bridge_interface}"

# ====== STEP 4.1: Open bridge firewall (if host has restrictive iptables) ======
source /tux2lab/shared-functions/bridge-firewall.sh
open_bridge_firewall "${lab_infra_bridge_interface}"

# ====== STEP 5: Start container ======
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

# ====== STEP 6: Mount ISOs ======
print_task "Mounting ISO images..."
if sudo /tux2lab/common-utils/tux2lab-iso-mounts.sh start >/dev/null 2>&1; then
    print_task_done
else
    print_task_fail
    print_warning "Some ISO mounts failed. Check /tux2lab-data/iso-mounts.conf"
fi

# ====== STEP 7: Start NFS on host ======
source /tux2lab/shared-functions/host-nfs.sh
start_host_nfs "${lab_infra_server_ipv4_address}" "${lab_infra_server_ipv6_address}"

# ====== STEP 8: Configure DNS on host ======
print_task "Configuring DNS for ${lab_infra_bridge_interface}..."
if command -v resolvectl &>/dev/null; then
    sudo resolvectl dns "${lab_infra_bridge_interface}" "${lab_infra_server_ipv4_address}" "${lab_infra_server_ipv6_address}" 2>/dev/null || true
    sudo resolvectl domain "${lab_infra_bridge_interface}" "${lab_infra_domain_name}" 2>/dev/null || true
fi
print_task_done

# ====== STEP 9: Update /etc/hosts ======
print_task "Syncing /etc/hosts..."
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/update-etc-hosts.sh
add_etc_hosts_entry "${lab_infra_server_hostname}" "${lab_infra_server_ipv4_address}" "${lab_infra_server_ipv6_address}"
print_task_done

# ====== STEP 10: Restore load balancer IPs ======
if [[ -f /tux2lab-data/lb-hub/lb-registry.json ]]; then
    sudo /tux2lab/lb-manage/lbmanager.sh restore || true
fi

# ====== STEP 11: Restore IPv6 forwarding if previously enabled ======
if [[ -f /tux2lab-data/lab-config/ipv6-route-active ]]; then
    print_task "Restoring IPv6 forwarding..."
    /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/kvm-ipv6-route.sh auto &>/dev/null && print_task_done || print_task_skip
fi

# ====== STEP 12: Health check ======
if [[ -x /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/health.sh ]]; then
    /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/health.sh || true
fi

print_success "tux2lab infrastructure started."
