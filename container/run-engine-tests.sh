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
CLIENT
    check_engine_dhcp
}

check_engine_dhcp() {
    python3 - <<'DHCPCLIENT'
import ipaddress
import json
from pathlib import Path
import secrets
import socket
import struct
import subprocess

configuration = json.loads(Path("/tux2lab-data/lab-config/lab_environment.json").read_text())
network = configuration["network"]
server4 = network["ipv4"]["address"]
server6 = network["ipv6"]["address"]
prefix6 = ipaddress.IPv6Network(network["ipv6"]["ula_subnet"])
domain = configuration["lab"]["domain"]
encoded_domain = b"".join(bytes([len(label)]) + label.encode("ascii") for label in domain.split(".")) + b"\0"

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
with socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0800)) as receiver, \
        socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
    receiver.bind(("client0", 0))
    receiver.settimeout(5)
    client.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    client.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, b"client0\0")
    client.settimeout(5)
    client.bind(("0.0.0.0", 68))
    def exchange4(message, expected):
        client.sendto(bootp + b"\x63\x82\x53\x63" + message + b"\xff", ("255.255.255.255", 67))
        for _ in range(10):
            frame, _ = receiver.recvfrom(4096)
            if len(frame) < 42 or frame[14] >> 4 != 4 or frame[23] != 17:
                continue
            udp_offset = 14 + (frame[14] & 15) * 4
            if udp_offset < 34 or len(frame) < udp_offset + 8:
                continue
            source_port, destination_port, udp_length = struct.unpack("!HHH", frame[udp_offset:udp_offset + 6])
            if source_port != 67 or destination_port != 68:
                continue
            assert udp_length >= 248 and udp_offset + udp_length <= len(frame)
            payload = frame[udp_offset + 8:udp_offset + udp_length]
            if payload[4:8] == struct.pack("!I", transaction):
                assert payload[0] == 2 and payload[28:34] == mac and payload[236:240] == b"\x63\x82\x53\x63"
                options = options4(payload)
                assert options[53] == bytes([expected])
                return payload, options
        raise AssertionError("No matching DHCPv4 reply")
    identity = b"\x3d\x07\x01" + mac
    requested4 = b"\x37\x05\x01\x03\x06\x0f\x77"
    offer, options = exchange4(b"\x35\x01\x01" + identity + requested4, 2)
    address = offer[16:20]
    assert ipaddress.IPv4Address(network["ipv4"]["dhcp_range_start"]) <= ipaddress.IPv4Address(address) <= ipaddress.IPv4Address(network["ipv4"]["dhcp_range_end"])
    assert options[54] == socket.inet_aton(server4)
    ack, options = exchange4(b"\x35\x01\x03\x32\x04" + address + b"\x36\x04" + options[54] + identity + requested4, 5)
    assert ack[16:20] == address
    leased4 = str(ipaddress.IPv4Address(address))
    subprocess.run(["ip", "addr", "add", leased4 + "/" + str(network["ipv4"]["prefix"]),
                    "dev", "client0"], check=True)
    print(json.dumps({"event": "lease4", "address": leased4, "mac": mac.hex(":")}), flush=True)
    try:
        assert ack[20:24] == socket.inet_aton(server4)
        assert ack[108:236].rstrip(b"\0") == b"ipxe.efi"
        assert options[1] == socket.inet_aton(network["ipv4"]["netmask"])
        assert options[3] == socket.inet_aton(network["ipv4"]["gateway"])
        assert options[6] == socket.inet_aton(server4)
        assert options[15] == domain.encode("ascii") and options[119] == encoded_domain
    finally:
        release4 = bytearray(bootp)
        release4[12:16] = address
        release4[10:12] = bytes(2)
        client.sendto(release4 + b"\x63\x82\x53\x63\x35\x01\x07\x36\x04" +
                      socket.inet_aton(server4) + identity + b"\xff", (server4, 67))
print("PASS: client DHCPv4 lease, network options, DNS/domain and PXE settings match lab configuration")

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
    requested = option6(6, struct.pack("!HHH", 23, 24, 59))
    advertised = exchange6(b"\x01" + identity6 + option6(3, struct.pack("!III", 42, 0, 0)) + requested, 2)
    reply = exchange6(b"\x03" + identity6 + option6(2, advertised[2]) + option6(3, advertised[3]) + requested, 7)
    try:
        assert reply[1] == identity6[4:] and reply[2] == advertised[2]
        leased = ipaddress.IPv6Address(options6(reply[3][12:])[5][:16])
        print(json.dumps({"event": "lease6", "address": str(leased), "duid": identity6[4:].hex(":")}), flush=True)
        assert prefix6.network_address + 0x3ff <= leased <= prefix6.network_address + 0x461
        assert reply[23] == socket.inet_pton(socket.AF_INET6, server6)
        assert reply[24] == encoded_domain
        assert reply[59] == ("tftp://[" + server6 + "]/ipxe.efi").encode("ascii")
    finally:
        released = exchange6(b"\x08" + identity6 + option6(2, advertised[2]) + option6(3, reply[3]), 7)
        assert released.get(13, b"\0\0")[:2] == b"\0\0", "DHCPv6 release rejected"
