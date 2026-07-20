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

# ====== HELP ======
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_cyan "Domain   : ${lab_infra_domain_name}
IPv4 Net : ${lab_infra_server_ipv4_subnet}
IPv6 Net : ${lab_infra_server_ipv6_ula_subnet}

USAGE:
    tux2lab dns [options] [arguments]

DESCRIPTION:
    Manage DNS records for the lab infrastructure via dnsbinder.
    Run without arguments for an interactive menu.

OPTIONS (passed to dnsbinder):
    -c,    --create              Create a host record (dual-stack: A + AAAA)
    -d,    --delete              Delete a host record (removes A + AAAA)
    -dy                          Delete without confirmation
    -r,    --rename              Rename an existing host record
    -ry                          Rename without confirmation
    -cf,   --create-from-file    Create multiple host records from a file
    -cfy                         Create multiple host records without confirmation
    -cif,  --create-with-ip-file Create host records with specific IPs from a file
    -cify                        Create with specific IPs without confirmation
    -df,   --delete-from-file    Delete multiple host records from a file
    -dfy                         Delete multiple host records without confirmation
    -ci,   --create-with-ip      Create a host record with specific IPv4 (auto-generates IPv6)
    -cc,   --create-cname        Create a CNAME/Alias record
    -dc,   --delete-cname        Delete a CNAME/Alias record
    -dcy                         Delete CNAME without confirmation
    -q,    --query               Lookup any record and display all its relevant records
    -y,    --yes                 Append to any command to skip confirmation prompts
    --inline                     Suppress TUI (no screen clear/cursor control) for bulk operations
    --setup                      Configure DNS domain and server (admin/internal)"
    exit 0
fi

# ====== VALIDATE OPTION ======
if [[ $# -gt 0 ]]; then
    valid_options=(-c --create -d --delete -dy -r --rename -ry
                   -cf --create-from-file -cfy
                   -cif --create-with-ip-file -cify
                   -df --delete-from-file -dfy
                   -ci --create-with-ip -cc --create-cname
                   -dc --delete-cname -dcy
                   -q --query
                   --setup -y --yes --inline)
    option_is_valid=false
    for opt in "${valid_options[@]}"; do
        if [[ "$1" == "$opt" ]]; then
            option_is_valid=true
            break
        fi
    done
    if ! $option_is_valid; then
        print_error "Unknown option: $1"
        echo "Run 'tux2lab dns --help' for usage information."
        exit 1
    fi
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

exit $exit_code
