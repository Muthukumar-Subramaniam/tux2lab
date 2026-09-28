#!/usr/bin/env bash

NFS_CONTROL_DIR=/proc/fs/nfsd
NFS_CHILDREN=()
NFS_OWNS_SERVER=false
NFS_OWNS_CONTROL=false
NFS_OWNS_PIPEFS=false
NFS_OWNS_FIREWALL=false
NFS_FIREWALL_STATE=/run/tux2lab-nfs.firewall.json

nfs_check_firewall() {
    local rules
    [[ -s "$NFS_FIREWALL_STATE" ]] || return 1
    rules=$(nft -j -s list table inet tux2lab_nfs) || return 1
    printf '%s\n' "$rules" | cmp -s "$NFS_FIREWALL_STATE" -
}

nfs_require_unused_exports() {
    local exports
    exports=$(cat /proc/fs/nfs/exports) || {
        printf '[ERROR] Cannot inspect kernel exports; refusing takeover.\n' >&2
        return 1
    }
    if [[ -z "$exports" || "$exports" != '# Version '* ]]; then
        printf '[ERROR] Unrecognized kernel export state; refusing takeover.\n' >&2
        return 1
    fi
    if grep -q '^/' <<< "$exports"; then
        printf '[ERROR] Kernel exports already exist; refusing to replace them.\n' >&2
        return 1
    fi
}

nfs_wait_for_rpc() {
    local program="$1" version="$2" attempt
    for ((attempt = 0; attempt < 50; attempt++)); do
        if timeout 1 rpcinfo -T tcp 127.0.0.1 "$program" "$version" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done
    printf '[ERROR] NFS RPC program %s did not become ready.\n' "$program" >&2
    return 1
}

