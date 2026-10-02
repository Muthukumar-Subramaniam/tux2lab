#!/usr/bin/env bash

engine_image_name() {
    sudo podman inspect "$1" --format '{{if index .Config.Labels "io.tux2lab.image.name"}}{{index .Config.Labels "io.tux2lab.image.name"}}{{else}}{{.ImageName}}{{end}}'
}

restore_engine_exports() {
    local name="$1" destination="$2" metadata rootfs
    metadata=$(sudo podman inspect "$name") || return 1
    rootfs=$(jq -er '.[0].Config.Labels["io.tux2lab.rootfs"] // ""' <<< "$metadata") || return 1
    if [[ -z "$rootfs" ]]; then
        sudo podman cp "$name:/etc/exports" "$destination"
        return $?
    fi
    jq -e --arg root "$rootfs" '.[0] | .State.Running == false and .Rootfs == $root' <<< "$metadata" >/dev/null || return 1
    [[ "$rootfs" =~ ^/var/lib/tux2lab/engine-rootfs/engine\.[a-zA-Z0-9]{8}/rootfs$ ]] || return 1
    [[ "$(sudo readlink -e "$rootfs/etc/exports")" == "$rootfs/etc/exports" ]] || return 1
    sudo cp "$rootfs/etc/exports" "$destination"
}

remove_engine_rootfs() {
    local rootfs="$1" instance containers metadata mounts
    [[ "$rootfs" =~ ^/var/lib/tux2lab/engine-rootfs/engine\.[a-zA-Z0-9]{8}/rootfs$ ]] || return 1
    instance="${rootfs%/rootfs}"
    [[ "$(sudo readlink -e "$rootfs")" == "$rootfs" ]] || return 1
    [[ "$(sudo cat "$instance/owner")" == tux2lab-engine-rootfs-v1 ]] || return 1
    containers=$(sudo podman ps -aq) || return 1
    if [[ -n "$containers" ]]; then
        local -a container_ids
        mapfile -t container_ids <<< "$containers"
        metadata=$(sudo podman inspect "${container_ids[@]}") || return 1
        jq -e --arg root "$rootfs" 'all(.[]; .Rootfs != $root and .Config.Labels["io.tux2lab.rootfs"] != $root)' <<< "$metadata" >/dev/null || return 1
    fi
    mounts=$(sudo findmnt --json -o TARGET) || return 1
    jq -e --arg root "$instance" '[.. | objects | .target? // empty | select(. == $root or startswith($root + "/"))] | length == 0' <<< "$mounts" >/dev/null || return 1
    sudo rm -rf --one-file-system -- "$instance"
}

prepare_engine_rootfs() (
    local image="$1" base=/var/lib/tux2lab/engine-rootfs instance='' rootfs='' copy='' filesystem status
    set -o pipefail
    cleanup_rootfs_preparation() {
        status=$?
        trap - EXIT
        if [[ -n "$copy" ]]; then sudo podman rm "$copy" >/dev/null || status=1; fi
        if [[ "$status" != 0 && -n "$rootfs" ]]; then
            if ! remove_engine_rootfs "$rootfs"; then
                printf 'Retained incomplete engine root: %s\n' "$rootfs" >&2
            fi
        fi
        exit "$status"
    }
    trap cleanup_rootfs_preparation EXIT
    sudo mkdir -p "$base" || return 1
    [[ "$(sudo readlink -e "$base")" == "$base" ]] || return 1
    sudo chown root:root "$base" || return 1
    sudo chmod 700 "$base" || return 1
    filesystem=$(findmnt -n -o FSTYPE -T "$base") || return 1
    case "$filesystem" in
        ext4|xfs|btrfs) ;;
        *) printf 'Engine root requires an exportable filesystem, found %s.\n' "$filesystem" >&2; return 1 ;;
    esac
    instance=$(sudo mktemp -d "$base/engine.XXXXXXXX") || return 1
    printf 'tux2lab-engine-rootfs-v1\n' | sudo tee "$instance/owner" >/dev/null || return 1
    sudo mkdir "$instance/rootfs" || return 1
    rootfs="$instance/rootfs"
    copy=$(sudo podman create --network=none --entrypoint /bin/true "$image") || return 1
    sudo podman export "$copy" | sudo tar --numeric-owner -xpf - -C "$rootfs" || return 1
    sudo podman rm "$copy" >/dev/null || return 1
    copy=''
    sudo test -x "$rootfs/entrypoint.sh" || return 1
    printf '%s\n' "$rootfs"
)

remove_engine_container() {
    local name="$1" metadata rootfs
    metadata=$(sudo podman inspect "$name") || return 1
    rootfs=$(jq -er '.[0].Config.Labels["io.tux2lab.rootfs"] // ""' <<< "$metadata") || return 1
    if [[ -n "$rootfs" ]]; then
        jq -e --arg root "$rootfs" '.[0] | .State.Running == false and .Rootfs == $root' <<< "$metadata" >/dev/null || return 1
        [[ "$rootfs" =~ ^/var/lib/tux2lab/engine-rootfs/engine\.[a-zA-Z0-9]{8}/rootfs$ ]] || return 1
    fi
    sudo podman rm "$name" || return 1
    if [[ -n "$rootfs" ]] && ! remove_engine_rootfs "$rootfs"; then
        printf 'Container removed, but engine root retained for inspection: %s\n' "$rootfs" >&2
        return 1
    fi
}