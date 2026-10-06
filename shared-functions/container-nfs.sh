#!/usr/bin/env bash

source "$(dirname -- "${BASH_SOURCE[0]}")/engine-rootfs.sh"

container_nfs_exists() {
    local status
    if sudo podman container exists "$1"; then
        printf 'true\n'
    else
        status=$?
        if [[ "$status" != 1 ]]; then
            printf 'Cannot inspect container %s (status %s); refusing ownership changes.\n' "$1" "$status" >&2
            return 1
        fi
        printf 'false\n'
    fi
}

container_nfs_image_check() {
    local image="$1" label
    label=$(sudo podman image inspect "$image" --format '{{index .Labels "io.tux2lab.nfs"}}') || return 1
    if [[ "$label" != container-v1 ]]; then
        printf 'This image does not support container NFS. Build the migration image and set TUX2LAB_ENGINE_IMAGE.\n' >&2
        return 1
    fi
    label=$(sudo podman image inspect "$image" --format '{{index .Labels "io.tux2lab.nfs.layout"}}') || return 1
    if [[ "$label" != direct-v1 ]]; then
        printf 'This image uses the obsolete export layout. Rebuild the migration image.\n' >&2
        return 1
    fi
}

container_nfs_require_no_client_mounts() {
    local filesystems
    filesystems=$(findmnt -rn -o FSTYPE) || {
        printf 'Cannot inspect host mount table; refusing NFS ownership changes.\n' >&2
        return 1
    }
    if [[ -z "$filesystems" ]] || grep -Eq '^(nfs|nfs4)$' <<< "$filesystems"; then
        printf 'Host NFS client mounts exist; lockd ownership requires a dedicated host.\n' >&2
        return 1
    fi
}

container_nfs_host_preflight() {
    local unit load_state active_state main_pid
    for unit in nfs-server.service nfs-kernel-server.service nfs-mountd.service rpc-mountd.service \
                rpcbind.service rpc-statd.service nfs-idmapd.service nfsdcld.service rpcbind.socket; do
        load_state=$(sudo systemctl show "$unit" -p LoadState --value) || return 1
        case "$load_state" in
            not-found) continue ;;
            loaded|masked) ;;
            *) printf 'Cannot determine host unit state: %s\n' "$unit" >&2; return 1 ;;
        esac
        active_state=$(sudo systemctl show "$unit" -p ActiveState --value) || return 1
        if [[ "$active_state" == failed && "$unit" == *.service ]]; then
            main_pid=$(sudo systemctl show "$unit" -p MainPID --value) || return 1
            [[ "$main_pid" == 0 ]] && continue
        elif [[ "$active_state" == inactive ]]; then
            continue
        fi
        printf 'Host %s is not stopped. Run the documented NFS migration first.\n' "$unit" >&2
        return 1
    done
    container_nfs_require_no_client_mounts || return 1
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

prepare_container_nfs_data_mount() {
    local data_dir="$1" mount_target propagation
    [[ "$data_dir" != / && "$(readlink -e "$data_dir")" == "$data_dir" ]] || return 1
    mount_target=$(findmnt -rn -o TARGET -T "$data_dir") || return 1
    [[ "$mount_target" == /* ]] || return 1
    if [[ "$mount_target" != "$data_dir" ]]; then
        sudo mount --rbind "$data_dir" "$data_dir" || return 1
        sudo mount --make-rprivate "$data_dir" || return 1
    fi
    sudo mount --make-rshared "$data_dir" || return 1
    propagation=$(findmnt -rn -o PROPAGATION --mountpoint "$data_dir") || return 1
    [[ ",$propagation," == *,shared,* ]]
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
    sudo mkdir -p "$data_dir/nfs/state" || return 1
    sudo chmod 700 "$data_dir/nfs/state" || return 1
    prepare_container_nfs_data_mount "$data_dir"
}

check_engine_nfs() {
    sudo podman exec "${1:-tux2lab-engine}" /bin/bash /usr/local/lib/tux2lab/nfs-service.sh check
}

record_engine_nfs_owner() {
    sudo timeout --kill-after=5 90 python3 "$(dirname -- "${BASH_SOURCE[0]}")/nfs-recovery.py" record "${1:-tux2lab-engine}"
}

recover_engine_nfs() {
    container_nfs_host_preflight || return 1
    sudo timeout --kill-after=5 90 unshare --mount --propagation private \
        python3 "$(dirname -- "${BASH_SOURCE[0]}")/nfs-recovery.py" recover "${1:-tux2lab-engine}"
}

wait_for_engine_nfs() {
    local name="${1:-tux2lab-engine}" attempt
    for ((attempt = 0; attempt < 30; attempt++)); do
        if check_engine_nfs "$name" >/dev/null 2>&1; then
            record_engine_nfs_owner "$name"
            return $?
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
    local threads status listeners
    if sudo test -e /proc/fs/nfsd/threads; then
        threads=$(sudo cat /proc/fs/nfsd/threads) || {
            printf 'Cannot read kernel NFS thread state; refusing filesystem cleanup.\n' >&2
            return 1
        }
        if [[ "$threads" != 0 ]]; then
            printf 'Kernel NFS is running or its thread state is invalid; refusing filesystem cleanup.\n' >&2
            return 1
        fi
    else
        status=$?
        [[ "$status" == 1 ]] || {
            printf 'Cannot inspect the kernel NFS control file; refusing filesystem cleanup.\n' >&2
            return 1
        }
    fi
    listeners=$(sudo ss -H -lntu '( sport = :2049 or sport = :111 or sport = :20048 )') || return 1
    if [[ -n "$listeners" ]]; then
        printf 'NFS/RPC listeners remain; refusing filesystem cleanup or ownership transfer.\n' >&2
        return 1
    fi
}

stop_engine_nfs() {
    local name="${1:-tux2lab-engine}" exists
    exists=$(container_nfs_exists "$name") || return 1
    if [[ "$exists" == true ]]; then
        require_container_nfs_engine "$name" || return 1
        sudo podman stop --time 30 "$name" || return 1
    fi
    verify_container_nfs_stopped
}