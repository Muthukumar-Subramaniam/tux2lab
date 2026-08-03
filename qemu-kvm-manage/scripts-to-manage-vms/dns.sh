#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: dns.sh                                                               #
# Description: Manage DNS records for the tux2lab infrastructure                         #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# Let dnsbinder handle --help directly (no resolvectl needed for help)
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sudo /tux2lab/named-manage/dnsbinder.sh --help
    exit 0
fi

# ====== PREREQUISITE: labbr0 must be up ======
if ! ip link show labbr0 &>/dev/null; then
    print_error "labbr0 interface is not available!"
    print_info "Start the lab infrastructure first: tux2lab start"
    exit 1
fi

# ====== CONFIGURE DNS RESOLUTION ======
print_task "Configuring DNS resolution for lab infra via resolvectl..."

current_dns_servers="$(resolvectl dns labbr0 2>/dev/null || true)"
current_dns_domains="$(resolvectl domain labbr0 2>/dev/null || true)"

if grep -qw "${lab_infra_server_ipv4_address}" <<< "${current_dns_servers}" && \
   grep -qw "${lab_infra_server_ipv6_address}" <<< "${current_dns_servers}" && \
   grep -qw "~${lab_infra_domain_name}" <<< "${current_dns_domains}"; then
   print_task_done
else
    if error_msg=$(sudo resolvectl dns labbr0 "${lab_infra_server_ipv4_address}" "${lab_infra_server_ipv6_address}" 2>&1) && \
       error_msg=$(sudo resolvectl domain labbr0 "~${lab_infra_domain_name}" 2>&1); then
        print_task_done
    else
        print_task_fail
        print_error "$error_msg"
        exit 1
    fi
fi

# ====== INVOKE DNSBINDER ======
print_info "Invoking dnsbinder utility..."

exit_code=0
sudo /tux2lab/named-manage/dnsbinder.sh "$@" || exit_code=$?

source /tux2lab/shared-functions/flush-dns-cache.sh
flush_dns_cache

exit $exit_code
