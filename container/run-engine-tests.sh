#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "FAIL: line %s (status %s): %.180s\n" "$LINENO" "$?" "$BASH_COMMAND" >&2' ERR

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$PROJECT_ROOT/shared-functions/engine-rootfs.sh"

generate_engine_fixtures() {
    if [[ "${TUX2LAB_TEST_FIXTURES:-}" != 1 || -e /tux2lab-data/lab-config/lab_environment.json ]]; then
        printf 'Fixture generation requires a dedicated empty test volume.\n' >&2
        return 1
    fi
    mkdir -p /tux2lab-data/lab-config/certs
    jq -n '{
        lab: {domain: "integration.test", engine_hostname: "engine", engine_fqdn: "engine.integration.test"},
        network: {
            bridge_interface: "labbr0", upstream_dns: ["192.0.2.1"],
            ipv4: {address: "192.0.2.1", network: "192.0.2.0", cidr: "192.0.2.0/24", prefix: 24,
                   netmask: "255.255.255.0", gateway: "192.0.2.1", broadcast: "192.0.2.255",
                   first24_subnet: "192.0.2", last24_subnet: "192.0.2",
                   dhcp_range_start: "192.0.2.100", dhcp_range_end: "192.0.2.120"},
            ipv6: {address: "2001:db8:1::1", prefix: 64, prefix_base: "2001:db8:1", ula_subnet: "2001:db8:1::/64"}
        },
        admin: {password_hash: "!"}
    }' > /tux2lab-data/lab-config/lab_environment.json
    bash "$PROJECT_ROOT/setup/generate-service-configs.sh"
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=engine.integration.test \
        -addext 'subjectAltName=DNS:engine.integration.test,IP:192.0.2.1,IP:2001:db8:1::1' \
        -keyout /tux2lab-data/lab-config/certs/tux2lab-nginx-selfsigned.key \
        -out /tux2lab-data/lab-config/certs/tux2lab-nginx-selfsigned.crt >/dev/null 2>&1
    cat > /tux2lab-data/named/named.conf <<'NAMED'
options {
    directory "/var/named";
    listen-on { 192.0.2.1; };
    listen-on-v6 { 2001:db8:1::1; };
    recursion no;
    allow-query { any; };
    pid-file "/run/named/named.pid";
};
zone "integration.test" {
    type master;
    file "/tux2lab-data/named/integration.test.zone";
};
NAMED
    cat > /tux2lab-data/named/integration.test.zone <<'ZONE'
$TTL 60
@ IN SOA engine.integration.test. hostmaster.integration.test. (1 60 60 3600 60)
  IN NS engine.integration.test.
engine IN A 192.0.2.1
engine IN AAAA 2001:db8:1::1
ZONE
    sed -i '/^pool /d' /tux2lab-data/chrony/chrony.conf
    printf 'engine integration fixture\n' > /tux2lab-data/fixture.txt
    mkdir -p /tux2lab-data/os-repos/dynamic
}

boot_test_engine() {
    [[ "$(stat -Lc %i /proc/self/ns/net)" != "${TUX2LAB_HOST_NETNS:?}" ]]
    [[ "$(ip -o link show | wc -l)" == 1 ]]
    ip link set lo up
    ip link add labbr0 type bridge
    ip link set labbr0 up
    ip netns add client
    ip link add enginepeer type veth peer name client0 netns client
    ip link set enginepeer master labbr0
    ip link set enginepeer up
    ip netns exec client ip link set lo up
    ip netns exec client ip link set client0 up
    ip addr add 192.0.2.1/24 dev labbr0
    ip -6 addr add 2001:db8:1::1/64 dev labbr0 nodad
    ip netns exec client ip addr add 192.0.2.2/24 dev client0
    ip netns exec client ip -6 addr add 2001:db8:1::2/64 dev client0 nodad
    sysctl() {
        case "$*" in
            '-w fs.nfs.nlm_tcpport=32803 fs.nfs.nlm_udpport=32769')
                printf 'SKIP: host-wide lockd writes in isolated engine test\n' >&2 ;;
            '-w net.ipv6.conf.all.forwarding=1'|'-w net.ipv6.conf.labbr0.forwarding=1')
                command sysctl "$@" ;;
            *) printf 'Unexpected sysctl in isolated test: %s\n' "$*" >&2; return 1 ;;
        esac
    }
    export -f sysctl
    exec /entrypoint.sh
}

