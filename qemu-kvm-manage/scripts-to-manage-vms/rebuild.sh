#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: rebuild.sh                                                               #
# Description: Regenerate configs, pull image, and recreate tux2lab-engine container     #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# ====== HELP ======
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    print_cyan "USAGE:
    tux2lab rebuild [OPTIONS]

DESCRIPTION:
    Regenerates service configurations from lab_environment.json, syncs
    credentials to the host, pulls the latest container image, and recreates
    the tux2lab-engine container.

    Use after pulling project updates (git pull) or changing lab configs.

    This command does NOT touch:
      - Guest virtual machines
      - DNS host records
      - Lab configuration (lab_environment.json)
      - ISOs, golden images

OPTIONS:
    --pull-image     Pull latest container image from registry
    -y, --yes        Skip confirmation prompt
    -h, --help       Show this help message"
    exit 0
fi

skip_confirm=false
pull_image=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) skip_confirm=true; shift ;;
        --pull-image) pull_image=true; shift ;;
        *) print_error "Unknown argument: $1"; echo "Run 'tux2lab rebuild --help' for usage."; exit 1 ;;
    esac
done

# ====== VALIDATE ======
if [[ ! -f "${LAB_ENV_JSON}" ]]; then
    print_error "Lab environment not found. Run 'tux2lab deploy' first."
    exit 1
fi

# ====== VERSION + INFO ======
local_version=$(jq -r '.version' /tux2lab/project_version.json)
print_info "Rebuilding tux2lab v${local_version}..."

# Auto-detect version mismatch: if running container's image tag doesn't match project version, pull
if [[ "$pull_image" != "true" ]]; then
    current_image=$(sudo podman inspect "${CONTAINER_NAME}" --format '{{.ImageName}}' 2>/dev/null || echo "")
    if [[ -n "$current_image" ]] && [[ "$current_image" != *":${local_version}" ]]; then
        print_info "Version mismatch detected (container: ${current_image##*:}, project: ${local_version}). Will pull new image."
        pull_image=true
    fi
fi

# ====== CONFIRM ======
if [[ "${skip_confirm}" != "true" ]]; then
    if [[ "$pull_image" == "true" ]]; then
        print_warning "This will regenerate service configs, pull the latest image, recreate the container, and restart NFS."
    else
        print_warning "This will regenerate service configs, recreate the container from the local image, and restart NFS."
    fi
    print_warning "Running VMs will NOT be affected, but lab services (DNS, DHCP, NTP, NFS, HTTP, TFTP) will have a brief disruption."
    read -rp "Continue? (yes/no): " confirm
    if [[ "${confirm}" != "yes" ]]; then
        print_info "Aborted."
        exit 0
    fi
fi

# ====== STEP 0: Ensure infrastructure is up ======
if ! sudo systemctl is-active --quiet libvirtd; then
    print_task "Starting libvirtd..."
    if sudo systemctl start libvirtd; then
        print_task_done
    else
        print_task_fail
        print_error "Failed to start libvirtd."
        exit 1
    fi
fi

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

source /tux2lab/shared-functions/lablink0.sh
ensure_lablink0 "${lab_infra_bridge_interface}"

# ====== STEP 1: Regenerate service configs ======
print_task "Regenerating service configurations..."
echo ""
if [[ -x /tux2lab/setup/generate-service-configs.sh ]]; then
    bash /tux2lab/setup/generate-service-configs.sh
else
    print_task_fail
    print_error "generate-service-configs.sh not found."
    exit 1
fi

# ====== STEP 2: Sync lab credentials to KVM host ======
print_task "Syncing lab credentials to host..."
source /tux2lab/shared-functions/sync-credentials-to-host.sh
if sync_credentials_to_host; then
    print_task_done
else
    print_task_skip
fi

# ====== STEP 3: Refresh DNS ======
print_task "Refreshing DNS configuration..."
if sudo podman ps --filter "name=${CONTAINER_NAME}" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
    sudo podman exec "${CONTAINER_NAME}" rndc reload &>/dev/null || true
fi
print_task_done

# Ensure DHCP pool DNS records exist (idempotent)
pool_ipv4=$(jq -r '.network.ipv4.address' "${LAB_ENV_JSON}")
pool_domain=$(jq -r '.lab.domain' "${LAB_ENV_JSON}")
pool_last24=$(jq -r '.network.ipv4.last24_subnet' "${LAB_ENV_JSON}")
if ! dig @"${pool_ipv4}" +short +time=1 +tries=1 A "dhcp-lease156.${pool_domain}" 2>/dev/null | grep -q '^[0-9]'; then
    print_task "Creating DNS records for DHCP pool (156-254)..."
    dhcp_lease_file="$(mktemp /tmp/dhcp-lease-records.XXXXXXXXXX)"
    for octet in $(seq 156 254); do
        echo "dhcp-lease${octet} ${pool_last24}.${octet}" >> "$dhcp_lease_file"
    done
    sudo bash /tux2lab/named-manage/dnsbinder.sh -cify --inline "$dhcp_lease_file" &>/dev/null || true
    rm -f "$dhcp_lease_file"
    print_task_done
fi

# ====== STEP 4: Pull container image (if needed) ======
container_image_primary="ghcr.io/muthukumar-subramaniam/tux2lab-engine:${local_version}"
container_image_fallback="docker.io/musubram/tux2lab-engine:${local_version}"
container_image=""

if [[ "$pull_image" != "true" ]]; then
    # Use existing local image
    container_image=$(sudo podman inspect "${CONTAINER_NAME}" --format '{{.ImageName}}' 2>/dev/null || echo "${container_image_primary}")
