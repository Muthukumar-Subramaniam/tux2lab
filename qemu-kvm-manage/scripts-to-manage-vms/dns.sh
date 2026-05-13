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

# ====== HELP ======
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_cyan "USAGE:
    tux2lab dns [options] [arguments]

DESCRIPTION:
    Manage DNS records for the lab infrastructure via dnsbinder.
    Run without arguments for an interactive menu.

OPTIONS (passed to dnsbinder):
    -c              Create a host record (dual-stack: A + AAAA)
    -d              Delete a host record (removes A + AAAA)
    -dy             Delete without confirmation
    -r              Rename an existing host record
    -ry             Rename without confirmation
    -cf <file>      Create multiple host records from a file
    -cfy <file>     Create multiple host records without confirmation
    -cif <file>     Create host records with specific IPs from a file
    -cify <file>    Create with specific IPs without confirmation
    -df <file>      Delete multiple host records from a file
    -dfy <file>     Delete multiple host records without confirmation
    -ci             Create a host record with a specific IPv4
    -cc             Create a CNAME/Alias record
    -dc             Delete a CNAME/Alias record
    -dcy            Delete CNAME without confirmation"
    exit 0
fi

# ====== VALIDATE OPTION ======
if [[ $# -gt 0 ]]; then
    valid_options=(-c -d -dy -r -ry -cf -cfy -cif -cify -df -dfy -ci -cc -dc -dcy --setup)
    option_is_valid=false
    for opt in "${valid_options[@]}"; do
        if [[ "$1" == "$opt" ]]; then
            option_is_valid=true
            break
        fi
    done
    if ! $option_is_valid; then
        print_error "Invalid option \"$1\"!"
        print_info "Run 'tux2lab dns --help' for usage info."
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
print_task "Enabling DNS of lab infra with resolvectl"

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
print_info "Invoking dnsbinder utility from lab infra server..."

if $lab_infra_server_mode_is_host; then
    sudo /tux2lab/named-manage/dnsbinder.sh "$@"
    exit_code=$?
else
    # SSH connection options
    ssh_opts=(-o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
    ssh_target="${lab_infra_admin_username}@${lab_infra_server_hostname}"

    # Verify SSH connectivity before proceeding
    if ! ssh "${ssh_opts[@]}" -o ConnectTimeout=5 "$ssh_target" true &>/dev/null; then
        print_error "Cannot reach lab infra server via SSH."
        print_info "Ensure the infra server is running: tux2lab health"
        exit 1
    fi

    # Check if this is a file-based operation (-cf, -cfy, -df, -dfy, -cif, or -cify)
    file_based_option=""
    file_path=""

    if [[ $# -ge 2 ]] && { [[ "$1" == "-cf" ]] || [[ "$1" == "-cfy" ]] || [[ "$1" == "-df" ]] || [[ "$1" == "-dfy" ]] || [[ "$1" == "-cif" ]] || [[ "$1" == "-cify" ]]; }; then
        file_based_option="$1"
        file_path="$2"

        # Validate that file exists locally
        if [[ ! -f "$file_path" ]]; then
            print_error "File not found: $file_path"
            exit 1
        fi

        # Create secure temp file on remote server
        remote_temp_file=$(ssh "${ssh_opts[@]}" "$ssh_target" "mktemp /tmp/dnsbinder-bulk.XXXXXXXXXX")

        print_task "Transferring file to lab infra server..."
        if scp "${ssh_opts[@]}" "$file_path" "${ssh_target}:${remote_temp_file}" >/dev/null 2>&1; then
            print_task_done
        else
            print_task_fail
            print_error "Failed to transfer file to lab infra server"
            ssh "${ssh_opts[@]}" "$ssh_target" "rm -f '${remote_temp_file}'" >/dev/null 2>&1 || true
            exit 1
        fi

        # Execute dnsbinder with remote temp file
        ssh "${ssh_opts[@]}" -t "$ssh_target" "sudo /tux2lab/named-manage/dnsbinder.sh ${file_based_option} '${remote_temp_file}'"
        exit_code=$?

        # Cleanup remote temp file
        ssh "${ssh_opts[@]}" "$ssh_target" "rm -f '${remote_temp_file}'" >/dev/null 2>&1 || true
    else
        # Regular options - forward as-is
        ssh "${ssh_opts[@]}" -t "$ssh_target" "sudo /tux2lab/named-manage/dnsbinder.sh $(printf '%q ' "$@")"
        exit_code=$?
    fi
fi

exit $exit_code