check_engine_clients() {
    local address discovery
    discovery=$(showmount -e 192.0.2.1)
    [[ "$(awk 'NR > 1 {print $1}' <<< "$discovery")" == /tux2lab-data ]]
    printf 'PASS: deployed discovery advertises only /tux2lab-data\n'
    for address in 192.0.2.1 2001:db8:1::1; do
        [[ "$(dig "@$address" engine.integration.test A +short +time=2 +tries=1)" == 192.0.2.1 ]]
        [[ "$(dig "@$address" engine.integration.test AAAA +tcp +short +time=2 +tries=1)" == 2001:db8:1::1 ]]
    done
    printf 'PASS: client DNS answers over IPv4/IPv6 UDP and TCP\n'
    python3 - <<'CLIENT'
import http.client
import ipaddress
from pathlib import Path
import secrets
import socket
import ssl
import struct
import time

fixture = Path("/tux2lab-data/fixture.txt").read_bytes()
ipxe = Path("/tux2lab-data/tftpboot/ipxe.efi").read_bytes()
tls = ssl.create_default_context(cafile="/tux2lab-data/lab-config/certs/tux2lab-nginx-selfsigned.crt")

for address in ("192.0.2.1", "2001:db8:1::1"):
    for connection in (http.client.HTTPConnection(address, 80, timeout=5),
                       http.client.HTTPSConnection(address, 443, context=tls, timeout=5)):
        connection.request("GET", "/fixture.txt")
        response = connection.getresponse()
        assert response.status == 200 and response.read() == fixture
        connection.close()
    family = socket.AF_INET6 if ":" in address else socket.AF_INET
    with socket.socket(family, socket.SOCK_DGRAM) as client:
        client.settimeout(5)
        client.sendto(b"\x00\x01ipxe.efi\x00octet\x00", (address, 69))
        received = bytearray()
        block = 1
        while True:
            packet, peer = client.recvfrom(2048)
            opcode, sequence = struct.unpack("!HH", packet[:4])
            assert opcode == 3 and sequence == block, (opcode, sequence, block)
            received.extend(packet[4:])
            client.sendto(struct.pack("!HH", 4, sequence), peer)
            if len(packet) < 516:
                break
            block = (block + 1) % 65536
        assert received == ipxe
    with socket.socket(family, socket.SOCK_DGRAM) as client:
        client.settimeout(5)
        timestamp = struct.pack("!II", int(time.time()) + 2208988800, secrets.randbits(32))
        client.sendto(b"\x23" + bytes(39) + timestamp, (address, 123))
        packet, _ = client.recvfrom(512)
        assert len(packet) >= 48 and packet[0] & 7 == 4
        assert packet[24:32] == timestamp and 1 <= packet[1] <= 15, packet[:4]
print("PASS: client HTTP/HTTPS, full iPXE TFTP transfer and local NTP over IPv4/IPv6")

mac = bytes.fromhex(Path("/sys/class/net/client0/address").read_text().strip().replace(":", ""))

def options4(payload):
    result = {}
    offset = 240
    while offset < len(payload):
        code = payload[offset]
        offset += 1
        if code == 255:
            break
        if code == 0:
            continue
        length = payload[offset]
        offset += 1
        assert offset + length <= len(payload)
        result[code] = payload[offset:offset + length]
        offset += length
    return result

transaction = secrets.randbits(32)
bootp = struct.pack("!BBBBIHH4s4s4s4s16s64s128s", 1, 1, 6, 0, transaction, 0, 0x8000,
                    bytes(4), bytes(4), bytes(4), bytes(4), mac, bytes(64), bytes(128))
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
    client.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    client.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b"client0\0")
    client.settimeout(5)
    client.bind(("0.0.0.0", 68))
    def exchange4(message, expected):
        client.sendto(bootp + b"\x63\x82\x53\x63" + message + b"\xff", ("255.255.255.255", 67))
        for _ in range(10):
            payload, _ = client.recvfrom(4096)
            if payload[4:8] == struct.pack("!I", transaction):
                options = options4(payload)
                assert options[53] == bytes([expected])
                return payload, options
        raise AssertionError("No matching DHCPv4 reply")
    identity = b"\x3d\x07\x01" + mac
    offer, options = exchange4(b"\x35\x01\x01" + identity, 2)
    address = offer[16:20]
    assert int(ipaddress.IPv4Address("192.0.2.100")) <= int(ipaddress.IPv4Address(address)) <= int(ipaddress.IPv4Address("192.0.2.120"))
    ack, options = exchange4(b"\x35\x01\x03\x32\x04" + address + b"\x36\x04" + options[54] + identity, 5)
    assert ack[16:20] == address and ack[20:24] == socket.inet_aton("192.0.2.1")
    assert ack[108:236].rstrip(b"\0") == b"ipxe.efi"
