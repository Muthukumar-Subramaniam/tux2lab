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

# --- Ensure persistent directories exist ---
mkdir -p "${DATA_DIR}/kea/leases"
mkdir -p "${DATA_DIR}/nfs/state"
mkdir -p "${DATA_DIR}/chrony"
mkdir -p "${DATA_DIR}/log/nginx"
mkdir -p "${DATA_DIR}/tftpboot"
# Symlink service state to persistent volume (survive container restarts)
ln -sf "${DATA_DIR}/kea/leases" /var/lib/kea
ln -sf "${DATA_DIR}/nfs/state" /var/lib/nfs
ln -sf "${DATA_DIR}/chrony" /var/lib/chrony
ln -sf "${DATA_DIR}/log/nginx" /var/log/nginx

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
# Serves iPXE binaries for PXE boot — binds to bridge IP
echo "[*] Starting in.tftpd (TFTP)..."
mkdir -p "${DATA_DIR}/tftpboot"
/usr/sbin/in.tftpd \
    --listen \
    --address "${BRIDGE_IP}:69" \
    --secure \
    "${DATA_DIR}/tftpboot" &
echo "    → tftpd started on ${BRIDGE_IP}:69"

# --- 7. Start NFS ---
# Exports /tux2lab-data for stage2 (RHEL) and casper-root (Ubuntu)
echo "[*] Starting NFS..."
if [[ -f "${DATA_DIR}/nfs/exports" ]]; then
    cp "${DATA_DIR}/nfs/exports" /etc/exports
    /usr/sbin/rpcbind -w || true
    /usr/sbin/rpc.nfsd 4
    /usr/sbin/rpc.idmapd || true
    /usr/sbin/rpc.mountd --no-nfs-version 2 --no-nfs-version 3
    /usr/sbin/exportfs -ra
    echo "    → NFS started (exports from ${DATA_DIR}/nfs/exports)"
else
    echo "    → SKIPPED: no exports file found"
fi

# --- 8. Start chrony (NTP) ---
# Serves time to lab VMs — binds to bridge IP
echo "[*] Starting chronyd (NTP)..."
if [[ -f "${DATA_DIR}/chrony/chrony.conf" ]]; then
    /usr/sbin/chronyd -f "${DATA_DIR}/chrony/chrony.conf" -d &
    echo "    → chronyd started on ${BRIDGE_IP}"
else
    # Fallback: start with default config allowing bridge subnet
    /usr/sbin/chronyd -d &
    echo "    → chronyd started (default config)"
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

# --- 10. Start sshd (debugging access) ---
# Pub key only, binds to bridge IP
echo "[*] Starting sshd..."
/usr/sbin/sshd -o "ListenAddress=${BRIDGE_IP}" -o "PasswordAuthentication=no"
echo "    → sshd started on ${BRIDGE_IP}:22"

echo "============================================"
echo " tux2lab-engine: all services started"
echo " Listening on: ${BRIDGE_IP} (${BRIDGE_IF})"
echo "============================================"

# --- Keep container alive ---
# Wait for any background process to exit (means a service crashed)
wait -n
echo "[ERROR] A service has exited unexpectedly. Container stopping."
exit 1
