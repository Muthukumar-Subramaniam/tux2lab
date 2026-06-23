#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: sync.sh                                                                  #
# Description: Sync /tux2lab from the KVM host to the lab infra server VM                #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh

# ====== HELP ======
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    print_cyan "USAGE:
    tux2lab sync

DESCRIPTION:
    Syncs the /tux2lab directory from the KVM host to the lab infra server VM
    and applies the lab infra services configuration.

    Use this after pulling updates on the host (git pull) to push the
    latest code to the infra server VM. The .git directory is excluded.

    If the server is already at the same version, you will be prompted
    before proceeding.

    In host mode, sync is skipped (code is already local) but lab infra
    services configuration is still applied."
    exit 0
fi

# ====== VALIDATE ======
LAB_ENV_VARS_FILE="/tux2lab-data/lab_environment_vars"

if [[ ! -f "$LAB_ENV_VARS_FILE" ]]; then
    print_error "No lab deployment found."
    print_info "Run 'tux2lab deploy' first."
    exit 1
fi

source "$LAB_ENV_VARS_FILE"

if ${lab_infra_server_mode_is_host:-false}; then
    print_info "Running in host mode — /tux2lab is already local. Skipping sync."
    read -rp "Re-apply lab infra services configuration? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        exit 0
    fi
    if ! bash /tux2lab/configure-lab-infra-server/configure-lab-infra-server.sh; then
        print_error "Failed to apply lab infra services configuration"
        exit 1
    fi
    exit 0
fi

# ====== VERSION CHECK ======
local_ssh_opts="-i ${HOME}/.ssh/tux2lab_id_rsa -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"

local_version=$(grep -o '"version": *"[^"]*"' /tux2lab/project_version.json | cut -d'"' -f4)

print_task "Checking version on ${lab_infra_server_hostname}..."
remote_version=$(ssh $local_ssh_opts "${lab_infra_admin_username}@${lab_infra_server_ipv4_address}" \
    "grep -o '\"version\": *\"[^\"]*\"' /tux2lab/project_version.json | cut -d'\"' -f4" 2>/dev/null) || {
    print_task_fail
    print_error "Failed to connect to infra server VM"
    print_info "Is the VM running? Try: tux2lab health"
    exit 1
}
print_task_done

if [[ "$local_version" == "$remote_version" ]]; then
    print_info "Server is already at v${remote_version} (same as host)"
    read -rp "Sync anyway? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

# ====== SYNC ======
print_task "Syncing /tux2lab to ${lab_infra_server_hostname} (v${local_version})..."
if ! rsync -a --delete --exclude='.git' -e "ssh $local_ssh_opts" /tux2lab/ "${lab_infra_admin_username}@${lab_infra_server_ipv4_address}:/tux2lab/" 2>/dev/null; then
    print_task_fail
    print_error "Failed to sync /tux2lab to infra server VM"
    print_info "Is the VM running? Try: tux2lab health"
    exit 1
fi
print_task_done

# ====== APPLY CONFIGURATION ======
if ! ssh $local_ssh_opts "${lab_infra_admin_username}@${lab_infra_server_ipv4_address}" \
    "bash /tux2lab/configure-lab-infra-server/configure-lab-infra-server.sh" 2>/dev/null; then
    print_error "Failed to apply lab infra services configuration"
    exit 1
fi
