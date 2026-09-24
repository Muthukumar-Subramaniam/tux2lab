#!/usr/bin/env bash
set -euxo pipefail

: "${NFS_BIND_IP:?}"
: "${NFS_BIND_IPV6:?}"
mountd_pid=""

cleanup() {
    set +e
    rpc.nfsd 0
    exportfs -ua
    if [[ -n "$mountd_pid" ]]; then
        kill "$mountd_pid"
    fi
    pkill -x rpc.statd || true
    pkill -x rpcbind || true
    umount /proc/fs/nfsd
}

mkdir -p /proc/fs/nfsd /var/lib/nfs/v4recovery
mount -t nfsd nfsd /proc/fs/nfsd
if [[ "$(cat /proc/fs/nfsd/threads)" != "0" ]]; then
    printf 'Refusing to take over an active kernel NFS instance.\n' >&2
    exit 1
fi
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ln -s /export/tux2lab-data /tux2lab-data
cp /test/exports /etc/exports
printf '[nfsd]\nhost = %s,%s\n' "$NFS_BIND_IP" "$NFS_BIND_IPV6" > /etc/nfs.conf
exportfs -rav
rpcbind -h "$NFS_BIND_IP" -h "$NFS_BIND_IPV6"
rpc.mountd --foreground --no-nfs-version 2 --port 20048 --log-auth &
mountd_pid=$!
rpc.nfsd --nfs-version 3 --nfs-version 4 --udp 8
printf 'READY: container NFSv3/v4 server\n'
cat /proc/fs/nfsd/versions /proc/fs/nfsd/threads
wait "$mountd_pid"