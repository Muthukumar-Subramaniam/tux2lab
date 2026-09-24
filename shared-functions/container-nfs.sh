#!/usr/bin/env bash

container_nfs_image_check() {
    local image="$1" label
    label=$(sudo podman image inspect "$image" --format '{{index .Labels "io.tux2lab.nfs"}}') || return 1
    if [[ "$label" != container-v1 ]]; then
        printf 'This image does not support container NFS. Build the migration image and set TUX2LAB_ENGINE_IMAGE.\n' >&2
        return 1
    fi
}

container_nfs_host_preflight() {
    local service
    for service in nfs-server nfs-kernel-server nfs-mountd rpc-mountd rpcbind rpc-statd nfs-idmapd; do
        if sudo systemctl is-active --quiet "$service.service"; then
            printf 'Host %s is active. Run the documented NFS migration before starting this engine.\n' "$service" >&2
            return 1
        fi
    done
    if sudo systemctl is-active --quiet rpcbind.socket; then
        printf 'Host rpcbind.socket is active; container NFS cannot own RPC.\n' >&2
        return 1
    fi
    if findmnt -rn -t nfs,nfs4 | grep -q .; then
        printf 'Host NFS client mounts exist; lockd ownership requires a dedicated host.\n' >&2
        return 1
    fi
    sudo modprobe nfsd || return 1
    sudo modprobe lockd
}

require_container_nfs_engine() {
    local label
    label=$(sudo podman inspect "${1:-tux2lab-engine}" --format '{{index .Config.Labels "io.tux2lab.nfs"}}') || return 1
    if [[ "$label" != container-v1 ]]; then
        printf 'The existing engine uses host NFS. Follow docs/nfs-container-migration.md before using this branch lifecycle.\n' >&2
        return 1
    fi
}

prepare_container_nfs() {
    local data_dir="$1" filesystem
    filesystem=$(findmnt -n -o FSTYPE -T "$data_dir") || return 1
    case "$filesystem" in
        ext4|xfs|btrfs) ;;
        *) printf 'Unsupported NFS backing filesystem: %s\n' "$filesystem" >&2; return 1 ;;
    esac
    [[ -s "$data_dir/nfs/container.exports" && -s "$data_dir/nfs/container.conf" ]] || {
        printf 'Container NFS configuration missing. Regenerate service configuration first.\n' >&2
        return 1
    }
    sudo mkdir -p "$data_dir/nfs/root$data_dir" "$data_dir/nfs/state" || return 1
    sudo chmod 700 "$data_dir/nfs/state"
}

check_engine_nfs() {
    sudo podman exec "${1:-tux2lab-engine}" /bin/bash /usr/local/lib/tux2lab/nfs-service.sh check
}

wait_for_engine_nfs() {
    local name="${1:-tux2lab-engine}" attempt
    for ((attempt = 0; attempt < 30; attempt++)); do
        if check_engine_nfs "$name" >/dev/null 2>&1; then
            return 0
        fi
        [[ "$(sudo podman inspect "$name" --format '{{.State.Running}}')" == true ]] || break
        sleep 1
    done
    printf 'Container NFS did not become ready. Inspect: sudo podman logs %s\n' "$name" >&2
    return 1
}

flush_engine_nfs() {
    check_engine_nfs "${1:-tux2lab-engine}" || return 1
    sudo podman exec "${1:-tux2lab-engine}" exportfs -f
}

verify_container_nfs_stopped() {
    if [[ -r /proc/fs/nfsd/threads && "$(cat /proc/fs/nfsd/threads)" != 0 ]]; then
        printf 'Kernel NFS is still running; refusing to unmount lab filesystems.\n' >&2
        return 1
    fi
    local listeners
    listeners=$(sudo ss -H -lntu '( sport = :2049 or sport = :111 or sport = :20048 )') || return 1
    if [[ -n "$listeners" ]]; then
        printf 'NFS/RPC listeners remain; refusing filesystem cleanup or ownership transfer.\n' >&2
        return 1
    fi
}

stop_engine_nfs() {
    local name="${1:-tux2lab-engine}"
    if sudo podman container exists "$name"; then
        require_container_nfs_engine "$name" || return 1
        sudo podman stop --time 30 "$name" || return 1
    fi
    verify_container_nfs_stopped
}