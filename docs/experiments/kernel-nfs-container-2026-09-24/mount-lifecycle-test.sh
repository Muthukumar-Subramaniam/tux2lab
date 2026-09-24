#!/usr/bin/env bash
set -euo pipefail

readonly CONTAINER_NAME="tux2lab-kernel-nfs-independence-test"
readonly ORIGINAL_ISO="/tux2lab-data/os-repos/almalinux/9"
iso_source=$(findmnt -n -o SOURCE --mountpoint "$ORIGINAL_ISO")
dynamic_dir=$(mktemp -d /tux2lab-data/os-repos/.nfs-kernel-test-mount.XXXXXX)
client_dir=$(mktemp -d /tmp/tux2lab-nfs-client.XXXXXX)

cleanup() {
    local original_status=$?
    trap - EXIT INT TERM
    if mountpoint -q "$client_dir"; then
        umount -R "$client_dir" || exit 1
    fi
    if mountpoint -q "$dynamic_dir"; then
        podman exec "$CONTAINER_NAME" exportfs -f || exit 1
        umount "$dynamic_dir" || exit 1
    fi
    rmdir "$dynamic_dir" "$client_dir"
    exit "$original_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for round in 1 2; do
    mount -o ro "$iso_source" "$dynamic_dir"
    [[ "$(podman exec "$CONTAINER_NAME" stat -f -c %T "/export$dynamic_dir")" == "isofs" ]]

    timeout --kill-after=5s 45s mount -t nfs \
        -o ro,vers=4.2,proto=tcp,soft,timeo=20,retrans=2,retry=0 \
        10.28.28.1:/tux2lab-data "$client_dir"
    timeout --kill-after=5s 90s cmp \
        "$ORIGINAL_ISO/images/install.img" \
        "$client_dir/os-repos/${dynamic_dir##*/}/images/install.img"
    printf 'PASS: dynamically added ISO readable, round %s\n' "$round"

    umount -R "$client_dir"
    podman exec "$CONTAINER_NAME" exportfs -f
    umount "$dynamic_dir"
    [[ "$(podman exec "$CONTAINER_NAME" stat -f -c %T "/export$dynamic_dir")" != "isofs" ]]
    printf 'PASS: ISO unmount propagated, round %s\n' "$round"
done