else
    print_task "Pulling tux2lab-engine container image..."
    pull_start=$SECONDS

    sudo podman pull "${container_image_primary}" &>/dev/null &
    pull_pid=$!
    pull_elapsed=0
    while kill -0 "$pull_pid" 2>/dev/null; do
        printf "\r${MAKE_IT_CYAN}[TASK] Pulling tux2lab-engine container image [%dm %ds]...${RESET_COLOR}\033[K" $((pull_elapsed/60)) $((pull_elapsed%60))
        sleep 1
        pull_elapsed=$((SECONDS - pull_start))
    done

    if wait "$pull_pid"; then
        container_image="${container_image_primary}"
    else
        # Fallback to Docker Hub
        pull_start=$SECONDS
        sudo podman pull "${container_image_fallback}" &>/dev/null &
        pull_pid=$!
        pull_elapsed=0
        while kill -0 "$pull_pid" 2>/dev/null; do
            printf "\r${MAKE_IT_CYAN}[TASK] Pulling tux2lab-engine container image [%dm %ds]...${RESET_COLOR}\033[K" $((pull_elapsed/60)) $((pull_elapsed%60))
            sleep 1
            pull_elapsed=$((SECONDS - pull_start))
        done

        if wait "$pull_pid"; then
            container_image="${container_image_fallback}"
        else
            printf "\r\033[K"
            print_task "Pulling tux2lab-engine container image..."
            print_task_fail
            print_error "Failed to pull from both registries."
            exit 1
        fi
    fi

    pull_elapsed=$((SECONDS - pull_start))
    printf "\r\033[K"
    printf "${MAKE_IT_CYAN}[TASK] Pulling tux2lab-engine container image (%dm %ds)...${RESET_COLOR}" $((pull_elapsed/60)) $((pull_elapsed%60))
    print_task_done
fi

# ====== STEP 5: Recreate container ======
print_task "Recreating tux2lab-engine container..."
recreate_start=$SECONDS

# Read required variables from lab environment
ipv4_address=$(jq -r '.network.ipv4.address' "${LAB_ENV_JSON}")
bridge_interface=$(jq -r '.network.bridge_interface' "${LAB_ENV_JSON}")
infra_fqdn=$(jq -r '.lab.engine_fqdn' "${LAB_ENV_JSON}")
data_dir="/tux2lab-data"

# Destroy and recreate in background subshell
(
    sudo podman rm -f "${CONTAINER_NAME}" &>/dev/null || true
    source /tux2lab/shared-functions/run-container.sh
    run_tux2lab_container "${CONTAINER_NAME}" "${container_image}" "${infra_fqdn}" "${data_dir}" "${ipv4_address}" "${bridge_interface}"
) &
run_pid=$!

# Live timer
recreate_elapsed=0
while kill -0 "$run_pid" 2>/dev/null; do
    printf "\r${MAKE_IT_CYAN}[TASK] Recreating tux2lab-engine container [%dm %ds]...${RESET_COLOR}\033[K" $((recreate_elapsed/60)) $((recreate_elapsed%60))
    sleep 1
    recreate_elapsed=$((SECONDS - recreate_start))
done
wait "$run_pid" || true

# Verify container is up
sleep 1
recreate_elapsed=$((SECONDS - recreate_start))
if sudo podman ps --filter "name=${CONTAINER_NAME}" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
    printf "\r\033[K"
    printf "${MAKE_IT_CYAN}[TASK] Recreating tux2lab-engine container (%dm %ds)...${RESET_COLOR}" $((recreate_elapsed/60)) $((recreate_elapsed%60))
    print_task_done
else
    printf "\r\033[K"
    print_task "Recreating tux2lab-engine container..."
    print_task_fail
    print_error "Container failed to start. Check: sudo podman logs ${CONTAINER_NAME}"
    exit 1
fi

# ====== STEP 6: Mount ISOs ======
print_task "Mounting ISO images..."
if sudo /tux2lab/common-utils/tux2lab-iso-mounts.sh start >/dev/null 2>&1; then
    print_task_done
else
    print_task_fail
    print_warning "Some ISO mounts failed. Check /tux2lab-data/iso-mounts.conf"
fi

# ====== STEP 7: Restart NFS on host ======
source /tux2lab/shared-functions/host-nfs.sh
restart_host_nfs

# ====== STEP 8: Ensure bridge firewall is open ======
source /tux2lab/shared-functions/bridge-firewall.sh
open_bridge_firewall "${lab_infra_bridge_interface}"

# ====== STEP 9: Update /etc/hosts ======
print_task "Syncing /etc/hosts..."
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/update-etc-hosts.sh
add_etc_hosts_entry "${lab_infra_server_hostname}" "${lab_infra_server_ipv4_address}" "${lab_infra_server_ipv6_address}"
print_task_done

# ====== STEP 10: Configure DNS on host ======
print_task "Configuring DNS for ${lab_infra_bridge_interface}..."
if command -v resolvectl &>/dev/null; then
    sudo resolvectl dns "${lab_infra_bridge_interface}" "${lab_infra_server_ipv4_address}" "${lab_infra_server_ipv6_address}" 2>/dev/null || true
    sudo resolvectl domain "${lab_infra_bridge_interface}" "${lab_infra_domain_name}" 2>/dev/null || true
fi
print_task_done

# ====== STEP 11: Ensure boot service is enabled ======
if [[ -x /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/enable.sh ]]; then
    /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/enable.sh
fi

# ====== DONE ======
print_success "Rebuild complete. Lab services updated to v${local_version}."
print_info "Run 'tux2lab health' to verify all services."