print("PASS: client DHCPv6 lease, DNS/domain and boot URL match lab configuration")

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
        dns_seen = False
        domain_seen = False
        offset = 16
        while offset < len(payload):
            code, units = payload[offset:offset + 2]
            assert units > 0 and offset + units * 8 <= len(payload)
            option = payload[offset:offset + units * 8]
            if code == 3:
                assert option[2] == prefix6.prefixlen and option[16:32] == prefix6.network_address.packed
                assert option[3] & 0xc0 == 0x80
                prefix_seen = True
            elif code == 25:
                assert option[8:] == socket.inet_pton(socket.AF_INET6, server6)
                dns_seen = True
            elif code == 31:
                assert option[8:].rstrip(b"\0") == encoded_domain.rstrip(b"\0")
                domain_seen = True
            offset += units * 8
        assert prefix_seen and dns_seen and domain_seen
        break
    else:
        raise AssertionError("No router advertisement")
print("PASS: router advertisement carries managed flags, lab prefix and DNS/domain")
DHCPCLIENT
}

run_deployed_dhcp_test() (
    local expected_host="$1" evidence="$2" bridge scratch namespace peer identity guests
    local namespace_created=false peer_created=false
    [[ "$(hostname -f)" == "$expected_host" && "$expected_host" != localhost ]] || return 1
    [[ -d "$evidence" && "$(readlink -e "$evidence")" == "$evidence" && "$evidence" != /tux2lab-data* ]] || return 1
    source "$PROJECT_ROOT/shared-functions/container-nfs.sh"
    require_container_nfs_engine tux2lab-engine
    check_engine_nfs tux2lab-engine
    guests=$(sudo -n virsh list --name) || return 1
    [[ -z "$guests" ]] || return 1
    bridge=$(jq -er '.network.bridge_interface' /tux2lab-data/lab-config/lab_environment.json)
    [[ "$bridge" =~ ^[a-zA-Z0-9_-]{1,15}$ && "$bridge" != lo ]] || return 1
    ip -d -j link show dev "$bridge" | jq -e 'length == 1 and .[0].linkinfo.info_kind == "bridge"' >/dev/null
    ip -d -j link show master "$bridge" | jq -e 'all(.[]; .linkinfo.info_kind == "dummy")' >/dev/null
    jq '{network, lab: {domain: .lab.domain}}' /tux2lab-data/lab-config/lab_environment.json > "$evidence/network.json"
    identity=$(sudo -n podman inspect tux2lab-engine --format '{{.Id}} {{.State.Pid}}')
    scratch=$(mktemp -d /tmp/tux2lab-dhcp.XXXXXXXX)
    namespace="tux2lab-dhcp-${scratch##*.}"
    peer="t2d${scratch##*.}"
    cleanup_deployed_dhcp() {
        local status=$? processes
        trap - EXIT
        if "$namespace_created"; then
            processes=$(sudo -n ip netns pids "$namespace") || {
                printf 'Cannot inspect client processes; retained namespace %s and %s\n' "$namespace" "$scratch" >&2
                exit 1
            }
            [[ -z "$processes" ]] || {
                printf 'Client processes remain; retained namespace %s and %s\n' "$namespace" "$scratch" >&2
                exit 1
            }
        fi
        if "$peer_created"; then sudo -n ip link delete "$peer" || exit 1; fi
        if "$namespace_created"; then sudo -n ip netns delete "$namespace" || exit 1; fi
        rmdir "$scratch" || exit 1
        exit "$status"
    }
    trap cleanup_deployed_dhcp EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    sudo -n ip netns add "$namespace"
    namespace_created=true
    sudo -n ip link add "$peer" type veth peer name client0 netns "$namespace"
    peer_created=true
    sudo -n ip link set "$peer" master "$bridge"
    sudo -n ip netns exec "$namespace" ip link set lo up
    sudo -n ip netns exec "$namespace" ip link set client0 addrgenmode none
    sudo -n ip netns exec "$namespace" ip -6 addr add "fe80::$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2):$(openssl rand -hex 2)/64" dev client0 nodad
    sudo -n ip link set "$peer" up
    sudo -n ip netns exec "$namespace" ip link set client0 up
    python3 - "$peer" <<'BRIDGEREADY' > "$evidence/bridge-ready.log"
import json
import select
import socket
import subprocess
import sys
import time

deadline = time.monotonic() + 45
with socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, socket.NETLINK_ROUTE) as events:
    events.bind((0, 1))
    while True:
        ports = json.loads(subprocess.check_output(["bridge", "-j", "link", "show", "dev", sys.argv[1]], text=True))
        assert len(ports) == 1, "Test bridge port disappeared"
        print("Bridge port state: " + ports[0]["state"], flush=True)
        if ports[0]["state"] == "forwarding":
            break
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([events], [], [], remaining)[0], "Bridge port never reached forwarding"
        events.recv(65536)
