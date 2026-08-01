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
    local bridge_ipv6
    bridge_ipv6=$(jq -r '.network.ipv6.address' "${data_dir}/lab-config/lab_environment.json")

    sudo mkdir -p "${data_dir}/log" "${data_dir}/logs"/{nginx,named,kea,chrony,tftpd,radvd} "${data_dir}/nginx/stream.d"
    sudo chown named:named "${data_dir}/logs/named" 2>/dev/null || true
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
        -v "/tux2lab:/tux2lab:ro" \
        -v "${data_dir}/kea/leases:/var/lib/kea" \
        -v "${data_dir}/logs:${data_dir}/logs" \
        -v "${data_dir}/nginx/stream.d:${data_dir}/nginx/stream.d" \
        -e "TUX2LAB_BRIDGE_IP=${bridge_ip}" \
        -e "TUX2LAB_BRIDGE_IF=${bridge_if}" \
        -e "TUX2LAB_BRIDGE_IPV6=${bridge_ipv6}" \
        "${image}" &>/dev/null
}
