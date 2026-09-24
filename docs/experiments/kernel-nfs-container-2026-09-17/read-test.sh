#!/usr/bin/env bash
set -euo pipefail

readonly SERVER="${1:-10.28.28.1}"
client_dir=$(mktemp -d /tmp/tux2lab-nfs-client.XXXXXX)
transport=tcp
if [[ "$SERVER" == \[* ]]; then
    transport=tcp6
fi

cleanup() {
    local original_status=$?
    trap - EXIT INT TERM
    if mountpoint -q "$client_dir"; then
        if ! umount -R "$client_dir"; then
            printf 'ERROR: client mount still present at %s\n' "$client_dir" >&2
            exit 1
        fi
    fi
    rmdir "$client_dir"
    exit "$original_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

timeout --kill-after=5s 45s mount -v -t nfs \
    -o "ro,vers=${NFS_TEST_VERSION:-4.2},proto=$transport,nolock,soft,timeo=20,retrans=2,retry=0" \
    "$SERVER:/tux2lab-data" "$client_dir"

for relative_path in \
    lab-config/lab_environment.json \
    os-repos/almalinux/9/images/install.img \
    os-repos/ubuntu-lts/24.04/casper/ubuntu-server-minimal.squashfs; do
    timeout --kill-after=5s 90s cmp \
        "/tux2lab-data/$relative_path" "$client_dir/$relative_path"
    printf 'PASS: %s via %s\n' "$relative_path" "$SERVER"
done