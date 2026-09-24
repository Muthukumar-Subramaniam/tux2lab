#!/usr/bin/env bash
set -euo pipefail

cleanup() {
    rpc.nfsd 0
    exportfs -ua
    umount /proc/fs/nfsd
}

mkdir -p /proc/fs/nfsd /var/lib/nfs
mount -t nfsd nfsd /proc/fs/nfsd
trap cleanup EXIT

stat -f -c '%n: %T' /tux2lab-data /tux2lab-data/os-repos/almalinux/9
exportfs -iv -o ro,sync,fsid=1,no_subtree_check,crossmnt 127.0.0.1:/tux2lab-data
exportfs -iv -o ro,sync,fsid=2,no_subtree_check 127.0.0.1:/tux2lab-data/os-repos/almalinux/9
exportfs -v
if [[ -n "${NFS_TEST_HOSTS:-}" ]]; then
    printf '[nfsd]\nhost = %s\n' "$NFS_TEST_HOSTS" > /etc/nfs.conf
fi
if (($# > 0)); then
    rpc.nfsd "$@"
    cat /proc/fs/nfsd/versions /proc/fs/nfsd/threads
fi