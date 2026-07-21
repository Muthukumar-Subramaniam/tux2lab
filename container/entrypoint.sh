#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# tux2lab-engine container entrypoint
# Starts all lab infrastructure services, bound to the lab bridge IP only.
#
# Environment variables (passed via podman run -e):
#   TUX2LAB_BRIDGE_IP   - IP address on labbr0 (e.g., 192.168.100.1)
#   TUX2LAB_BRIDGE_IF   - Bridge interface name (default: labbr0)
#   TUX2LAB_DATA_DIR    - Path to tux2lab-data mount (default: /tux2lab-data)
#----------------------------------------------------------------------------------------#
set -euo pipefail

# --- Configuration from environment ---
BRIDGE_IP="${TUX2LAB_BRIDGE_IP:-}"
BRIDGE_IF="${TUX2LAB_BRIDGE_IF:-labbr0}"
DATA_DIR="${TUX2LAB_DATA_DIR:-/tux2lab-data}"

if [[ -z "${BRIDGE_IP}" ]]; then
    echo "[ERROR] TUX2LAB_BRIDGE_IP must be set (e.g., 192.168.100.1)"
    exit 1
fi

echo "============================================"
echo " tux2lab-engine starting"
echo " Bridge IP: ${BRIDGE_IP}"
echo " Bridge IF: ${BRIDGE_IF}"
echo " Data dir:  ${DATA_DIR}"
echo "============================================"

# --- Ensure container-internal writable directories exist ---
# Service state goes to container's own filesystem (ephemeral)
# Config/content comes from /tux2lab-data (read-only mount)
mkdir -p /var/named/data /var/named/dynamic
chown -R named:named /var/named
mkdir -p /var/run/kea /run/named
chown named:named /run/named

# Generate rndc key if missing (needed for rndc reload/status)
if [[ ! -f /etc/rndc.key ]]; then
    rndc-confgen -a -u named &>/dev/null
fi

# Enable IPv6 forwarding on bridge (required for radvd)
sysctl -w "net.ipv6.conf.${BRIDGE_IF}.forwarding=1" &>/dev/null || true

# --- Wait for bridge interface and IPs to be ready ---
echo "[*] Waiting for ${BRIDGE_IF} to be ready..."
timeout=30
elapsed=0
while ! ip link show "${BRIDGE_IF}" 2>/dev/null | grep -q "state UP"; do
    if ((elapsed >= timeout)); then
        echo "[ERROR] Timeout waiting for ${BRIDGE_IF} to come UP"
        exit 1
    fi
    sleep 1
    ((++elapsed))
done
echo "    → ${BRIDGE_IF} is UP"

# Wait for IPv4 address
elapsed=0
while ! ip -4 addr show dev "${BRIDGE_IF}" 2>/dev/null | grep -q "${BRIDGE_IP}"; do
    if ((elapsed >= timeout)); then
        echo "[ERROR] Timeout waiting for IPv4 ${BRIDGE_IP} on ${BRIDGE_IF}"
        exit 1
    fi
    sleep 1
    ((++elapsed))
done
echo "    → IPv4 ${BRIDGE_IP} ready"

# Wait for IPv6 address (DAD completion — no "tentative" flag)
elapsed=0
while ip -6 addr show dev "${BRIDGE_IF}" 2>/dev/null | grep -q "tentative"; do
    if ((elapsed >= timeout)); then
        echo "[WARN] IPv6 DAD did not complete within ${timeout}s, proceeding anyway"
        break
    fi
    sleep 1
    ((++elapsed))
done
echo "    → IPv6 ready"

# --- Helper: wait for a process to be ready ---
wait_for_pid() {
    local pidfile="$1"
    local timeout=10
    while [[ ! -f "${pidfile}" ]] && ((timeout-- > 0)); do
        sleep 0.5
    done
}

# --- 1. Start named (DNS) ---
# Binds to bridge IP only — configured via named.conf
echo "[*] Starting named (DNS)..."
if [[ -f "${DATA_DIR}/named/named.conf" ]]; then
    /usr/sbin/named -u named -c "${DATA_DIR}/named/named.conf" -f &
    echo "    → named started (config from ${DATA_DIR}/named/named.conf)"
else
    echo "    → SKIPPED: no named.conf found at ${DATA_DIR}/named/named.conf"
fi

# --- 2. Start kea-dhcp4 (DHCPv4) ---
# Listens on the bridge interface — configured via kea-dhcp4.conf
echo "[*] Starting kea-dhcp4 (DHCPv4)..."
if [[ -f "${DATA_DIR}/kea/kea-dhcp4.conf" ]]; then
    /usr/sbin/kea-dhcp4 -c "${DATA_DIR}/kea/kea-dhcp4.conf" &
    echo "    → kea-dhcp4 started (interface: ${BRIDGE_IF})"
else
    echo "    → SKIPPED: no kea-dhcp4.conf found"
fi

# --- 3. Start kea-dhcp6 (DHCPv6) ---
# Assigns IPv6 addresses to guest VMs (stateful DHCPv6, paired with radvd M=1)
echo "[*] Starting kea-dhcp6 (DHCPv6)..."
if [[ -f "${DATA_DIR}/kea/kea-dhcp6.conf" ]]; then
    /usr/sbin/kea-dhcp6 -c "${DATA_DIR}/kea/kea-dhcp6.conf" &
    echo "    → kea-dhcp6 started (interface: ${BRIDGE_IF})"
