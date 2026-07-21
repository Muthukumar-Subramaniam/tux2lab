#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Shared function to create and run the tux2lab-engine container.                        #
# Single source of truth for container configuration (mounts, env, flags).               #
#----------------------------------------------------------------------------------------#

# Create and run tux2lab-engine container
# Usage: run_tux2lab_container <container_name> <container_image> <hostname> <data_dir> <bridge_ip> <bridge_if>
run_tux2lab_container() {
    local name="$1"
    local image="$2"
    local hostname="$3"
    local data_dir="$4"
    local bridge_ip="$5"
    local bridge_if="$6"

    sudo mkdir -p "${data_dir}/log"
    sudo podman run -d \
        --name "${name}" \
        --hostname "${hostname}" \
        --uts=private \
        --network=host \
        --privileged \
        --log-driver=k8s-file \
        --log-opt "path=${data_dir}/log/tux2lab-engine.log" \
        --log-opt "max-size=10mb" \
        -v "${data_dir}:${data_dir}:ro,rslave" \
        -v "${data_dir}/kea/leases:/var/lib/kea" \
        -e "TUX2LAB_BRIDGE_IP=${bridge_ip}" \
        -e "TUX2LAB_BRIDGE_IF=${bridge_if}" \
        "${image}" &>/dev/null
}
