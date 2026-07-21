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
    tux2lab sync [-y]

DESCRIPTION:
    Regenerates service configurations from lab_environment.json and
    recreates the tux2lab-engine container to pick up changes.

    Use this after pulling updates on the host (git pull) to apply
    the latest templates and configuration logic.

    The /tux2lab directory is already bind-mounted into the container
    as read-only, so code changes are visible immediately. This command
    regenerates derived configs (nginx, kea, DNS, etc.) and recreates
    services to apply them.

OPTIONS:
    -y, --yes    Skip confirmation prompt"
    exit 0
fi

skip_confirm=false
if [[ "${1:-}" == "-y" ]] || [[ "${1:-}" == "--yes" ]]; then
    skip_confirm=true
    shift
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

# ====== CONFIRM ======
if [[ "${skip_confirm}" != "true" ]]; then
    print_warning "This will destroy and recreate the tux2lab-engine container."
    read -rp "Proceed? [y/N]: " confirm
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
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

# ====== STEP 2: Regenerate DNS (if zone files need update) ======
print_task "Refreshing DNS configuration..."
if sudo podman ps --filter "name=${CONTAINER_NAME}" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
    sudo podman exec "${CONTAINER_NAME}" rndc reload &>/dev/null || true
fi
print_task_done

# ====== STEP 3: Pull latest container image ======
container_image_primary="ghcr.io/muthukumar-subramaniam/tux2lab-engine:${local_version}"
container_image_fallback="docker.io/musubram/tux2lab-engine:${local_version}"
container_image=""

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

# ====== STEP 4: Recreate container ======
print_task "Recreating tux2lab-engine container..."
recreate_start=$SECONDS

# Read required variables from lab environment
ipv4_address=$(jq -r '.network.ipv4.address' "${LAB_ENV_JSON}")
bridge_interface=$(jq -r '.network.bridge_interface' "${LAB_ENV_JSON}")
infra_fqdn=$(jq -r '.lab.engine_fqdn' "${LAB_ENV_JSON}")
data_dir="/tux2lab-data"

# Stop and remove existing container
sudo podman rm -f "${CONTAINER_NAME}" &>/dev/null || true

# Start fresh container
sudo mkdir -p "${data_dir}/log"
sudo podman run -d \
    --name "${CONTAINER_NAME}" \
    --hostname "${infra_fqdn}" \
    --uts=private \
    --network=host \
    --privileged \
    --log-driver=k8s-file \
    --log-opt "path=${data_dir}/log/tux2lab-engine.log" \
    --log-opt "max-size=10mb" \
    -v "${data_dir}:${data_dir}:ro" \
    -v "${data_dir}/kea/leases:/var/lib/kea" \
    -v "/tux2lab:${data_dir}/tux2lab:ro" \
    -v "/lib/modules:/lib/modules:ro" \
    -e "TUX2LAB_BRIDGE_IP=${ipv4_address}" \
    -e "TUX2LAB_BRIDGE_IF=${bridge_interface}" \
    "${container_image}" &>/dev/null

# Live timer while waiting for container to come up
recreate_elapsed=0
while true; do
    printf "\r${MAKE_IT_CYAN}[TASK] Recreating tux2lab-engine container [%dm %ds]...${RESET_COLOR}\033[K" $((recreate_elapsed/60)) $((recreate_elapsed%60))
    sleep 1
    recreate_elapsed=$((SECONDS - recreate_start))
    if sudo podman ps --filter "name=${CONTAINER_NAME}" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
        break
    fi
    if ((recreate_elapsed >= 30)); then
        printf "\r\033[K"
        print_task "Recreating tux2lab-engine container..."
        print_task_fail
        print_error "Container failed to start within 30s. Check: sudo podman logs ${CONTAINER_NAME}"
        exit 1
    fi
done

recreate_elapsed=$((SECONDS - recreate_start))
printf "\r\033[K"
printf "${MAKE_IT_CYAN}[TASK] Recreating tux2lab-engine container (%dm %ds)...${RESET_COLOR}" $((recreate_elapsed/60)) $((recreate_elapsed%60))
print_task_done

# ====== DONE ======
print_success "Sync complete. Lab services updated to v${local_version}."
print_info "Run 'tux2lab health' to verify all services."