nfs_wait_for_tracking_daemon() {
    local child="$1" attempt
    for ((attempt = 0; attempt < 100; attempt++)); do
        kill -0 "$child" 2>/dev/null || break
        if grep -qs '^inotify ' "/proc/$child"/fdinfo/*; then
            return 0
        fi
        sleep 0.1
    done
    printf '[ERROR] NFS client tracking daemon did not initialize its pipe watch.\n' >&2
    return 1
}

check_container_nfs() {
    local child
    [[ -s /run/tux2lab-nfs.ready ]] || return 1
    [[ "$(cat "$NFS_CONTROL_DIR/threads")" -gt 0 ]] || return 1
    [[ -p /var/lib/nfs/rpc_pipefs/nfsd/cld ]] || return 1
    while IFS= read -r child; do
        [[ "$child" =~ ^[0-9]+$ ]] && kill -0 "$child" 2>/dev/null || return 1
    done < /run/tux2lab-nfs.ready
    nfs_check_firewall || return 1
    timeout 5 rpcinfo -n 2049 -t "${BRIDGE_IP:?}" 100003 3 >/dev/null 2>&1 || return 1
    timeout 5 rpcinfo -n 2049 -t "$BRIDGE_IP" 100003 4 >/dev/null 2>&1
}

start_container_nfs() {
    local config_dir="${DATA_DIR:?}/nfs" listener
    [[ -s "$config_dir/container.exports" && -s "$config_dir/container.conf" ]] || {
        printf '[ERROR] Container NFS configuration missing; regenerate lab configuration.\n' >&2
        return 1
    }
    if [[ -r "$NFS_CONTROL_DIR/threads" && "$(cat "$NFS_CONTROL_DIR/threads")" != 0 ]]; then
        printf '[ERROR] Another kernel NFS server is active; refusing takeover.\n' >&2
        return 1
    fi
    listener=$(ss -H -lntu '( sport = :111 or sport = :2049 or sport = :20048 or sport = :32803 or sport = :32769 or sport = :32765 or sport = :32766 )') || return 1
    if [[ -n "$listener" ]]; then
        printf '[ERROR] NFS/RPC ports are already in use; perform the documented host migration first.\n' >&2
        return 1
    fi
    [[ -d /export && -d "/export${DATA_DIR}" ]] || return 1
    [[ "$(stat -f -c %T /export)" != overlayfs ]] || return 1
    cp "$config_dir/container.conf" /etc/nfs.conf || return 1
    cp "$config_dir/container.exports" /etc/exports || return 1
    mkdir -p "$NFS_CONTROL_DIR" /var/lib/nfs/{v4recovery,nfsdcld,nfsdcltrack} /var/lib/nfs/rpc_pipefs || return 1
    touch /var/lib/nfs/etab /var/lib/nfs/rmtab /var/lib/nfs/state || return 1
    if ! mountpoint -q "$NFS_CONTROL_DIR"; then
        mount -t nfsd nfsd "$NFS_CONTROL_DIR" || return 1
        NFS_OWNS_CONTROL=true
    fi
    [[ "$(cat "$NFS_CONTROL_DIR/threads")" == 0 ]] || return 1
    nfs_require_unused_exports || return 1
    sysctl -w fs.nfs.nlm_tcpport=32803 fs.nfs.nlm_udpport=32769 >/dev/null || return 1
    if nft list table inet tux2lab_nfs >/dev/null 2>&1; then
        nft delete table inet tux2lab_nfs || return 1
    fi
    write_container_nfs_firewall "${BRIDGE_IF:?}" | nft -f - || return 1
    NFS_OWNS_FIREWALL=true
    nft -j -s list table inet tux2lab_nfs > "$NFS_FIREWALL_STATE" || return 1
    if ! mountpoint -q /var/lib/nfs/rpc_pipefs; then
        mount -t rpc_pipefs sunrpc /var/lib/nfs/rpc_pipefs || return 1
        NFS_OWNS_PIPEFS=true
    fi
    nfsdcld -F -p /var/lib/nfs/rpc_pipefs -s /var/lib/nfs/nfsdcld &
    NFS_CHILDREN+=("$!")
    nfs_wait_for_tracking_daemon "${NFS_CHILDREN[0]}" || return 1
    local rpcbind_hosts=(-h "$BRIDGE_IP")
    [[ -z "${BRIDGE_IPV6:-}" ]] || rpcbind_hosts+=(-h "$BRIDGE_IPV6")
    rpcbind -f "${rpcbind_hosts[@]}" &
    NFS_CHILDREN+=("$!")
    nfs_wait_for_rpc 100000 2 || return 1
    NFS_OWNS_SERVER=true
    exportfs -ra || return 1
    rpc.mountd --foreground --no-nfs-version 2 --port 20048 &
    NFS_CHILDREN+=("$!")
    nfs_wait_for_rpc 100005 3 || return 1
    rpc.nfsd --nfs-version 3 --nfs-version 4 --udp 8 || return 1
    printf '%s\n' "${NFS_CHILDREN[@]}" > /run/tux2lab-nfs.ready
    check_container_nfs
}

stop_container_nfs() {
    local child attempt
    rm -f /run/tux2lab-nfs.ready
    if "$NFS_OWNS_SERVER"; then
        timeout 10 rpc.nfsd 0 || return 1
        exportfs -ua || return 1
        NFS_OWNS_SERVER=false
    fi
    for child in "${NFS_CHILDREN[@]}"; do
        kill -TERM "$child" 2>/dev/null || true
    done
    for ((attempt = 0; attempt < 50; attempt++)); do
        local alive=false
        for child in "${NFS_CHILDREN[@]}"; do
            kill -0 "$child" 2>/dev/null && alive=true
        done
        "$alive" || break
        sleep 0.1
    done
    for child in "${NFS_CHILDREN[@]}"; do
        if kill -0 "$child" 2>/dev/null; then
            kill -KILL "$child" 2>/dev/null || true
        fi
        wait "$child" 2>/dev/null || true
    done
    NFS_CHILDREN=()
    if "$NFS_OWNS_PIPEFS"; then
        umount /var/lib/nfs/rpc_pipefs || return 1
        NFS_OWNS_PIPEFS=false
    fi
    if "$NFS_OWNS_CONTROL"; then
        umount "$NFS_CONTROL_DIR" || return 1
        NFS_OWNS_CONTROL=false
    fi
    if "$NFS_OWNS_FIREWALL"; then
        nft delete table inet tux2lab_nfs || return 1
        NFS_OWNS_FIREWALL=false
        rm -f "$NFS_FIREWALL_STATE" || return 1
    fi
}

monitor_container_nfs() {
    while check_container_nfs; do
        sleep 2
    done
    printf '[ERROR] Container NFS lost readiness.\n' >&2
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    BRIDGE_IP="${TUX2LAB_BRIDGE_IP:-}"
    if [[ "${1:-}" != check || -z "$BRIDGE_IP" ]]; then
        printf 'Usage: nfs-service.sh check (requires TUX2LAB_BRIDGE_IP)\n' >&2
        exit 2
    fi
    check_container_nfs
fi