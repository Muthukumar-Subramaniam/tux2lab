#!/usr/bin/env bash
# DNS records for the DHCP pools (the NFS export ACL relies on their reverse lookup).
# Idempotent: only names missing from the forward zone are created.

# Usage: ensure_dhcp_pool_dns_records <domain> <dhcp4_range_start> <dhcp4_range_end> <ipv6_prefix_base>
ensure_dhcp_pool_dns_records() {
    local domain="$1"
    local range_start="$2"
    local range_end="$3"
    local ipv6_prefix_base="$4"
    local zone_file="/tux2lab-data/named/dnsbinder-managed-zone-files/${domain}-forward.db"
    local prefix="${range_start%.*}"
    local first="${range_start##*.}"
    local last="${range_end##*.}"
    # Matches the Kea DHCPv6 pool ::3ff-::461
    local -r dhcp6_pool_size=99
    local list_file output i tries

    if ! sudo test -f "${zone_file}"; then
        print_error "Forward zone not found: ${zone_file}"
        return 1
    fi

    print_task "Waiting for DNS service..."
    for (( tries = 0; tries < 30; tries++ )); do
        sudo podman exec tux2lab-engine rndc status &>/dev/null && break
        sleep 1
    done
    if (( tries == 30 )); then
        print_task_fail
        print_error "named in tux2lab-engine did not become ready."
        return 1
    fi
    print_task_done

    list_file="$(mktemp /tmp/dhcp-pool-records.XXXXXXXXXX)" || return 1

    print_task "Creating DNS records for DHCPv4 pool..."
    for (( i = first; i <= last; i++ )); do
        echo "dhcp4-lease$(( i - first + 1 )) ${prefix}.${i}"
    done | sudo awk 'NR == FNR { seen[$1]; next } !($1 in seen)' "${zone_file}" - > "${list_file}"
    if [[ -s "${list_file}" ]] && ! output=$(sudo bash /tux2lab/named-manage/dnsbinder.sh -cify --ipv4-only --ttl 86400 --inline "${list_file}" 2>&1); then
        print_task_fail
        print_error "dnsbinder failed to create the DHCPv4 pool records:"
        echo "${output}"
        rm -f "${list_file}"
        return 1
    fi
    print_task_done

    print_task "Creating DNS records for DHCPv6 pool..."
    for (( i = 1; i <= dhcp6_pool_size; i++ )); do
        echo "dhcp6-lease${i} ${ipv6_prefix_base}::$(printf '%x' $(( 0x3ff + i - 1 )))"
    done | sudo awk 'NR == FNR { seen[$1]; next } !($1 in seen)' "${zone_file}" - > "${list_file}"
    if [[ -s "${list_file}" ]] && ! output=$(sudo bash /tux2lab/named-manage/dnsbinder.sh -c6fy --ttl 86400 --inline "${list_file}" 2>&1); then
        print_task_fail
        print_error "dnsbinder failed to create the DHCPv6 pool records:"
        echo "${output}"
        rm -f "${list_file}"
        return 1
    fi
    print_task_done

    rm -f "${list_file}"
}
