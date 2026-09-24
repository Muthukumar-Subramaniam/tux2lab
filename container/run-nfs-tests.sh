#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$PROJECT_ROOT/shared-functions/nfs-config.sh"

if [[ "${1:-}" == --service ]]; then
    [[ $# == 2 ]] || exit 2
    service_dir=$(sudo mktemp -d /tux2lab-data/.nfs-service-test.XXXXXXXX)
    trap 'sudo rm -rf -- "$service_dir"' EXIT
    sudo mkdir -p "$service_dir/root/tux2lab-data" "$service_dir/data/nfs" "$service_dir/state"
    sudo podman run --rm -i --network=none --privileged \
        -e "TUX2LAB_HOST_NETNS=$(stat -Lc %i /proc/self/ns/net)" \
        -v "$PROJECT_ROOT:/tux2lab:ro" \
        -v "$service_dir/root:/export:ro" \
        -v "$service_dir/data:/export/tux2lab-data" \
        -v "$service_dir/state:/var/lib/nfs" \
        --entrypoint /bin/bash "$2" /tux2lab/container/run-nfs-tests.sh --service-internal
    exit 0
fi

run_isolated_service_test() (
    [[ "$(stat -Lc %i /proc/self/ns/net)" != "${TUX2LAB_HOST_NETNS:?}" ]] || exit 1
    [[ "$(ip -o link show | wc -l)" == 1 ]] || exit 1
    source "$PROJECT_ROOT/container/nfs-service.sh"
    ip link set lo up
    ip link add labbr0 type dummy
    ip link set labbr0 up
    ip addr add 192.0.2.1/24 dev labbr0
    ip -6 addr add 2001:db8:1::1/64 dev labbr0 nodad
    BRIDGE_IP=192.0.2.1
    BRIDGE_IPV6=2001:db8:1::1
    BRIDGE_IF=labbr0
    DATA_DIR=/tux2lab-data
    ln -s /export/tux2lab-data "$DATA_DIR"
    write_container_nfs_conf "$BRIDGE_IP" "$BRIDGE_IPV6" > "$DATA_DIR/nfs/container.conf"
    write_container_nfs_exports "$DATA_DIR" 192.0.2.0/24 2001:db8:1::/64 > "$DATA_DIR/nfs/container.exports"
    printf 'container NFS fixture\n' > "$DATA_DIR/fixture"
    mkdir -p /mnt/nfs-test
    sysctl() {
        [[ "$*" == '-w fs.nfs.nlm_tcpport=32803 fs.nfs.nlm_udpport=32769' ]] || return 1
        printf 'SKIP: host-wide lockd port changes in isolated service test\n' >&2
    }
    cleanup_service_test() {
        local status=$?
        trap - EXIT
        if mountpoint -q /mnt/nfs-test; then
            umount /mnt/nfs-test || status=1
        fi
        stop_container_nfs || status=1
        exit "$status"
    }
    trap cleanup_service_test EXIT
    start_container_nfs
    for protocol in v4-ipv4 v4-ipv6 v3-ipv4; do
        case "$protocol" in
            v4-ipv4) mount -t nfs -o rw,vers=4.1,proto=tcp,retry=0 192.0.2.1:/tux2lab-data /mnt/nfs-test ;;
            v4-ipv6) mount -t nfs -o rw,vers=4.1,proto=tcp6,retry=0 '[2001:db8:1::1]:/tux2lab-data' /mnt/nfs-test ;;
            v3-ipv4) mount -t nfs -o rw,vers=3,nolock,proto=tcp,retry=0 192.0.2.1:/tux2lab-data /mnt/nfs-test ;;
        esac
        cmp "$DATA_DIR/fixture" /mnt/nfs-test/fixture
        if touch /mnt/nfs-test/not-allowed 2>/dev/null; then
            printf 'FAIL: NFS export allowed a write\n' >&2
            exit 1
        fi
        umount /mnt/nfs-test
        printf 'PASS: isolated %s original-path read-only export\n' "$protocol"
    done
    stop_container_nfs
    [[ -z "$(ss -H -lntu '( sport = :111 or sport = :2049 or sport = :20048 )')" ]]
    printf 'PASS: isolated NFS service releases its listeners\n'
    start_container_nfs
    printf 'PASS: isolated NFS service restarts with persistent state\n'
    mountd_pid="${NFS_CHILDREN[2]}"
    kill -KILL "$mountd_pid"
    wait "$mountd_pid" 2>/dev/null || true
    if check_container_nfs; then
        printf 'FAIL: dead mountd remained healthy\n' >&2
        exit 1
    fi
    stop_container_nfs
    [[ -z "$(ss -H -lntu '( sport = :111 or sport = :2049 or sport = :20048 )')" ]]
    printf 'PASS: mountd failure invalidates readiness and cleanup releases listeners\n'
    exit 0
)