print("PASS: client DHCPv4 discover/request receives a lease and PXE boot settings")

def option6(code, value):
    return struct.pack("!HH", code, len(value)) + value

def options6(payload):
    result = {}
    offset = 0
    while offset < len(payload):
        code, length = struct.unpack("!HH", payload[offset:offset + 4])
        offset += 4
        assert offset + length <= len(payload)
        result[code] = payload[offset:offset + length]
        offset += length
    return result

interface = socket.if_nametoindex("client0")
with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM) as client:
    client.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b"client0\0")
    client.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, interface)
    client.settimeout(5)
    client.bind(("::", 546))
    def exchange6(message, expected):
        transaction6 = secrets.token_bytes(3)
        client.sendto(message[:1] + transaction6 + message[1:], ("ff02::1:2", 547, 0, interface))
        for _ in range(10):
            payload, _ = client.recvfrom(4096)
            if payload[1:4] == transaction6:
                assert payload[0] == expected, payload[0]
                return options6(payload[4:])
        raise AssertionError("No matching DHCPv6 reply")
    identity6 = option6(1, struct.pack("!HH", 3, 1) + mac)
    requested = option6(6, struct.pack("!HH", 23, 59))
    advertised = exchange6(b"\x01" + identity6 + option6(3, struct.pack("!III", 42, 0, 0)) + requested, 2)
    reply = exchange6(b"\x03" + identity6 + option6(2, advertised[2]) + option6(3, advertised[3]) + requested, 7)
    leased = ipaddress.IPv6Address(options6(reply[3][12:])[5][:16])
    assert ipaddress.IPv6Address("2001:db8:1::3ff") <= leased <= ipaddress.IPv6Address("2001:db8:1::461")
    assert reply[23] == socket.inet_pton(socket.AF_INET6, "2001:db8:1::1")
    assert reply[59] == b"tftp://[2001:db8:1::1]/ipxe.efi"
print("PASS: client DHCPv6 solicit/request receives a lease, DNS and boot URL")

with socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6) as client:
    client.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b"client0\0")
    client.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_IF, interface)
    client.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_MULTICAST_HOPS, 255)
    client.settimeout(10)
    client.sendto(struct.pack("!BBHI", 133, 0, 0, 0), ("ff02::2", 0, 0, interface))
    for _ in range(20):
        payload, _ = client.recvfrom(4096)
        if payload[0] != 134:
            continue
        assert payload[5] & 0xc0 == 0xc0
        prefix_seen = False
        offset = 16
        while offset < len(payload):
            code, units = payload[offset:offset + 2]
            assert units > 0 and offset + units * 8 <= len(payload)
            option = payload[offset:offset + units * 8]
            if code == 3:
                assert option[2] == 64 and option[16:32] == socket.inet_pton(socket.AF_INET6, "2001:db8:1::")
                prefix_seen = True
            offset += units * 8
        assert prefix_seen
        break
    else:
        raise AssertionError("No router advertisement")
print("PASS: client router solicitation receives managed DHCPv6 flags and lab prefix")
CLIENT
}