print("PASS: test port reached bridge forwarding state")
BRIDGEREADY
    cat "$evidence/bridge-ready.log"
    if ! sudo -n timeout -k 5 150 ip netns exec "$namespace" bash "$PROJECT_ROOT/container/run-engine-tests.sh" --dhcp-client \
        2>&1 | tee "$evidence/client.log"; then
        return 1
    fi
    if [[ "${3:-false}" == true ]]; then
        if ! sudo -n timeout -k 5 600 ip netns exec "$namespace" unshare --mount --propagation private \
            bash "$PROJECT_ROOT/container/run-engine-tests.sh" --deployed-nfs-client 2>&1 | tee "$evidence/nfs-client.log"; then
            return 1
        fi
    fi
    [[ "$(sudo -n podman inspect tux2lab-engine --format '{{.Id}} {{.State.Pid}}')" == "$identity" ]]
    check_engine_nfs tux2lab-engine
    printf 'PASS: deployed DHCP/RA transactions completed without restarting the engine\n'
)

check_deployed_nfs_client() {
    local ipv4 ipv6 client_address checksum
    ip link show dev client0 >/dev/null
    ipv4=$(jq -er '.network.ipv4.address' /tux2lab-data/lab-config/lab_environment.json)
    ipv6=$(jq -er '.network.ipv6.address' /tux2lab-data/lab-config/lab_environment.json)
    client_address=$(python3 - <<'CLIENTADDRESS'
import ipaddress
import json
from pathlib import Path
network = json.loads(Path('/tux2lab-data/lab-config/lab_environment.json').read_text())['network']['ipv6']
prefix = ipaddress.IPv6Network(network['ula_subnet'])
print(str(prefix.network_address + 2) + '/' + str(prefix.prefixlen))
CLIENTADDRESS
    )
    ip -6 addr add "$client_address" dev client0 nodad
    checksum=$(sha256sum /tux2lab-data/os-repos/almalinux/9/images/install.img)
    bash "$PROJECT_ROOT/container/run-migration-tests.sh" --read-client "$ipv4" "$ipv6" "${checksum%% *}"
}