if [[ "${1:-}" == --service-internal ]]; then
    run_isolated_service_test
    exit 0
fi

if [[ "${1:-}" == --firewall ]]; then
    [[ $# == 2 ]] || exit 2
    exec sudo podman run --rm -i --network=none --cap-add=NET_ADMIN --cap-add=SYS_ADMIN \
        --security-opt seccomp=unconfined -v "$PROJECT_ROOT:/tux2lab:ro" \
        --entrypoint /bin/bash "$2" /tux2lab/container/run-nfs-tests.sh --firewall-internal
fi

if [[ "${1:-}" == --firewall-internal ]]; then
    [[ "$EUID" == 0 ]] || exit 1
    [[ "$(ip -o link show | wc -l)" == 1 ]] || exit 1
    ip link set lo up
    ip link add labbr0 type bridge
    ip link set labbr0 up
    for client in allowed denied; do
        ip netns add "$client"
        ip link add "${client}0" type veth peer name client0 netns "$client"
        ip link set "${client}0" up
        ip netns exec "$client" ip link set lo up
        ip netns exec "$client" ip link set client0 up
    done
    ip link set allowed0 master labbr0
    ip addr add 192.0.2.1/24 dev labbr0
    ip -6 addr add 2001:db8:1::1/64 dev labbr0 nodad
    ip addr add 198.51.100.1/24 dev denied0
    ip -6 addr add 2001:db8:2::1/64 dev denied0 nodad
    ip netns exec allowed ip addr add 192.0.2.2/24 dev client0
    ip netns exec allowed ip -6 addr add 2001:db8:1::2/64 dev client0 nodad
    ip netns exec denied ip addr add 198.51.100.2/24 dev client0
    ip netns exec denied ip -6 addr add 2001:db8:2::2/64 dev client0 nodad
    write_container_nfs_firewall labbr0 | nft -f -
    python3 - <<'PYTEST'
import socket
import subprocess
import threading

tcp_ports = [111, 2049, 20048, 32803, 32765]
udp_ports = [111, 2049, 20048, 32769, 32765, 32766]

def serve(listener, stream):
    while True:
        if stream:
            connection, _ = listener.accept()
            with connection:
                connection.sendall(b"ready")
        else:
            _, peer = listener.recvfrom(64)
            listener.sendto(b"ready", peer)

listeners = []
for family, address in [(socket.AF_INET, "0.0.0.0"), (socket.AF_INET6, "::")]:
    for kind, ports in [(socket.SOCK_STREAM, tcp_ports), (socket.SOCK_DGRAM, udp_ports)]:
        for port in ports:
            listener = socket.socket(family, kind)
            if family == socket.AF_INET6:
                listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            listener.bind((address, port))
            if kind == socket.SOCK_STREAM:
                listener.listen()
            listeners.append(listener)
            threading.Thread(target=serve, args=(listener, kind == socket.SOCK_STREAM), daemon=True).start()

probe = '''
import socket, sys
expected = sys.argv[1] == "allowed"
for address in sys.argv[2:]:
    family = socket.AF_INET6 if ":" in address else socket.AF_INET
    for kind, ports in [(socket.SOCK_STREAM, [111,2049,20048,32803,32765]),
                        (socket.SOCK_DGRAM, [111,2049,20048,32769,32765,32766])]:
        for port in ports:
            with socket.socket(family, kind) as client:
                client.settimeout(0.5)
                try:
                    client.connect((address, port))
                    if kind == socket.SOCK_DGRAM:
                        client.send(b"probe")
                    received = client.recv(64) == b"ready"
                except (TimeoutError, OSError):
                    received = False
                assert received == expected, (address, port, kind, received)
'''
for namespace, addresses in [("allowed", ["192.0.2.1", "2001:db8:1::1"]),
                             ("denied", ["198.51.100.1", "2001:db8:2::1"])]:
    subprocess.run(["ip", "netns", "exec", namespace, "python3", "-c", probe, namespace, *addresses], check=True)
subprocess.run(["python3", "-c", probe, "allowed", "127.0.0.1", "::1"], check=True)
print("PASS: real IPv4/IPv6 TCP/UDP RPC ports allow bridge/loopback and reject outside traffic")
PYTEST
    exit 0
fi
[[ $# == 0 ]] || exit 2

exports=$(write_container_nfs_exports /tux2lab-data 192.0.2.0/24 2001:db8::/64)
[[ "$exports" == /export\ * ]]
[[ "$exports" == *$'\n/export/tux2lab-data '* ]]
[[ "$exports" == *'192.0.2.0/24(ro,sync,fsid=0,'* ]]
[[ "$exports" == *'2001:db8::/64(ro,sync,fsid=1,'* ]]
[[ "$exports" != *'rw,'* && "$exports" != *'*.'* ]]
printf 'PASS: read-only pseudoroot and numeric dual-stack clients\n'

exports=$(write_container_nfs_exports /tux2lab-data 192.0.2.0/24)
[[ "$exports" != *'::'* ]]
configuration=$(write_container_nfs_conf 192.0.2.1)
[[ "$configuration" == *$'host = 192.0.2.1\n'* ]]
[[ "$configuration" != *'192.0.2.1,'* ]]
printf 'PASS: IPv4-only configuration\n'

configuration=$(write_container_nfs_conf 192.0.2.1 2001:db8::1)
[[ "$configuration" == *$'host = 192.0.2.1,2001:db8::1\n'* ]]
[[ "$configuration" == *'port = 20048'* && "$configuration" == *'port = 32803'* ]]
[[ "$configuration" == *'udp-port = 32769'* && "$configuration" == *'port = 32765'* ]]
printf 'PASS: dual-stack binding and fixed RPC ports\n'

if write_container_nfs_exports '/bad path' 192.0.2.0/24 >/dev/null 2>&1 ||
   write_container_nfs_exports / 192.0.2.0/24 >/dev/null 2>&1 ||
   write_container_nfs_conf $'192.0.2.1\n[other]' >/dev/null 2>&1; then
    printf 'FAIL: unsafe configuration accepted\n' >&2
    exit 1
fi
printf 'PASS: invalid configuration rejected\n'

firewall=$(write_container_nfs_firewall labbr0)
[[ "$firewall" == *'type filter hook input priority -10'* ]]
[[ "$firewall" == *'iifname != { "lo", "labbr0" } tcp dport'* ]]
[[ "$firewall" == *'iifname != { "lo", "labbr0" } udp dport'* ]]
if write_container_nfs_firewall 'bad"bridge' >/dev/null 2>&1 ||
   write_container_nfs_firewall lo >/dev/null 2>&1; then
    printf 'FAIL: unsafe firewall interface accepted\n' >&2
    exit 1
fi
printf 'PASS: RPC confinement rule generation\n'

source "$PROJECT_ROOT/container/nfs-service.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
DATA_DIR="$test_dir/data"
NFS_CONTROL_DIR="$test_dir/control"
mkdir -p "$DATA_DIR/nfs" "$NFS_CONTROL_DIR"
printf 'test\n' > "$DATA_DIR/nfs/container.exports"
printf 'test\n' > "$DATA_DIR/nfs/container.conf"
printf '8\n' > "$NFS_CONTROL_DIR/threads"
if start_container_nfs >/dev/null 2>&1; then
    printf 'FAIL: active kernel server takeover allowed\n' >&2
    exit 1
fi
[[ "$NFS_OWNS_SERVER" == false && "${#NFS_CHILDREN[@]}" == 0 ]]
printf 'PASS: active server rejected before mutation\n'

(
    source "$PROJECT_ROOT/shared-functions/container-nfs.sh"
    sudo() {
        if [[ "$*" == 'podman image inspect old-image --format {{index .Labels "io.tux2lab.nfs"}}' ]]; then
            printf 'legacy\n'
        else
            printf 'Unexpected mutation: %s\n' "$*" >&2
            exit 99
        fi
    }
    if container_nfs_image_check old-image 2>/dev/null; then
        exit 1
    fi
)
printf 'PASS: incompatible image rejected\n'

(
    source "$PROJECT_ROOT/shared-functions/container-nfs.sh"
    source "$PROJECT_ROOT/shared-functions/run-container.sh"
    source() { :; }
    container_nfs_image_check() { printf 'image\n' >> "$test_dir/replacement"; }
    container_nfs_host_preflight() { :; }
    prepare_container_nfs() { :; }
    require_container_nfs_engine() { :; }
    stop_engine_nfs() { printf 'stop %s\n' "$1" >> "$test_dir/replacement"; }
    run_tux2lab_container() { printf 'run\n' >> "$test_dir/replacement"; return 1; }
    wait_for_engine_nfs() { printf 'ready %s\n' "$1" >> "$test_dir/replacement"; }
    sudo() {
        if [[ "$*" == 'podman container exists engine-rebuild-backup' ]]; then
            return 1
        fi
        printf '%s\n' "$*" >> "$test_dir/replacement"
    }
    if replace_tux2lab_container engine new-image lab /data 192.0.2.1 labbr0 2>/dev/null; then
        exit 1
    fi
    grep -qx 'podman rename engine-rebuild-backup engine' "$test_dir/replacement"
    grep -qx 'ready engine' "$test_dir/replacement"
    ! grep -q 'rm -f' "$test_dir/replacement"
)
printf 'PASS: replacement failure restores previous engine\n'

(
    source "$PROJECT_ROOT/shared-functions/container-nfs.sh"
    sudo() { printf 'LISTEN 0 64 192.0.2.1:2049\n'; }
    cat() { printf '0\n'; }
    if verify_container_nfs_stopped 2>/dev/null; then
        exit 1
    fi
)
printf 'PASS: residual kernel listener blocks cleanup\n'

(
    source "$PROJECT_ROOT/setup/migrate-nfs-to-container.sh"
    NFS_MIGRATION_DIR="$test_dir/blocked-rollback"
    mkdir -p "$NFS_MIGRATION_DIR"
    touch "$NFS_MIGRATION_DIR/snapshot-complete"
    printf 'original\n' > "$NFS_MIGRATION_DIR/engine-id"
    stop_engine_nfs() { return 1; }
    sudo() {
        case "$*" in
            'podman container exists '*) return 0 ;;
            'podman inspect tux2lab-engine-host-nfs-backup --format {{.Id}}') printf 'original\n' ;;
            *) printf 'FAIL: rollback continued after failed NFS shutdown\n' >&2; exit 99 ;;
        esac
    }
    if restore_host_nfs; then
        exit 1
    fi
    [[ -f "$NFS_MIGRATION_DIR/snapshot-complete" ]]
)
printf 'PASS: failed NFS shutdown blocks host rollback\n'

(
    source "$PROJECT_ROOT/setup/migrate-nfs-to-container.sh"
    NFS_MIGRATION_DIR="$test_dir/host-rollback"
    mkdir -p "$NFS_MIGRATION_DIR"
    touch "$NFS_MIGRATION_DIR/snapshot-complete"
    printf 'original\n' > "$NFS_MIGRATION_DIR/engine-id"
    printf 'rpcbind.service\tactive\tenabled\n' > "$NFS_MIGRATION_DIR/units"
    printf 'nfs-idmapd.service\tinactive\tstatic\n' >> "$NFS_MIGRATION_DIR/units"
    printf 'rpcbind.service\n' > "$NFS_MIGRATION_DIR/masked"
    printf '/tux2lab-data 192.0.2.0/24(ro)\n' > "$NFS_MIGRATION_DIR/exports"
    printf '0\n' > "$NFS_MIGRATION_DIR/lockd-tcp"
    printf '0\n' > "$NFS_MIGRATION_DIR/lockd-udp"
    printf 'true\n' > "$NFS_MIGRATION_DIR/engine-running"
    stop_engine_nfs() { printf 'stop\n' >> "$test_dir/host-rollback.log"; }
    verify_container_nfs_stopped() { :; }
    sudo() {
        printf '%s\n' "$*" >> "$test_dir/host-rollback.log"
        case "$*" in
            'podman inspect tux2lab-engine-host-nfs-backup --format {{.Id}}') printf 'original\n' ;;
            'systemctl show rpcbind.service -p UnitFileState --value') printf 'enabled\n' ;;
            'systemctl show rpcbind.service -p ActiveState --value') printf 'active\n' ;;
            'systemctl show nfs-idmapd.service -p UnitFileState --value') printf 'static\n' ;;
            'systemctl show nfs-idmapd.service -p ActiveState --value') printf 'inactive\n' ;;
            'exportfs -s') cat "$NFS_MIGRATION_DIR/exports" ;;
        esac
        return 0
    }
    restore_host_nfs >/dev/null
    [[ ! -e "$NFS_MIGRATION_DIR" ]]
    grep -qx 'podman rename tux2lab-engine-host-nfs-backup tux2lab-engine' "$test_dir/host-rollback.log"
    grep -qx 'systemctl unmask rpcbind.service' "$test_dir/host-rollback.log"
    grep -qx 'systemctl show rpcbind.service -p ActiveState --value' "$test_dir/host-rollback.log"
    grep -qx 'systemctl stop nfs-idmapd.service' "$test_dir/host-rollback.log"
    grep -qx 'podman start tux2lab-engine' "$test_dir/host-rollback.log"
)
printf 'PASS: host rollback restores engine, units, lockd settings and exports\n'