check_engine_iso() (
    local expected="$1" client_dir protocol options server checksum
    client_dir=$(mktemp -d /tmp/engine-nfs.XXXXXXXX)
    cleanup_iso_client() {
        local status=$?
        trap - EXIT
        if mountpoint -q "$client_dir"; then
            umount "$client_dir" || exit 1
        fi
        rmdir "$client_dir"
        exit "$status"
    }
    trap cleanup_iso_client EXIT
    for protocol in v4-ipv4 v4-ipv6 v3-ipv4; do
        case "$protocol" in
            v4-ipv4) options=vers=4.1,proto=tcp; server=192.0.2.1 ;;
            v4-ipv6) options=vers=4.1,proto=tcp6; server='[2001:db8:1::1]' ;;
            v3-ipv4) options=vers=3,nolock,proto=tcp; server=192.0.2.1 ;;
        esac
        timeout -k 5 20 mount -t nfs -o "ro,$options,soft,timeo=20,retrans=2,retry=0" \
            "$server:/tux2lab-data" "$client_dir"
        checksum=$(timeout -k 5 60 sha256sum "$client_dir/os-repos/dynamic/images/install.img")
        [[ "${checksum%% *}" == "$expected" ]]
        umount "$client_dir"
        printf 'PASS: propagated ISO full installer checksum over %s\n' "$protocol"
    done
    python3 - "$expected" <<'ISOCLIENT'
import hashlib
import http.client
import ssl
import sys

context = ssl.create_default_context(cafile="/tux2lab-data/lab-config/certs/tux2lab-nginx-selfsigned.crt")
for address in ("192.0.2.1", "2001:db8:1::1"):
    for connection in (http.client.HTTPConnection(address, 80, timeout=10),
                       http.client.HTTPSConnection(address, 443, context=context, timeout=10)):
        connection.request("GET", "/os-repos/dynamic/images/install.img")
        response = connection.getresponse()
        assert response.status == 200
        digest = hashlib.sha256()
        for chunk in iter(lambda: response.read(1048576), b""):
            digest.update(chunk)
        assert digest.hexdigest() == sys.argv[1]
        connection.close()
print("PASS: propagated ISO full installer checksum over IPv4/IPv6 HTTP and HTTPS")
ISOCLIENT
)