restore_deployed_firewall() {
    local evidence="$1" engine_id
    [[ "$EUID" == 0 && "$evidence" == /home/*/nfs-firewall-validation.* ]] || return 1
    [[ "$(readlink -e "$evidence")" == "$evidence" ]] || return 1
    [[ "$(cat "$evidence/host")" == "$(hostname -f)" ]] || return 1
    [[ -s "$evidence/firewalld-original.tar" ]] || return 1
    engine_id=$(podman inspect tux2lab-engine --format '{{.Id}}') || return 1
    [[ "$engine_id" == "$(cat "$evidence/engine-id")" ]] || return 1
    systemctl stop firewalld.service || return 1
    if [[ ! -e "$evidence/firewalld-tested" ]]; then
        mv /etc/firewalld "$evidence/firewalld-tested" || return 1
    fi
    tar -xpf "$evidence/firewalld-original.tar" -C / || return 1
    [[ "$(systemctl show firewalld.service -p UnitFileState --value)" == disabled ]] || return 1
    source "$PROJECT_ROOT/shared-functions/container-nfs.sh"
    if [[ "$(podman inspect tux2lab-engine --format '{{.State.Running}}')" != true ]]; then
        podman start tux2lab-engine || return 1
    fi
    wait_for_engine_nfs tux2lab-engine || return 1
    touch "$evidence/restored" || return 1
    printf 'PASS: original disabled firewall configuration and engine readiness restored\n'
}

run_deployed_firewall_phase() (
    local expected_host="$1" evidence="$2" phase="$3" recovery bridge guests
    [[ "$EUID" == 0 && "$(hostname -f)" == "$expected_host" && "$expected_host" != localhost ]]
    [[ "$evidence" == /home/*/nfs-firewall-validation.* && "$(readlink -e "$evidence")" == "$evidence" ]]
    source "$PROJECT_ROOT/shared-functions/container-nfs.sh"
    source "$PROJECT_ROOT/common-utils/color-functions.sh"
    source "$PROJECT_ROOT/shared-functions/bridge-firewall.sh"
    check_engine_nfs tux2lab-engine
    bridge=$(jq -er '.network.bridge_interface' /tux2lab-data/lab-config/lab_environment.json)
    guests=$(virsh list --name)
    [[ -z "$guests" ]]
    ip -d -j link show dev "$bridge" | jq -e 'length == 1 and .[0].linkinfo.info_kind == "bridge"' >/dev/null
    ip -d -j link show master "$bridge" | jq -e 'all(.[]; .linkinfo.info_kind == "dummy")' >/dev/null
    recovery="tux2lab-firewall-recovery-${evidence##*.}"
    if [[ "$phase" == start ]]; then
        [[ ! -e "$evidence/host" && "$(readlink -e /etc/firewalld)" == /etc/firewalld ]]
        [[ "$(systemctl show firewalld.service -p ActiveState --value)" == inactive ]]
        [[ "$(systemctl show firewalld.service -p UnitFileState --value)" == disabled ]]
        [[ "$(firewall-offline-cmd --get-default-zone)" == public ]]
        firewall-offline-cmd --zone=public --query-service=ssh
        hostname -f > "$evidence/host"
        podman inspect tux2lab-engine --format '{{.Id}}' > "$evidence/engine-id"
        tar -cpf "$evidence/firewalld-original.tar" -C / etc/firewalld
        chmod 600 "$evidence/firewalld-original.tar"
        systemd-run --unit="$recovery" --on-active=15m --timer-property=AccuracySec=1s \
            /bin/bash "$PROJECT_ROOT/container/run-engine-tests.sh" --restore-deployed-firewall "$evidence"
    else
        [[ "$(cat "$evidence/host")" == "$expected_host" && ! -e "$evidence/restored" ]]
        [[ "$(podman inspect tux2lab-engine --format '{{.Id}}')" == "$(cat "$evidence/engine-id")" ]]
    fi
    recover_failure() {
        local status=$?
        trap - EXIT
        if [[ "$status" != 0 ]]; then
            restore_deployed_firewall "$evidence" || exit 1
            systemctl stop "$recovery.timer" || exit 1
        fi
        exit "$status"
    }
    trap recover_failure EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    case "$phase" in
        start)
            systemctl start firewalld.service
            open_bridge_firewall "$bridge" ;;
        reload) firewall-cmd --reload ;;
        restart) systemctl restart firewalld.service ;;
        restore)
            restore_deployed_firewall "$evidence"
            systemctl stop "$recovery.timer"
            return 0 ;;
        *) return 2 ;;
    esac
    systemctl is-active --quiet firewalld.service
    firewall-cmd --zone=public --query-service=ssh
    firewall-cmd --get-active-zones
    firewall-cmd --zone=trusted --query-interface="$bridge"
    check_engine_nfs tux2lab-engine
    printf 'PASS: firewalld %s preserves SSH allowance, trusted bridge and exact NFS rules\n' "$phase"
)