(
    source "$PROJECT_ROOT/setup/migrate-nfs-to-container.sh"
    NFS_MIGRATION_DIR="$test_dir/missing-backup"
    mkdir -p "$NFS_MIGRATION_DIR"
    touch "$NFS_MIGRATION_DIR/snapshot-complete"
    printf 'original\n' > "$NFS_MIGRATION_DIR/engine-id"
    sudo() {
        case "$*" in
            'podman container exists tux2lab-engine-host-nfs-backup') return 1 ;;
            'podman inspect tux2lab-engine --format {{.Id}}') printf 'replacement\n' ;;
            *) printf 'FAIL: missing backup permitted host service changes\n' >&2; exit 99 ;;
        esac
    }
    if restore_host_nfs 2>/dev/null; then
        exit 1
    fi
)
printf 'PASS: missing original engine blocks host rollback\n'

(
    source "$PROJECT_ROOT/setup/migrate-nfs-to-container.sh"
    NFS_MIGRATION_DIR="$test_dir/failed-snapshot"
    NFS_UNITS=()
    exportfs() { return 1; }
    sysctl() { printf 'FAIL: snapshot continued after failed export capture\n' >&2; exit 99; }
    if snapshot_host_nfs; then
        exit 1
    fi
    [[ ! -e "$NFS_MIGRATION_DIR/snapshot-complete" ]]
)
printf 'PASS: failed snapshot cannot authorize host mutation\n'