run_engine_tests() (
    local image="$1" iso_mount="${2:-}" scratch container_name engine_created=false data_mounted=false attempt
    local iso_source iso_checksum iso_hash round filesystem engine_pid exit_code rootfs=''
    local inject_failure="${3:-false}" observer_name observer_created=false
    sudo podman image inspect "$image" >/dev/null
    if [[ -n "$iso_mount" ]]; then
        [[ "$(findmnt -n -o FSTYPE --mountpoint "$iso_mount")" == iso9660 ]]
        [[ ",$(findmnt -n -o OPTIONS --mountpoint "$iso_mount")," == *,ro,* ]]
        iso_source=$(findmnt -n -o SOURCE --mountpoint "$iso_mount")
        [[ "$iso_source" =~ ^/dev/loop[0-9]+$ ]]
        iso_checksum=$(sha256sum "$iso_mount/images/install.img")
        iso_hash="${iso_checksum%% *}"
    fi
    scratch=$(sudo mktemp -d /tux2lab-data/.engine-test.XXXXXXXX)
    container_name="tux2lab-engine-test-${scratch##*.}"
    observer_name="${container_name}-observer"
    cleanup_engine_test() {
        local status=$?
        trap - EXIT INT TERM
        if "$engine_created"; then
            if [[ "$status" != 0 ]]; then sudo podman logs --tail 120 "$container_name" || true; fi
            if ! sudo podman stop --time 30 "$container_name" >/dev/null; then
                printf 'Retained test container and data: %s %s\n' "$container_name" "$scratch" >&2
                exit 1
            fi
        fi
        if "$observer_created"; then
            sudo podman stop --time 5 "$observer_name" >/dev/null || exit 1
            sudo podman rm "$observer_name" >/dev/null || exit 1
        fi
        if "$engine_created"; then
            remove_engine_container "$container_name" >/dev/null || exit 1
        elif [[ -n "$rootfs" ]]; then
            remove_engine_rootfs "$rootfs" || exit 1
        fi
        if mountpoint -q "$scratch/data/os-repos/dynamic"; then
            sudo umount "$scratch/data/os-repos/dynamic" || exit 1
        fi
        if "$data_mounted"; then sudo umount "$scratch/data" || exit 1; fi
        sudo rm -rf -- "$scratch"
        exit "$status"
    }
    trap cleanup_engine_test EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    sudo chmod 755 "$scratch"
    sudo mkdir -p "$scratch/data" "$scratch/state"
    sudo podman run --rm --network=host -e TUX2LAB_TEST_FIXTURES=1 -v "$PROJECT_ROOT:/tux2lab:ro" \
        -v "$scratch/data:/tux2lab-data" --entrypoint /bin/bash "$image" \
        -c 'apk add --no-cache jq openssl >/dev/null && bash /tux2lab/container/run-engine-tests.sh --fixtures'
    sudo mount --bind "$scratch/data" "$scratch/data"
    data_mounted=true
    sudo mount --make-shared "$scratch/data"
    rootfs=$(prepare_engine_rootfs "$image")
    sudo podman create --name "$container_name" --network=none --privileged --stop-timeout=30 \
        --hostname engine.integration.test \
        --label "io.tux2lab.rootfs=$rootfs" \
        --add-host engine.integration.test:192.0.2.1 --add-host client.integration.test:192.0.2.2 \
        --add-host engine6.integration.test:2001:db8:1::1 --add-host client6.integration.test:2001:db8:1::2 \
        -e "TUX2LAB_HOST_NETNS=$(stat -Lc %i /proc/self/ns/net)" \
        -e TUX2LAB_BRIDGE_IP=192.0.2.1 -e TUX2LAB_BRIDGE_IPV6=2001:db8:1::1 -e TUX2LAB_BRIDGE_IF=labbr0 \
        -v "$PROJECT_ROOT:/tux2lab:ro" \
        -v "$scratch/data:/tux2lab-data:ro,rslave" -v "$scratch/state:/var/lib/nfs" \
        -v "$scratch/data/logs:/tux2lab-data/logs" \
        -v "$scratch/data/nginx/stream.d:/tux2lab-data/nginx/stream.d" \
        -v "$scratch/data/kea/leases:/var/lib/kea" \
        --rootfs "$rootfs" /bin/bash /tux2lab/container/run-engine-tests.sh --boot >/dev/null
    engine_created=true
    sudo podman start "$container_name" >/dev/null
    for ((attempt = 0; attempt < 45; attempt++)); do
        [[ "$(sudo podman inspect "$container_name" --format '{{.State.Running}}')" == true ]] || return 1
        if sudo podman exec "$container_name" bash /tux2lab/container/run-engine-tests.sh --ready >/dev/null 2>&1; then
            printf 'PASS: complete engine entrypoint starts every service with production data mounts\n'
            break
        fi
        sleep 1
    done
    [[ "$attempt" -lt 45 ]] || { printf 'FAIL: complete engine startup timed out\n' >&2; return 1; }
    sudo podman exec "$container_name" timeout 90 ip netns exec client \
        bash /tux2lab/container/run-engine-tests.sh --clients
    sudo podman exec "$container_name" python3 -c '
import base64, json, urllib.request
request = urllib.request.Request("http://127.0.0.1:8000/", data=json.dumps({"command": "status-get", "service": ["dhcp4", "dhcp6"]}).encode(), headers={"Content-Type": "application/json", "Authorization": "Basic " + base64.b64encode(b"kea-api:kea-api-password").decode()})
with urllib.request.urlopen(request, timeout=5) as response:
    results = json.load(response)
assert len(results) == 2 and all(result["result"] == 0 for result in results)
print("PASS: authenticated Kea control agent reaches both DHCP daemons")'
    if [[ -n "$iso_mount" ]]; then
        engine_pid=$(sudo podman inspect "$container_name" --format '{{.State.Pid}}')
        for round in 1 2; do
            sudo mount -t iso9660 -o ro "$iso_source" "$scratch/data/os-repos/dynamic"
            filesystem=$(sudo podman exec "$container_name" stat -f -c %T /tux2lab-data/os-repos/dynamic)
            [[ "$filesystem" == isofs ]] || {
                printf 'FAIL: mounted ISO reports filesystem %s inside the engine\n' "$filesystem" >&2
                return 1
            }
            sudo podman exec "$container_name" timeout -k 5 180 ip netns exec client \
                bash /tux2lab/container/run-engine-tests.sh --iso-client "$iso_hash"
            sudo podman exec "$container_name" exportfs -f
            sudo umount "$scratch/data/os-repos/dynamic"
            filesystem=$(sudo podman exec "$container_name" stat -f -c %T /tux2lab-data/os-repos/dynamic)
            [[ "$filesystem" != isofs ]] || {
                printf 'FAIL: unmounted ISO remains visible inside the engine\n' >&2
                return 1
            }
            sudo podman exec "$container_name" test ! -e /tux2lab-data/os-repos/dynamic/images/install.img
            [[ "$(sudo podman inspect "$container_name" --format '{{.State.Pid}}')" == "$engine_pid" ]]
            sudo podman exec "$container_name" bash /tux2lab/container/run-engine-tests.sh --ready
            printf 'PASS: ISO mount/unmount propagation round %s without engine restart\n' "$round"
        done
    fi
    sudo podman create --name "$observer_name" --network="container:$container_name" --privileged \
        --entrypoint /bin/bash "$image" \
        -c 'trap "exit 0" TERM; while :; do sleep 3600 & wait "$!"; done' >/dev/null
    observer_created=true
    sudo podman start "$observer_name" >/dev/null
    sudo podman exec "$observer_name" mount -t nfsd nfsd /proc/fs/nfsd
    [[ "$(sudo podman exec "$observer_name" cat /proc/fs/nfsd/threads)" == 8 ]]
    if "$inject_failure"; then
        sudo podman exec "$container_name" pkill -KILL -x rpc.mountd
        exit_code=$(sudo timeout -k 5 45 podman wait "$container_name")
        [[ "$exit_code" == 1 ]]
        printf 'PASS: mountd failure makes the complete engine exit with status 1\n'
    else
        sudo podman stop --time 30 "$container_name" >/dev/null
        [[ "$(sudo podman inspect "$container_name" --format '{{.State.ExitCode}}')" == 143 ]]
        printf 'PASS: complete engine handles SIGTERM without forced termination\n'
    fi
    sudo podman exec "$observer_name" bash -c '
        set -euo pipefail
        [[ "$(cat /proc/fs/nfsd/threads)" == 0 ]]
        exports=$(cat /proc/fs/nfs/exports)
        [[ "$exports" == "# Version "* && "$exports" != *$'"'"'\n/'"'"'* ]]
        listeners=$(ss -H -lntup)
        tables=$(nft list tables)
        [[ -z "$listeners" && -z "$tables" ]]
    '
    printf 'PASS: retained test namespace has no NFS threads, exports, service listeners or firewall table\n'
)

case "${1:-}" in
    --fixtures) generate_engine_fixtures ;;
    --boot) boot_test_engine ;;
    --clients) check_engine_clients ;;
    --iso-client) check_engine_iso "$2" ;;
    --ready)
        bash /usr/local/lib/tux2lab/nfs-service.sh check
        for process in named kea-dhcp4 kea-dhcp6 kea-ctrl-agent nginx in.tftpd chronyd radvd; do
            pgrep -f "^(nginx: master process )?/usr/sbin/${process//./\\.} " >/dev/null
        done ;;
    --startup)
        [[ $# == 2 ]] || exit 2
        run_engine_tests "$2" ;;
    --run)
        [[ $# == 3 ]] || exit 2
        run_engine_tests "$2" "$3" ;;
    --failure)
        [[ $# == 2 ]] || exit 2
        run_engine_tests "$2" '' true ;;
    *) printf 'Usage: bash container/run-engine-tests.sh --startup IMAGE | --run IMAGE ISO_MOUNT | --failure IMAGE\n' >&2; exit 2 ;;
esac