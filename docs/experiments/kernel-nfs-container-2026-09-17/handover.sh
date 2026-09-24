#!/usr/bin/env bash
set -euo pipefail

readonly WORK_DIR="/tmp/tux2lab-kernel-nfs-test-20260917-f2f902b4"
readonly CONTAINER_NAME="tux2lab-kernel-nfs-test"
readonly IMAGE="localhost/tux2lab-kernel-nfs-test:20260917-f2f902b4"
handover_started=false
pseudo_root=""

cleanup() {
    local original_status=$?
    trap - EXIT INT TERM
    set +e
    if "$handover_started"; then
        if podman container exists "$CONTAINER_NAME"; then
            podman stop --time 15 "$CONTAINER_NAME"
        fi
        printf 'Restoring host NFS...\n'
        /usr/sbin/rpc.nfsd 0
        /usr/sbin/exportfs -ua
        systemctl start rpcbind.socket rpcbind.service rpc-statd.service nfs-server.service nfs-mountd.service
        local restore_status=$?
        /usr/sbin/exportfs -ra
        if ((restore_status != 0)) || ! systemctl is-active --quiet nfs-server.service nfs-mountd.service; then
            printf 'ERROR: host NFS restoration requires attention.\n' >&2
            exit 1
        fi
        printf 'RESTORED: host NFS\n'
        cat /proc/fs/nfsd/versions /proc/fs/nfsd/threads
    fi
    if [[ -n "$pseudo_root" ]]; then
        rmdir "$pseudo_root/tux2lab-data" "$pseudo_root"
    fi
    exit "$original_status"
}

if ((EUID != 0)); then
    printf 'Run this test with sudo.\n' >&2
    exit 1
fi
systemctl is-active --quiet nfs-server.service nfs-mountd.service
if podman container exists "$CONTAINER_NAME"; then
    printf 'Test container already exists; refusing to replace it.\n' >&2
    exit 1
fi
if [[ -n "$(ss -Htn '( sport = :2049 )')" ]] || \
   [[ -n "$(find /proc/fs/nfsd/clients -mindepth 1 -maxdepth 1 -type d -print -quit)" ]]; then
    printf 'Active NFS clients detected; refusing to interrupt them.\n' >&2
    exit 1
fi
if pgrep -f '[v]irt-install|[k]vm-build-golden-image' >/dev/null; then
    printf 'An installer is running; refusing to interrupt it.\n' >&2
    exit 1
fi

mkdir -p "$WORK_DIR/state"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
pseudo_root=$(mktemp -d /tux2lab-data/.nfs-kernel-test-root.XXXXXX)
mkdir "$pseudo_root/tux2lab-data"
handover_started=true
systemctl stop nfs-server.service nfs-mountd.service
systemctl stop rpc-statd.service rpcbind.service rpcbind.socket
if [[ "$(cat /proc/fs/nfsd/threads)" != "0" ]] || pgrep -x rpc.mountd >/dev/null; then
    printf 'Host NFS did not fully stop.\n' >&2
    exit 1
fi

podman run --rm --name "$CONTAINER_NAME" --network=host --userns=host --privileged \
    -v "$pseudo_root:/export:ro" \
    -v /tux2lab-data:/export/tux2lab-data:ro,rslave \
    -v "$WORK_DIR:/test:ro" \
    -v "$WORK_DIR/state:/var/lib/nfs" \
    -e NFS_BIND_IP=10.28.28.1 \
    -e NFS_BIND_IPV6=fd28:2808:2020:3000::1 \
    "$IMAGE" /test/server.sh