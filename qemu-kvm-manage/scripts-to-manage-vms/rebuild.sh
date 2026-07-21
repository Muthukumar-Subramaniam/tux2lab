#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: rebuild.sh                                                               #
# Description: Recreate the tux2lab-engine container using local image and existing config#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# ====== HELP ======
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    print_cyan "USAGE:
    tux2lab rebuild [-y]

DESCRIPTION:
    Regenerates service configurations and recreates the tux2lab-engine
    container using the locally available image. Does NOT pull a new image.

    Use this when you want to quickly restart the container with updated
    configs without fetching anything from the registry. For pulling the
    latest image, use 'tux2lab sync' instead.

    This command does NOT touch:
      - Guest virtual machines
      - DNS zone files / host records
      - Lab configuration (lab_environment.json)
      - SSH keys, certificates, ISOs, golden images

OPTIONS:
    -y, --yes    Skip confirmation prompt
    -h, --help   Show this help message"
    exit 0
fi

skip_confirm=false
if [[ "${1:-}" == "-y" ]] || [[ "${1:-}" == "--yes" ]]; then
    skip_confirm=true
    shift
fi

if [[ $# -gt 0 ]]; then
    print_error "Unknown argument: $1"
    echo "Run 'tux2lab rebuild --help' for usage information."
    exit 1
fi

# ====== VALIDATE ======
if [[ ! -f "${LAB_ENV_JSON}" ]]; then
    print_error "Lab environment not found. Run 'tux2lab deploy' first."
    exit 1
fi

# ====== VERSION + INFO ======
local_version=$(jq -r '.version' /tux2lab/project_version.json)
print_info "Rebuilding tux2lab-engine v${local_version} from local image..."

# ====== CONFIRM ======
if [[ "${skip_confirm}" != "true" ]]; then
    print_warning "This will recreate the tux2lab-engine container and restart NFS."
    print_warning "Running VMs will NOT be affected."
    read -rp "Continue? (yes/no): " confirm
    if [[ "${confirm}" != "yes" ]]; then
        print_info "Aborted."
        exit 0
    fi
fi

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

# ====== STEP 2: Refresh DNS ======
print_task "Refreshing DNS configuration..."
if sudo podman ps --filter "name=${CONTAINER_NAME}" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
    sudo podman exec "${CONTAINER_NAME}" rndc reload &>/dev/null || true
fi
print_task_done

# ====== STEP 3: Recreate container from local image ======
print_task "Recreating tux2lab-engine container..."
recreate_start=$SECONDS

# Resolve container image from current container
container_image=$(sudo podman inspect "${CONTAINER_NAME}" --format '{{.ImageName}}' 2>/dev/null || echo "ghcr.io/muthukumar-subramaniam/tux2lab-engine:${local_version}")

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

# ====== STEP 4: Restart NFS on host ======
source /tux2lab/shared-functions/host-nfs.sh
restart_host_nfs

# ====== STEP 5: Ensure bridge firewall is open ======
source /tux2lab/shared-functions/bridge-firewall.sh
open_bridge_firewall "${lab_infra_bridge_interface}"

# ====== DONE ======
print_success "Rebuild complete. Container recreated from local image."
print_info "Run 'tux2lab health' to verify all services."
