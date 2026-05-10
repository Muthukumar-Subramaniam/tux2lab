#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: dns.sh                                                               #
# Description: Manage DNS records for the KVM lab infrastructure                         #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

print_task "Enabling DNS of lab infra with resolvectl"

current_dns_servers="$(resolvectl dns labbr0 2>/dev/null || true)"
current_dns_domains="$(resolvectl domain labbr0 2>/dev/null || true)"

if grep -qw "${lab_infra_server_ipv4_address}" <<< "${current_dns_servers}" && \
   grep -qw "${lab_infra_server_ipv6_address}" <<< "${current_dns_servers}" && \
   grep -qw "~${lab_infra_domain_name}" <<< "${current_dns_domains}"; then
   print_task_done
else
    if ip link show labbr0 &>/dev/null; then
       if error_msg=$(sudo resolvectl dns labbr0 "${lab_infra_server_ipv4_address}" "${lab_infra_server_ipv6_address}" 2>&1) && \
          error_msg=$(sudo resolvectl domain labbr0 "~${lab_infra_domain_name}" 2>&1); then
           print_task_done
       else
           print_task_fail
           print_error "$error_msg"
           exit 1
       fi
    else
       print_task_fail
       print_error "labbr0 interface is not yet available!"
       exit 1
    fi
fi

print_info "Invoking dnsbinder utility from lab infra server..."

if $lab_infra_server_mode_is_host; then
    sudo /tux2lab/named-manage/dnsbinder.sh "$@"
    exit_code=$?
else
    # Check if this is a file-based operation (-cf or -df)
    file_based_option=""
    file_path=""
    
    if [[ $# -ge 2 ]] && { [[ "$1" == "-cf" ]] || [[ "$1" == "-df" ]]; }; then
        file_based_option="$1"
        file_path="$2"
        
        # Validate that file exists locally
        if [[ ! -f "$file_path" ]]; then
            print_error "File not found: $file_path"
            exit 1
        fi
        
        # Generate unique temp filename on remote server
        remote_temp_file="/tmp/dnsbinder-bulk-$(date +%s)-$$.txt"
        
        print_task "Transferring file to lab infra server..."
        if scp -o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$file_path" "${lab_infra_admin_username}@${lab_infra_server_hostname}:${remote_temp_file}" >/dev/null 2>&1; then
            print_task_done
        else
            print_task_fail
            print_error "Failed to transfer file to lab infra server"
            exit 1
        fi
        
        # Execute dnsbinder with remote temp file
        ssh -o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -t "${lab_infra_admin_username}@${lab_infra_server_hostname}" "sudo /tux2lab/named-manage/dnsbinder.sh ${file_based_option} '${remote_temp_file}'"
        exit_code=$?
        
        # Cleanup remote temp file
        ssh -o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "${lab_infra_admin_username}@${lab_infra_server_hostname}" "rm -f ${remote_temp_file}" >/dev/null 2>&1
    else
        # Regular options - forward as-is
        ssh -o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -t "${lab_infra_admin_username}@${lab_infra_server_hostname}" "sudo /tux2lab/named-manage/dnsbinder.sh $(printf '%q ' "$@")"
        exit_code=$?
    fi
fi

exit $exit_code