run_deployed_helper_audit() (
    local expected_host="$1" evidence="$2" instance engine_id guests status stats
    [[ "$EUID" == 0 && "$expected_host" != localhost && "$(hostname -f)" == "$expected_host" ]]
    [[ "$evidence" == /home/*/nfs-helper-validation.* && "$(readlink -e "$evidence")" == "$evidence" ]]
    source "$PROJECT_ROOT/shared-functions/container-nfs.sh"
    check_engine_nfs tux2lab-engine
    guests=$(virsh list --name)
    [[ -z "$guests" ]]
    container_nfs_require_no_client_mounts
    engine_id=$(podman inspect tux2lab-engine --format '{{.Id}}')
    instance="/sys/kernel/tracing/instances/tux2lab-${evidence##*.}"
    mkdir "$instance"
    cleanup_helper_audit() {
        local result=$?
        trap - EXIT
        printf '0\n' > "$instance/tracing_on" || exit 1
        rmdir "$instance" || exit 1
        [[ "$(podman inspect tux2lab-engine --format '{{.Id}}')" == "$engine_id" ]] || exit 1
        if [[ "$(podman inspect tux2lab-engine --format '{{.State.Running}}')" != true ]]; then
            podman start tux2lab-engine || exit 1
        fi
        wait_for_engine_nfs tux2lab-engine || exit 1
        exit "$result"
    }
    trap cleanup_helper_audit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf '0\n' > "$instance/tracing_on"
    printf 'call_usermodehelper_setup\ncall_usermodehelper_exec\n' > "$instance/set_ftrace_filter"
    printf 'function\n' > "$instance/current_tracer"
    printf 'filename ~ "*nfs*" || filename ~ "*modprobe*" || filename ~ "*request-key*" || filename ~ "*rpc.*"\n' \
        > "$instance/events/sched/sched_process_exec/filter"
    printf '1\n' > "$instance/events/sched/sched_process_exec/enable"
    printf '1\n' > "$instance/events/module/module_request/enable"
    printf '1\n' > "$instance/tracing_on"
    status=0
    keyctl session - keyctl request2 user "debug:tux2lab-${evidence##*.}" negate @s \
        > "$evidence/positive-control-command.log" 2>&1 || status=$?
    [[ "$status" == 1 ]]
    printf '0\n' > "$instance/tracing_on"
    cat "$instance/trace" > "$evidence/positive-control.trace"
    grep -q 'call_usermodehelper_setup' "$evidence/positive-control.trace"
    grep -q 'sched_process_exec: filename=.*/request-key ' "$evidence/positive-control.trace"
    printf 'PASS: positive control captured native request-key kernel upcall and execution\n'
    printf '\n' > "$instance/trace"
    printf '1\n' > "$instance/tracing_on"
    stop_engine_nfs tux2lab-engine
    podman start tux2lab-engine
    wait_for_engine_nfs tux2lab-engine
    mkdir "$evidence/network-client"
    run_deployed_dhcp_test "$expected_host" "$evidence/network-client" true
    printf '0\n' > "$instance/tracing_on"
    cat "$instance/trace" > "$evidence/workload.trace"
    for stats in "$instance"/per_cpu/cpu*/stats; do
        cat "$stats" >> "$evidence/buffer-stats.log"
        awk '$1 == "overrun:" && $2 != 0 {exit 1}' "$stats"
    done
    podman top tux2lab-engine hpid comm | grep -E 'HPID|rpc|nfs|mountd' > "$evidence/engine-helper-pids.log"
    printf 'PASS: traced engine restart and real bridge NFS reads without trace-buffer overruns\n'
)

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
    sudo podman run --rm --network=host --security-opt label=disable \
        -e TUX2LAB_TEST_FIXTURES=1 -v "$PROJECT_ROOT:/tux2lab:ro" \
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
        -v /dev:/dev:ro \
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

run_recovery_client() (
    local server="$1" relative_file="$2" client_mount
    [[ "$relative_file" != /* && "/$relative_file/" != */../* ]] || return 1
    [[ "$(stat -Lc %i /proc/self/ns/mnt)" != "$(stat -Lc %i /proc/1/ns/mnt)" ]] || return 1
    client_mount=$(mktemp -d /tmp/tux2lab-recovery-client.XXXXXXXX)
    cleanup_recovery_client() {
        local status=$?
        trap - EXIT
        if mountpoint -q "$client_mount"; then umount "$client_mount" || exit 1; fi
        rmdir "$client_mount"
        exit "$status"
    }
    trap cleanup_recovery_client EXIT
    timeout -k 5 25 mount -t nfs -o ro,vers=4.1,proto=tcp,hard,timeo=10,retrans=2,retry=0 \
        "$server:/tux2lab-data" "$client_mount"
    python3 /dev/fd/3 "$client_mount/$relative_file" 3<<'RECOVERYCLIENT'
import hashlib
import json
import mmap
import os
import sys

block_size = 1024 * 1024
descriptor = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECT)
try:
    with mmap.mmap(-1, block_size) as buffer:
        count = os.readv(descriptor, [buffer])
        assert count == block_size
        expected = hashlib.sha256(buffer).hexdigest()
        print(json.dumps({"event": "ready", "sha256": expected}), flush=True)
        assert sys.stdin.readline().strip() == "read"
        os.lseek(descriptor, 0, os.SEEK_SET)
        print(json.dumps({"event": "reading"}), flush=True)
        count = os.readv(descriptor, [buffer])
        assert count == block_size
        actual = hashlib.sha256(buffer).hexdigest()
        assert actual == expected
        print(json.dumps({"event": "recovered", "sha256": actual}), flush=True)
        assert sys.stdin.readline().strip() == "close"
finally:
    os.close(descriptor)
RECOVERYCLIENT
)

run_deployed_cli_recovery_test() (
    local expected_host="$1" evidence="$2" identity root owner held listeners status guests clients
    local owner_held=false restart_needed=false
    [[ "$EUID" != 0 && "$(hostname -f)" == "$expected_host" && "$expected_host" != localhost ]] || return 1
    [[ -d "$evidence" && "$(readlink -e "$evidence")" == "$evidence" && "$evidence" != /tux2lab-data* ]] || return 1
    source "$PROJECT_ROOT/shared-functions/container-nfs.sh"
    guests=$(sudo -n virsh list --name) || return 1
    [[ -z "$guests" ]] || return 1
    check_engine_nfs tux2lab-engine
    clients=$(sudo -n podman exec tux2lab-engine ls -A /proc/fs/nfsd/clients) || return 1
    [[ -z "$clients" ]] || return 1
    record_engine_nfs_owner tux2lab-engine
    identity=$(sudo -n podman inspect tux2lab-engine --format '{{.Id}} {{.Rootfs}}') || return 1
    root=$(sudo -n podman inspect tux2lab-engine --format '{{.Rootfs}}') || return 1
    owner="${root%/rootfs}/nfs-owner.json"
    held="${root%/rootfs}/nfs-owner.validation-held"
    sudo -n test ! -e "$held" && sudo -n test ! -L "$held" || return 1
    cleanup_cli_recovery() {
        status=$?
        trap - EXIT
        if "$owner_held"; then
            if sudo -n test -e "$owner"; then
                printf 'Unexpected replacement owner record; retained %s\n' "$held" >&2
                status=1
            else
                sudo -n mv -- "$held" "$owner" || status=1
            fi
        fi
        if "$restart_needed"; then /usr/local/bin/tux2lab start > "$evidence/failure-restart.log" 2>&1 || status=1; fi
        exit "$status"
    }
    trap cleanup_cli_recovery EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    sudo -n nft -j -s list table inet tux2lab_nfs | tee "$evidence/firewall-before.json" >/dev/null
    restart_needed=true
    sudo -n podman kill --signal KILL tux2lab-engine | tee "$evidence/kill.log" >/dev/null
    [[ "$(sudo -n podman wait tux2lab-engine)" == 137 ]]
    listeners=$(sudo -n ss -H -lntu '( sport = :2049 or sport = :111 or sport = :20048 )')
    if [[ -n "$listeners" ]]; then
        sudo -n mv -- "$owner" "$held"
        owner_held=true
        if /usr/local/bin/tux2lab start > "$evidence/missing-owner.log" 2>&1; then
            printf 'FAIL: startup accepted orphaned NFS without ownership evidence\n' >&2
            return 1
        fi
        [[ "$(sudo -n podman inspect tux2lab-engine --format '{{.State.Running}} {{.State.ExitCode}}')" == 'false 137' ]]
        [[ "$(sudo -n ss -H -lntu '( sport = :2049 or sport = :111 or sport = :20048 )')" == "$listeners" ]]
        sudo -n nft -j -s list table inet tux2lab_nfs | cmp - "$evidence/firewall-before.json"
        sudo -n mv -- "$held" "$owner"
        owner_held=false
        printf 'PASS: normal startup refuses missing ownership evidence without changing orphaned NFS\n'
    fi
    /usr/local/bin/tux2lab start > "$evidence/start-recovery.log" 2>&1
    restart_needed=false
    check_engine_nfs tux2lab-engine
    [[ "$(sudo -n podman inspect tux2lab-engine --format '{{.Id}} {{.Rootfs}}')" == "$identity" ]]
    printf 'PASS: normal startup recovers the recorded owner and preserves the engine/root\n'
)

run_deployed_restart_test() (
    local expected_host="$1" relative_file="$2" evidence="$3" shutdown_mode="${4:-stop}" bridge_ip
    if [[ "$EUID" == 0 ]]; then
        printf 'Run deployed recovery tests as a sudo-capable non-root user.\n' >&2
        return 1
    fi
    [[ "$(hostname -f)" == "$expected_host" && "$expected_host" != localhost ]] || return 1
    [[ -d "$evidence" && "$(readlink -e "$evidence")" == "$evidence" && "$evidence" != /tux2lab-data* ]] || return 1
    [[ "$relative_file" != /* && "/$relative_file/" != */../* ]] || return 1
    source "$PROJECT_ROOT/shared-functions/container-nfs.sh"
    require_container_nfs_engine tux2lab-engine
    check_engine_nfs tux2lab-engine
    bridge_ip=$(jq -er '.network.ipv4.address' /tux2lab-data/lab-config/lab_environment.json)
    python3 - "$PROJECT_ROOT" "$bridge_ip" "$relative_file" "$evidence" "$shutdown_mode" <<'RECOVERYHOST'
import json
from pathlib import Path
import select
import subprocess
import sys
import time

project, server, relative_file, evidence_path, shutdown_mode = sys.argv[1:]
assert shutdown_mode in ("stop", "kill", "kill-stop")
evidence = Path(evidence_path)
engine = "tux2lab-engine"
client = None
restart_needed = False
started_at = str(int(time.time()))

def command(arguments, timeout=45, log=None):
    result = subprocess.run(arguments, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    if log is not None:
        (evidence / log).write_text(result.stdout)
    if result.returncode:
        print(result.stdout, file=sys.stderr)
        result.check_returncode()
    return result.stdout

def inspect_engine():
    return json.loads(command(["sudo", "-n", "podman", "inspect", engine]))[0]

def receive(timeout):
    assert client is not None
    assert select.select([client.stdout], [], [], timeout)[0], "Client response timed out"
    line = client.stdout.readline()
    assert line, "Client exited before completing recovery"
    message = json.loads(line)
    print(json.dumps(message), flush=True)
    return message

def client_states():
    return command(["sudo", "-n", "podman", "exec", engine, "sh", "-c",
                    "cat /proc/fs/nfsd/clients/*/states"])

def snapshot_exports(phase):
    output = command(["sudo", "-n", "podman", "exec", engine, "cat",
                      "/proc/net/rpc/nfsd.fh/content", "/proc/net/rpc/nfsd.export/content"])
    (evidence / ("export-cache-" + phase + ".txt")).write_text(output)

def restart_engine():
    command(["/usr/local/bin/tux2lab", "start"], timeout=150, log="restart.log")
    command(["sudo", "-n", "podman", "exec", engine, "/bin/bash",
             "/usr/local/lib/tux2lab/nfs-service.sh", "check"])

original = inspect_engine()
assert original["State"]["Running"]
assert original["Config"]["Labels"]["io.tux2lab.nfs.layout"] == "direct-v1"
assert not command(["sudo", "-n", "virsh", "list", "--name"]).strip(), "Test host has running guests"
assert not command(["sudo", "-n", "podman", "exec", engine, "ls", "-A",
                    "/proc/fs/nfsd/clients"]).strip(), "Existing NFSv4 clients must be drained first"
command(["sudo", "-n", "python3", project + "/shared-functions/nfs-recovery.py", "record", engine])

with (evidence / "client.stderr").open("wb") as client_errors:
    try:
        client = subprocess.Popen(
            ["sudo", "-n", "unshare", "--mount", "--propagation", "private", "bash",
             project + "/container/run-engine-tests.sh", "--recovery-client", server, relative_file],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=client_errors,
            bufsize=0, start_new_session=True)
        ready = receive(40)
        assert ready["event"] == "ready"
        states = client_states()
        (evidence / "open-states-before.txt").write_text(states)
        assert "type: open" in states, "No server-side NFSv4 OPEN state"
        snapshot_exports("before")
        firewall = command(["sudo", "-n", "nft", "-j", "-s", "list", "table", "inet", "tux2lab_nfs"],
                           log="firewall-before.json")
        restart_needed = True
        if shutdown_mode in ("kill", "kill-stop"):
            command(["sudo", "-n", "podman", "kill", "--signal", "KILL", engine], log="stop.log")
            assert command(["sudo", "-n", "podman", "wait", engine], timeout=30).strip() == "137"
            assert inspect_engine()["State"]["ExitCode"] == 137
            retained = command(["sudo", "-n", "nft", "-j", "-s", "list", "table", "inet", "tux2lab_nfs"],
                               log="firewall-after.json")
            assert json.loads(retained) == json.loads(firewall), "Crash changed NFS firewall protection"
            print("PASS: PID1 SIGKILL exits 137 and retains NFS firewall protection", flush=True)
            if shutdown_mode == "kill-stop":
                command(["/usr/local/bin/tux2lab", "stop", "--yes"], timeout=150,
                        log="ownership-recovery.log")
            else:
                command(["sudo", "-n", "timeout", "--kill-after=5", "90", "unshare", "--mount",
                         "--propagation", "private", "python3", project + "/shared-functions/nfs-recovery.py",
                         "recover", engine], timeout=100, log="ownership-recovery.log")
            retained = command(["sudo", "-n", "nft", "-j", "-s", "list", "table", "inet", "tux2lab_nfs"])
            assert json.loads(retained) == json.loads(firewall), "Recovery removed NFS firewall protection"
            print("PASS: ownership-checked kernel recovery retains NFS firewall protection", flush=True)
        else:
            command(["sudo", "-n", "podman", "stop", "--time", "30", engine], log="stop.log")
            assert inspect_engine()["State"]["ExitCode"] == 143
        assert not command(["sudo", "-n", "ss", "-H", "-lntu",
                            "( sport = :2049 or sport = :111 or sport = :20048 )"],
                           log="listeners-after.txt").strip(), "RPC listeners survived engine exit"
        client.stdin.write(b"read\n")
        assert receive(10)["event"] == "reading"
        assert not select.select([client.stdout], [], [], 2)[0], "Uncached read did not block during outage"
        print("PASS: an open-handle direct read blocks while the engine is stopped", flush=True)
        restart_engine()
        restart_needed = False
        snapshot_exports("after")
        recovered = receive(150)
        assert recovered["event"] == "recovered" and recovered["sha256"] == ready["sha256"]
        states = client_states()
        (evidence / "open-states-after.txt").write_text(states)
        assert "type: open" in states, "Recovered client has no NFSv4 OPEN state"
        client.stdin.write(b"close\n")
        client.stdin.close()
        assert client.wait(timeout=20) == 0
        current = inspect_engine()
        assert current["Id"] == original["Id"] and current["Rootfs"] == original["Rootfs"]
        print("PASS: same mounted NFSv4 file descriptor resumes matching direct reads after engine restart", flush=True)
    finally:
        try:
            if restart_needed:
                restart_engine()
        finally:
            try:
                with (evidence / "kernel-recovery.log").open("w") as kernel_log:
                    subprocess.run(["sudo", "-n", "journalctl", "-k", "--since", "@" + started_at,
                                    "--no-pager"], stdout=kernel_log, stderr=subprocess.STDOUT, timeout=15)
            finally:
                if client is not None and client.poll() is None:
                    subprocess.run(["sudo", "-n", "kill", "-TERM", "--", "-" + str(client.pid)], check=False)
                    try:
                        client.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        subprocess.run(["sudo", "-n", "kill", "-KILL", "--", "-" + str(client.pid)], check=False)
                        client.wait(timeout=15)
RECOVERYHOST
)

case "${1:-}" in
    --deployed-dhcp)
        [[ $# == 3 ]] || exit 2
        run_deployed_dhcp_test "$2" "$3" ;;
    --deployed-restart)
        [[ $# == 4 ]] || exit 2
        run_deployed_restart_test "$2" "$3" "$4" ;;
    --deployed-crash)
        [[ $# == 4 ]] || exit 2
        run_deployed_restart_test "$2" "$3" "$4" kill ;;
    --deployed-crash-stop)
        [[ $# == 4 ]] || exit 2
        run_deployed_restart_test "$2" "$3" "$4" kill-stop ;;
    --deployed-crash-start)
        [[ $# == 3 ]] || exit 2
        run_deployed_cli_recovery_test "$2" "$3" ;;
    --recovery-client)
        [[ $# == 3 ]] || exit 2
        run_recovery_client "$2" "$3" ;;
    --fixtures) generate_engine_fixtures ;;
    --boot) boot_test_engine ;;
    --clients) check_engine_clients ;;
    --dhcp-client) check_engine_dhcp ;;
    --deployed-network)
        [[ $# == 3 ]] || exit 2
        run_deployed_dhcp_test "$2" "$3" true ;;
    --deployed-nfs-client) check_deployed_nfs_client ;;
    --deployed-firewall)
        [[ $# == 4 ]] || exit 2
        run_deployed_firewall_phase "$2" "$3" "$4" ;;
    --restore-deployed-firewall)
        [[ $# == 2 ]] || exit 2
        restore_deployed_firewall "$2" ;;
    --deployed-helpers)
        [[ $# == 3 ]] || exit 2
        run_deployed_helper_audit "$2" "$3" ;;
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
    *) printf 'Usage: bash container/run-engine-tests.sh --startup IMAGE | --run IMAGE ISO_MOUNT | --failure IMAGE\n       bash container/run-engine-tests.sh --deployed-restart|--deployed-crash|--deployed-crash-stop EXPECTED_HOST RELATIVE_FILE EVIDENCE_DIR\n       bash container/run-engine-tests.sh --deployed-crash-start EXPECTED_HOST EVIDENCE_DIR\n       bash container/run-engine-tests.sh --deployed-dhcp|--deployed-network EXPECTED_HOST EVIDENCE_DIR\n       sudo bash container/run-engine-tests.sh --deployed-firewall EXPECTED_HOST EVIDENCE_DIR start|reload|restart|restore\n       sudo bash container/run-engine-tests.sh --restore-deployed-firewall EVIDENCE_DIR\n       sudo bash container/run-engine-tests.sh --deployed-helpers EXPECTED_HOST EVIDENCE_DIR\n' >&2; exit 2 ;;
esac