#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: health.sh                                                            #
# Description: tux2lab Health Check Tool                                                 #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
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

print_cyan "-------------------------------------------------------------
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
# Summary
# -------------------------------------------------------------
total_services=${#services_to_check[@]}
print_cyan "-------------------------------------------------------------
Health Check Summary of tux2lab:
Total Services    : $total_services
Active Services   : $active_services
Inactive Services : $inactive_services
-------------------------------------------------------------"
if [[ $active_services -eq 0 ]]; then
    print_error "tux2lab health is CRITICAL."
    print_info "All services are down. Try: tux2lab start"
    print_cyan "-------------------------------------------------------------"
    exit 2
elif [[ $total_services -eq $active_services ]]; then
    print_success "tux2lab health is STABLE."
    print_cyan "-------------------------------------------------------------"
    exit 0
else
    print_warning "tux2lab health is DEGRADED."
    print_info "Some services are down. Try: tux2lab start"
    print_cyan "-------------------------------------------------------------"
    exit 1
fi