else
    echo "    → SKIPPED: no kea-dhcp6.conf found"
fi

# --- 4. Start kea-ctrl-agent (Kea API) ---
# Management API for dynamic DHCP operations
echo "[*] Starting kea-ctrl-agent..."
if [[ -f "${DATA_DIR}/kea/kea-ctrl-agent.conf" ]]; then
    /usr/sbin/kea-ctrl-agent -c "${DATA_DIR}/kea/kea-ctrl-agent.conf" &
    echo "    → kea-ctrl-agent started"
else
    echo "    → SKIPPED: no kea-ctrl-agent.conf found"
fi

# --- 5. Start nginx (HTTP/HTTPS) ---
# Serves boot ISOs, kickstarts, lab-config — binds to bridge IP
echo "[*] Starting nginx (HTTP)..."
if [[ -f "${DATA_DIR}/nginx/nginx.conf" ]]; then
    /usr/sbin/nginx -c "${DATA_DIR}/nginx/nginx.conf" -g 'daemon off;' &
    echo "    → nginx started (serving ${DATA_DIR})"
else
    echo "    → SKIPPED: no nginx.conf found at ${DATA_DIR}/nginx/nginx.conf"
fi

# --- 6. Start TFTP ---
# Serves iPXE binaries for PXE boot — binds to bridge IP (dual-stack)
echo "[*] Starting in.tftpd (TFTP)..."
/usr/sbin/in.tftpd \
    --foreground \
    --listen \
    --address "${BRIDGE_IP}:69" \
    --secure \
    "${DATA_DIR}/tftpboot" &
# IPv6 TFTP instance
BRIDGE_IPV6=$(ip -6 addr show dev "${BRIDGE_IF}" scope global 2>/dev/null | grep -oP 'inet6 \K[^/]+' | head -1)
if [[ -n "${BRIDGE_IPV6}" ]]; then
    /usr/sbin/in.tftpd \
        --foreground \
        --listen \
        --address "[${BRIDGE_IPV6}]:69" \
        --secure \
        "${DATA_DIR}/tftpboot" &
    echo "    → tftpd started on ${BRIDGE_IP}:69 + [${BRIDGE_IPV6}]:69"
else
    echo "    → tftpd started on ${BRIDGE_IP}:69 (IPv6 not available)"
fi

# --- 7. Start NFS ---
# Exports /tux2lab-data for stage2 (RHEL) and casper-root (Ubuntu)
echo "[*] Starting NFS..."
if [[ -f "${DATA_DIR}/nfs/exports" ]]; then
    cp "${DATA_DIR}/nfs/exports" /etc/exports
    # Restrict rpcbind and mountd to bridge IPs
    /usr/sbin/rpcbind -w -h "${BRIDGE_IP}" -h "${BRIDGE_IPV6:-::1}" || true
    # Load NFS kernel module if needed, then start NFS daemon with timeout
    modprobe nfsd 2>/dev/null || true
    timeout 10 /usr/sbin/rpc.nfsd -H "${BRIDGE_IP}" -H "${BRIDGE_IPV6:-::1}" 4 || echo "    → WARNING: rpc.nfsd failed (NFS kernel module may not be available)"
    /usr/sbin/rpc.idmapd || true
    /usr/sbin/rpc.mountd --no-nfs-version 2 --no-nfs-version 3 -H "${BRIDGE_IP}" -H "${BRIDGE_IPV6:-::1}" || true
    /usr/sbin/exportfs -ra || true
    echo "    → NFS started (exports from ${DATA_DIR}/nfs/exports)"
else
    echo "    → SKIPPED: no exports file found"
fi

# --- 8. Start chrony (NTP) ---
# Serves time to lab VMs — binds to bridge IP
# -x = don't adjust system clock (host's chronyd handles that)
# -u root = stay as root (avoids UID mismatch between container and host)
echo "[*] Starting chronyd (NTP)..."
if [[ -f "${DATA_DIR}/chrony/chrony.conf" ]]; then
    /usr/sbin/chronyd -f "${DATA_DIR}/chrony/chrony.conf" -d -x -u root &
    echo "    → chronyd started on ${BRIDGE_IP} (time server only, no clock adjust)"
else
    /usr/sbin/chronyd -d -x -u root &
    echo "    → chronyd started (default config, no clock adjust)"
fi

# --- 9. Start radvd (IPv6 Router Advertisements) ---
# Sends RAs on labbr0 so guest VMs get IPv6 addresses
echo "[*] Starting radvd (IPv6 RA)..."
if [[ -f "${DATA_DIR}/radvd/radvd.conf" ]]; then
    /usr/sbin/radvd -C "${DATA_DIR}/radvd/radvd.conf" -n &
    echo "    → radvd started (IPv6 RA on ${BRIDGE_IF})"
else
    echo "    → SKIPPED: no radvd.conf found"
fi

echo "============================================"
echo " tux2lab-engine: all services started"
echo " Listening on: ${BRIDGE_IP} (${BRIDGE_IF})"
echo " Debug access: sudo podman exec -it tux2lab-engine bash"
echo "============================================"

# --- Keep container alive ---
# Wait for any background process to exit (means a service crashed)
# Disable errexit — wait -n returns the child's exit code, which may be non-zero
set +e
wait -n
echo "[ERROR] A service has exited unexpectedly. Container stopping."
exit 1
