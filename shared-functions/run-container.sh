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

    source /tux2lab/shared-functions/container-nfs.sh
    container_nfs_image_check "$image" || return 1
    container_nfs_host_preflight || return 1
    prepare_container_nfs "$data_dir" || return 1
    sudo mkdir -p "${data_dir}/logs"/{nginx,named,kea,radvd} "${data_dir}/nginx/stream.d"
    sudo chown named:named "${data_dir}/logs/named" 2>/dev/null || true
    sudo podman run -d \
        --name "${name}" \
        --hostname "${hostname}" \
        --uts=private \
        --network=host \
        --privileged \
        --stop-timeout=30 \
        --health-cmd='/bin/bash /usr/local/lib/tux2lab/nfs-service.sh check' \
        --health-interval=15s \
        --health-timeout=12s \
        --health-start-period=30s \
        --log-driver=k8s-file \
        --log-opt "path=${data_dir}/logs/tux2lab-engine.log" \
        --log-opt "max-size=10mb" \
        -v "${data_dir}/nfs/root:/export:ro" \
        -v "${data_dir}:/export${data_dir}:ro,rslave" \
        -v "${data_dir}/nfs/state:/var/lib/nfs" \
        -v "/tux2lab:/tux2lab:ro" \
        -v "${data_dir}/kea/leases:/var/lib/kea" \
        -v "${data_dir}/logs:/export${data_dir}/logs" \
        -v "${data_dir}/nginx/stream.d:/export${data_dir}/nginx/stream.d" \
        -e "TUX2LAB_BRIDGE_IP=${bridge_ip}" \
        -e "TUX2LAB_BRIDGE_IF=${bridge_if}" \
        -e "TUX2LAB_BRIDGE_IPV6=${bridge_ipv6}" \
        -e "TUX2LAB_DATA_DIR=${data_dir}" \
        "${image}" &>/dev/null || return 1
    wait_for_engine_nfs "$name"
}

replace_tux2lab_container() {
    local name="$1" image="$2" backup="${1}-rebuild-backup" exists
    source /tux2lab/shared-functions/container-nfs.sh
    container_nfs_image_check "$image" || return 1
    container_nfs_host_preflight || return 1
    prepare_container_nfs "$4" || return 1
    exists=$(container_nfs_exists "$name") || return 1
    if [[ "$exists" == false ]]; then
        run_tux2lab_container "$@"
        return $?
    fi
    require_container_nfs_engine "$name" || return 1
    exists=$(container_nfs_exists "$backup") || return 1
    if [[ "$exists" == true ]]; then
        printf 'Previous rebuild backup exists: %s. Resolve it before rebuilding.\n' "$backup" >&2
        return 1
    fi
    stop_engine_nfs "$name" || return 1
    sudo podman rename "$name" "$backup" || return 1
    if run_tux2lab_container "$@"; then
        sudo podman rm "$backup"
        return $?
    fi
    printf 'Replacement failed; restoring the previous engine.\n' >&2
    exists=$(container_nfs_exists "$name") || return 1
    if [[ "$exists" == true ]]; then
        stop_engine_nfs "$name" || return 1
        sudo podman rm "$name" || return 1
    fi
    sudo podman rename "$backup" "$name" || return 1
    sudo podman start "$name" || return 1
    wait_for_engine_nfs "$name" || return 1
    return 1
}
