#!/usr/bin/env bash

write_container_nfs_exports() {
    local data_dir="$1" ipv4_network="$2" ipv6_network="${3:-}"
    local export_path network
    if [[ ! "$data_dir" =~ ^/[a-zA-Z0-9_/-]+$ || "$data_dir" == / || "$data_dir" == */ ]]; then
        printf 'Invalid NFS data directory: %s\n' "$data_dir" >&2
        return 1
    fi
    if [[ ! "$ipv4_network" =~ ^[0-9.]+/[0-9]+$ ]] ||
       [[ -n "$ipv6_network" && ! "$ipv6_network" =~ ^[a-fA-F0-9:]+/[0-9]+$ ]]; then
        printf 'Invalid NFS client network.\n' >&2
        return 1
    fi
    local fsid=0
    for export_path in /export "/export${data_dir}"; do
        printf '%s' "$export_path"
        for network in "$ipv4_network" "$ipv6_network"; do
            [[ -n "$network" ]] || continue
            printf ' %s(ro,sync,fsid=%s,no_subtree_check,no_root_squash,crossmnt)' "$network" "$fsid"
        done
        printf '\n'
        fsid=1
    done
}

write_container_nfs_conf() {
    local ipv4_address="$1" ipv6_address="${2:-}"
    if [[ ! "$ipv4_address" =~ ^[0-9.]+$ ]] ||
       [[ -n "$ipv6_address" && ! "$ipv6_address" =~ ^[a-fA-F0-9:]+$ ]]; then
        printf 'Invalid NFS bind address.\n' >&2
        return 1
    fi
    printf '[nfsd]\nhost = %s%s\nthreads = 8\nvers3 = y\nvers4 = y\nudp = y\n' \
        "$ipv4_address" "${ipv6_address:+,$ipv6_address}"
    printf '[mountd]\nport = 20048\n[nfsdcltrack]\nstoragedir = /var/lib/nfs/nfsdcltrack\n'
    printf '[lockd]\nport = 32803\nudp-port = 32769\n'
    printf '[statd]\nport = 32765\noutgoing-port = 32766\n'
}

write_container_nfs_firewall() {
    local bridge="$1"
    if [[ ! "$bridge" =~ ^[a-zA-Z0-9_-]{1,15}$ || "$bridge" == lo ]]; then
        printf 'Invalid NFS bridge interface.\n' >&2
        return 1
    fi
    printf 'table inet tux2lab_nfs {\n chain input {\n  type filter hook input priority -10; policy accept;\n'
    printf '  iifname != { "lo", "%s" } tcp dport { 111, 2049, 20048, 32803, 32765 } drop\n' "$bridge"
    printf '  iifname != { "lo", "%s" } udp dport { 111, 2049, 20048, 32769, 32765, 32766 } drop\n' "$bridge"
    printf ' }\n}\n'
}