#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: health.sh                                                            #
# Description: tux2lab Health Check Tool                                                 #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
# Note: -e is intentionally omitted — health checks must run to completion
set -uo pipefail

# Source color functions and environment defaults
source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# ====== HELP ======
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_cyan "USAGE:
    tux2lab health

DESCRIPTION:
    Checks all lab infrastructure services and reports their status.
    Exit codes: 0 = STABLE, 1 = DEGRADED, 2 = CRITICAL."
    exit 0
fi

if [[ $# -gt 0 ]]; then
    print_error "Unknown argument: $1"
    echo "Run 'tux2lab health --help' for usage information."
    exit 1
fi

# ====== PREREQUISITE CHECKS ======
if ! command -v nc &>/dev/null; then
    print_error "Required command 'nc' (netcat) is not installed."
    exit 1
fi

# In VM mode, verify the infra server VM is running
if ! $lab_infra_server_mode_is_host; then
    if ! sudo virsh list --state-running --name 2>/dev/null | grep -Fxq "$lab_infra_server_hostname"; then
        print_error "Lab infra server VM '$lab_infra_server_hostname' is not running."
        print_info "Start it with: tux2lab start"
        exit 2
    fi
fi

# Define port numbers
PORT_DNS=53
PORT_DHCPV4=67
PORT_NTP=123
PORT_TFTP=69
PORT_NFS=2049
PORT_WEB=80

# Define lab infra services (service_name:port:protocol:address)
# DNS is checked first so we can detect hostname resolution failures early
services_to_check=(
  "DNS Server:$PORT_DNS:tcp:$lab_infra_server_hostname"
  "DHCP Server:$PORT_DHCPV4:udp:$lab_infra_server_ipv4_address"
  "NTP Server:$PORT_NTP:udp:$lab_infra_server_hostname"
  "TFTP Server:$PORT_TFTP:udp:$lab_infra_server_hostname"
  "NFS Server:$PORT_NFS:tcp:$lab_infra_server_hostname"
  "Web Server:$PORT_WEB:tcp:$lab_infra_server_hostname"
)

# -------------------------------------------------------------
# Calculate the max length of service names for proper alignment
# -------------------------------------------------------------
max_len=0
for entry in "${services_to_check[@]}"; do
    IFS=':' read -r service_name service_port service_proto service_address <<< "$entry"
    (( ${#service_name} > max_len )) && max_len=${#service_name}
done

# -------------------------------------------------------------
# Header
# -------------------------------------------------------------
if $lab_infra_server_mode_is_host; then
    lab_infra_server_mode="HOST"
else
    lab_infra_server_mode="VM"
fi

print_cyan "--------------------------------------------------------------
tux2lab Health Check
Lab Infra Server Mode: ${lab_infra_server_mode}
Lab Infra Server     : ${lab_infra_server_hostname}
IPv4 Address         : ${lab_infra_server_ipv4_address}
IPv6 Address         : ${lab_infra_server_ipv6_address}
-------------------------------------------------------------"

active_services=0
inactive_services=0
dns_is_down=false

# -------------------------------------------------------------
# Service checks
# -------------------------------------------------------------
for entry in "${services_to_check[@]}"; do
    IFS=':' read -r service_name service_port service_proto service_address <<< "$entry"

    # If DNS is down, fall back to IP address for hostname-based checks
    if $dns_is_down && [[ "$service_address" == "$lab_infra_server_hostname" ]]; then
        service_address="$lab_infra_server_ipv4_address"
    fi

    check_result=1
    if [[ "$service_proto" == "udp" ]]; then
        nc -z -u -w 3 "$service_address" "$service_port" &>/dev/null && check_result=0
    else
        nc -z -w 3 "$service_address" "$service_port" &>/dev/null && check_result=0
    fi

    if [[ $check_result -eq 0 ]]; then
        printf "\033[0;36m[ \033[0;32m✓\033[0;36m ] %-*s [ %s/%s ]\033[0m\n" "$max_len" "$service_name" "$service_port" "$service_proto"
        ((active_services++))
    else
        printf "\033[0;36m[ \033[0;31m✗\033[0;36m ] %-*s [ %s/%s ]\033[0m\n" "$max_len" "$service_name" "$service_port" "$service_proto"
        ((inactive_services++))
        # Track DNS failure to avoid cascade
        if [[ "$service_name" == "DNS Server" ]]; then
            dns_is_down=true
        fi
    fi
done

# -------------------------------------------------------------
# Deep Validation of Services
# -------------------------------------------------------------
print_cyan "--------------------------------------------------------------
Deep Validation of Services:
-------------------------------------------------------------"

deep_pass=0
deep_fail=0

fn_deep_pass() {
    printf "  \033[0;32m[PASS]\033[0m %s\n" "$1"
    ((deep_pass++))
}

fn_deep_fail() {
    printf "  \033[0;31m[FAIL]\033[0m %s\n" "$1"
    ((deep_fail++))
}

# Helper: run command on infra server (locally with sudo or via SSH)
ssh_opts=(-o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
ssh_target="${lab_infra_admin_username}@${lab_infra_server_hostname}"

fn_run_on_infra() {
    if $lab_infra_server_mode_is_host; then
        sudo bash -c "$1" 2>/dev/null
    else
        ssh "${ssh_opts[@]}" "$ssh_target" "sudo bash -c '$1'" 2>/dev/null
    fi
}

# --- DNS: Forward + Reverse lookup ---
dns_forward_result=$(fn_run_on_infra "dig +short ${lab_infra_server_hostname} A @${lab_infra_server_ipv4_address}")
if [[ "$dns_forward_result" == "$lab_infra_server_ipv4_address" ]]; then
    fn_deep_pass "DNS forward lookup ($lab_infra_server_hostname → $lab_infra_server_ipv4_address)"
else
    fn_deep_fail "DNS forward lookup ($lab_infra_server_hostname → expected $lab_infra_server_ipv4_address, got ${dns_forward_result:-NXDOMAIN})"
fi

dns_reverse_result=$(fn_run_on_infra "dig +short -x ${lab_infra_server_ipv4_address} @${lab_infra_server_ipv4_address}")
expected_ptr="${lab_infra_server_hostname}."
if [[ "$dns_reverse_result" == "$expected_ptr" ]]; then
    fn_deep_pass "DNS reverse lookup ($lab_infra_server_ipv4_address → $lab_infra_server_hostname)"
else
    fn_deep_fail "DNS reverse lookup ($lab_infra_server_ipv4_address → expected $expected_ptr, got ${dns_reverse_result:-NXDOMAIN})"
fi

# --- DHCP: kea-dhcp4 and kea-dhcp6 service active ---
kea_dhcp4_status=$(fn_run_on_infra "systemctl is-active kea-dhcp4")
if [[ "$kea_dhcp4_status" == "active" ]]; then
    fn_deep_pass "Kea DHCPv4 service active"
else
    fn_deep_fail "Kea DHCPv4 service (status: ${kea_dhcp4_status:-unknown})"
fi

kea_dhcp6_status=$(fn_run_on_infra "systemctl is-active kea-dhcp6")
if [[ "$kea_dhcp6_status" == "active" ]]; then
    fn_deep_pass "Kea DHCPv6 service active"
else
    fn_deep_fail "Kea DHCPv6 service (status: ${kea_dhcp6_status:-unknown})"
fi

# --- NTP: chronyd active and synchronized ---
chrony_status=$(fn_run_on_infra "systemctl is-active chronyd")
if [[ "$chrony_status" == "active" ]]; then
    fn_deep_pass "Chronyd service active"
else
    fn_deep_fail "Chronyd service (status: ${chrony_status:-unknown})"
fi

chrony_sync=$(fn_run_on_infra "chronyc tracking 2>/dev/null | grep -c 'Leap status.*Normal'")
if [[ "$chrony_sync" == "1" ]]; then
    fn_deep_pass "NTP synchronized (chrony leap status normal)"
else
    fn_deep_fail "NTP not synchronized (chrony leap status abnormal)"
fi

# --- TFTP: ipxe.efi exists in TFTP root ---
tftp_file_check=$(fn_run_on_infra "test -f /var/lib/tftpboot/ipxe.efi && echo yes")
if [[ "$tftp_file_check" == "yes" ]]; then
    fn_deep_pass "TFTP boot file exists (/var/lib/tftpboot/ipxe.efi)"
else
    fn_deep_fail "TFTP boot file missing (/var/lib/tftpboot/ipxe.efi)"
fi

# --- NFS: expected export exists ---
nfs_export_check=$(fn_run_on_infra "exportfs -v 2>/dev/null | grep -c /tux2lab-data")
if [[ "$nfs_export_check" -ge 1 ]] 2>/dev/null; then
    fn_deep_pass "NFS export available (/tux2lab-data)"
else
    fn_deep_fail "NFS export not found (/tux2lab-data)"
fi

# --- Web/Nginx: HTTP and HTTPS responses ---
http_code=$(fn_run_on_infra "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 http://${lab_infra_server_hostname}/")
if [[ "$http_code" == "200" ]]; then
    fn_deep_pass "Nginx HTTP response (200 OK)"
else
    fn_deep_fail "Nginx HTTP response (got ${http_code:-timeout})"
fi

https_code=$(fn_run_on_infra "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 https://${lab_infra_server_hostname}/")
if [[ "$https_code" == "200" ]]; then
    fn_deep_pass "Nginx HTTPS response (200 OK, cert trusted by system CA)"
else
    fn_deep_fail "Nginx HTTPS response (got ${https_code:-timeout}, cert may not be in trust store)"
fi

# -------------------------------------------------------------
# Summary
# -------------------------------------------------------------
total_services=${#services_to_check[@]}
total_deep=$((deep_pass + deep_fail))
print_cyan "--------------------------------------------------------------
Health Check Summary of tux2lab:
Port Reachability : $active_services/$total_services services reachable
Deep Validation   : $deep_pass/$total_deep checks passed
-------------------------------------------------------------"
if [[ $active_services -eq 0 ]]; then
    print_error "tux2lab health is CRITICAL."
    print_info "All services are down. Try: tux2lab start"
    print_cyan "-------------------------------------------------------------"
    exit 2
elif [[ $total_services -eq $active_services ]] && [[ $deep_fail -eq 0 ]]; then
    print_success "tux2lab health is STABLE."
    print_cyan "-------------------------------------------------------------"
    exit 0
else
    print_warning "tux2lab health is DEGRADED."
    if [[ $inactive_services -gt 0 ]]; then
        print_info "Some services are unreachable. Try: tux2lab start"
    fi
    if [[ $deep_fail -gt 0 ]]; then
        print_info "$deep_fail deep validation check(s) failed."
    fi
    print_cyan "-------------------------------------------------------------"
    exit 1
fi
