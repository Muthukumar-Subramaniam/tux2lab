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
                   --setup -y --yes)
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
print_info "Invoking dnsbinder utility from lab infra server..."

exit_code=0

if $lab_infra_server_mode_is_host; then
    sudo /tux2lab/named-manage/dnsbinder.sh "$@" || exit_code=$?
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

    # Check if this is a file-based operation
    file_based_option=""
    file_path=""
    yes_flag=""

    # Detect trailing --yes / -y modifier
    for arg in "$@"; do
        if [[ "$arg" == "--yes" || "$arg" == "-y" ]]; then
            yes_flag="--yes"
        fi
    done

    if [[ $# -ge 2 ]] && { [[ "$1" == "-cf" ]] || [[ "$1" == "--create-from-file" ]] || [[ "$1" == "-cfy" ]] || [[ "$1" == "-df" ]] || [[ "$1" == "--delete-from-file" ]] || [[ "$1" == "-dfy" ]] || [[ "$1" == "-cif" ]] || [[ "$1" == "--create-with-ip-file" ]] || [[ "$1" == "-cify" ]]; }; then
        file_based_option="$1"
        file_path="$2"

        # Validate that file exists locally
        if [[ ! -f "$file_path" ]]; then
            print_error "File not found: $file_path"
            exit 1
        fi

        # Create secure temp file on remote server
        if ! remote_temp_file=$(ssh "${ssh_opts[@]}" "$ssh_target" "mktemp /tmp/dnsbinder-bulk.XXXXXXXXXX" 2>/dev/null); then
            print_error "Failed to create temp file on lab infra server."
            exit 1
        fi
        if [[ -z "$remote_temp_file" ]]; then
            print_error "Failed to create temp file on lab infra server."
            exit 1
        fi

        # Ensure remote temp file is cleaned up on exit or interrupt
        cleanup_remote_temp() {
            ssh "${ssh_opts[@]}" "$ssh_target" "rm -f '${remote_temp_file}'" >/dev/null 2>&1 || true
        }
        trap cleanup_remote_temp EXIT INT TERM

        print_task "Transferring file to lab infra server..."
        if scp "${ssh_opts[@]}" "$file_path" "${ssh_target}:${remote_temp_file}" >/dev/null 2>&1; then
            print_task_done
        else
            print_task_fail
            print_error "Failed to transfer file to lab infra server"
            exit 1
        fi

        # Execute dnsbinder with remote temp file
        ssh "${ssh_opts[@]}" -t "$ssh_target" "sudo /tux2lab/named-manage/dnsbinder.sh ${file_based_option} '${remote_temp_file}' ${yes_flag}" || exit_code=$?

        # Cleanup handled by trap, clear it
        cleanup_remote_temp
        trap - EXIT INT TERM
    else
        # Regular options - forward as-is
        args_escaped=$(printf '%q ' "$@")
        ssh "${ssh_opts[@]}" -t "$ssh_target" "sudo /tux2lab/named-manage/dnsbinder.sh ${args_escaped% }" || exit_code=$?
    fi
fi

exit $exit_code
