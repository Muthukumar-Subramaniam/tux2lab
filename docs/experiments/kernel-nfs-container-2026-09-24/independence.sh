#!/usr/bin/env bash
set -euo pipefail

readonly ARCHIVE="/tux2lab/docs/experiments/kernel-nfs-container-2026-09-17"
readonly WORK_DIR="/tmp/tux2lab-kernel-nfs-test-20260924"
readonly CONTAINER_NAME="tux2lab-kernel-nfs-independence-test"
readonly IMAGE="localhost/tux2lab-kernel-nfs-test:20260917-f2f902b4"
readonly SERVICES=(rpcbind.socket rpcbind.service rpc-statd.service nfs-idmapd.service nfs-mountd.service nfs-server.service)
readonly COLD_START="${COLD_START:-0}"
readonly SERVER_SCRIPT="${SERVER_SCRIPT:-/test/server.sh}"
handover_started=false
cold_started=false
pseudo_root=""
state_dir=""

cleanup() {
    local original_status=$?
    local restore_failed=0
    local service
    trap - EXIT INT TERM
    set +e
    if "$handover_started"; then
        if podman container exists "$CONTAINER_NAME"; then
            podman stop --time 15 "$CONTAINER_NAME"
            if [[ "$(podman inspect --format '{{.State.Running}}' "$CONTAINER_NAME")" != "false" ]]; then
                printf 'ERROR: test container has not stopped; refusing competing host startup.\n' >&2
                exit 1
            fi
            podman logs "$CONTAINER_NAME" > "$WORK_DIR/container-${state_dir##*/}.log" 2>&1
            podman rm "$CONTAINER_NAME"
        fi
        if "$cold_started"; then
            modprobe nfsd || restore_failed=1
            systemctl start proc-fs-nfsd.mount || restore_failed=1
        fi
        /usr/sbin/rpc.nfsd 0 || restore_failed=1
        /usr/sbin/exportfs -ua || restore_failed=1
        systemctl start "${SERVICES[@]}" || restore_failed=1
        /usr/sbin/exportfs -ra || restore_failed=1
        for service in "${SERVICES[@]}"; do
            if ! systemctl is-active --quiet "$service"; then
                printf 'ERROR: failed to restore %s\n' "$service" >&2
                restore_failed=1
            fi
        done
        /usr/sbin/exportfs -s > "$WORK_DIR/exports.after"
        cmp "$WORK_DIR/exports.before" "$WORK_DIR/exports.after" || restore_failed=1
        if ((restore_failed != 0)); then
            printf 'ERROR: rollback needs attention; inspect %s.\n' "$WORK_DIR" >&2
            exit 1
        fi
        printf 'RESTORED: all six host services and original exports\n'
        cat /proc/fs/nfsd/versions /proc/fs/nfsd/threads
    fi
    if [[ -n "$pseudo_root" ]]; then
        rmdir "$pseudo_root/tux2lab-data" "$pseudo_root" || exit 1
    fi
    printf 'Evidence and fresh-state directory retained: %s\n' "$WORK_DIR"
    exit "$original_status"
}

if ((EUID != 0)); then
    printf 'Run with sudo -n bash.\n' >&2
    exit 1
fi
umask 077
exec 9>/run/lock/tux2lab-nfs-experiment.lock
flock -n 9 || { printf 'Another NFS experiment owns the lock.\n' >&2; exit 1; }
[[ "$COLD_START" == "0" || "$COLD_START" == "1" ]]
if [[ "$COLD_START" == "1" ]]; then
    systemctl is-active --quiet proc-fs-nfsd.mount
    [[ -f /sys/module/nfsd/refcnt ]]
    [[ "$(cat /proc/sys/kernel/modules_disabled)" == "0" ]]
fi
for service in "${SERVICES[@]}"; do
    systemctl is-active --quiet "$service" || { printf 'Baseline service inactive: %s\n' "$service" >&2; exit 1; }
done
podman image exists "$IMAGE"
if podman container exists "$CONTAINER_NAME" || podman container exists tux2lab-kernel-nfs-test; then
    printf 'An experiment container already exists.\n' >&2
    exit 1
fi
if [[ -n "$(ss -Htn '( sport = :2049 or dport = :2049 )')" ]] || \
   [[ -n "$(find /proc/fs/nfsd/clients -mindepth 1 -maxdepth 1 -type d -print -quit)" ]]; then
    printf 'NFS clients detected; refusing handover.\n' >&2
    exit 1
fi
if pgrep -f '[v]irt-install|[k]vm-build-golden-image|[k]vm-install-pxe' >/dev/null; then
    printf 'An installer is running; refusing handover.\n' >&2
    exit 1
fi
if exportfs -s | awk '$1 != "/tux2lab-data" { found=1 } END { exit !found }'; then
    printf 'Unrelated exports detected; refusing handover.\n' >&2
    exit 1
fi
[[ "$(findmnt -n -o FSTYPE -T /tux2lab-data)" == "ext4" ]]
mkdir -p "$WORK_DIR"
exportfs -s > "$WORK_DIR/exports.before"
systemctl show "${SERVICES[@]}" -p Id -p ActiveState -p SubState > "$WORK_DIR/services.before"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
state_dir=$(mktemp -d "$WORK_DIR/state.XXXXXX")
pseudo_root=$(mktemp -d /tux2lab-data/.nfs-kernel-test-root.XXXXXX)
mkdir "$pseudo_root/tux2lab-data"
handover_started=true
systemctl stop nfs-server.service nfs-mountd.service nfs-idmapd.service rpc-statd.service rpcbind.service rpcbind.socket
for service in "${SERVICES[@]}"; do
    service_state=$(systemctl show "$service" -p ActiveState --value)
    case "$service_state" in
        inactive|failed) ;;
        *) printf 'Service not stopped: %s (%s)\n' "$service" "$service_state" >&2; exit 1 ;;
    esac
    if [[ "$service" == *.service ]]; then
        [[ "$(systemctl show "$service" -p MainPID --value)" == "0" ]]
    fi
done
[[ "$(cat /proc/fs/nfsd/threads)" == "0" ]]
if pgrep -x 'rpc\.(mountd|idmapd|statd)|rpcbind' >/dev/null; then
    printf 'Host RPC userspace is still running.\n' >&2
    exit 1
fi
printf 'STOPPED: all six host services; no host NFS/RPC daemons\n'
printf 'FRESH STATE: %s\n' "$state_dir"
if [[ "$COLD_START" == "1" ]]; then
    cold_started=true
    systemctl stop proc-fs-nfsd.mount
    if mountpoint -q /proc/fs/nfsd; then
        printf 'Host nfsd control filesystem is still mounted.\n' >&2
        exit 1
    fi
    [[ -z "$(find /sys/module/nfsd/holders -mindepth 1 -maxdepth 1 -print -quit)" ]]
    rmmod nfsd
    [[ ! -e /sys/module/nfsd ]]
    printf 'COLD: nfsd module absent before container startup\n'
fi
podman run --name "$CONTAINER_NAME" --network=host --userns=host --privileged \
    -v "$pseudo_root:/export:ro" \
    -v /tux2lab-data:/export/tux2lab-data:ro,rslave \
    -v "$ARCHIVE:/test:ro" \
    -v "$WORK_DIR:/followup:ro" \
    -v "$state_dir:/var/lib/nfs" \
    -e NFS_BIND_IP=10.28.28.1 \
    -e NFS_BIND_IPV6=fd28:2808:2020:3000::1 \
    "$IMAGE" "$SERVER_SCRIPT"