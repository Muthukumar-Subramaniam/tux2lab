#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: rebuild.sh                                                               #
# Description: Tear down and redeploy the lab infra server using existing configuration  #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh

# ====== FLAG PARSING ======
clean_state=false

declare -A _seen_args
for arg in "$@"; do
    if [[ -n "${_seen_args[$arg]:-}" ]]; then
        print_error "Duplicate argument: $arg"
        exit 1
    fi
    _seen_args["$arg"]=1
    case "$arg" in
        -h|--help)
            print_cyan "USAGE:
    tux2lab rebuild [OPTIONS]

DESCRIPTION:
    Destroys ALL virtual machines (guests) and redeploys the lab
    infrastructure container using existing configuration.

    By default, the rebuild uses saved lab_environment.json — no
    interactive prompts.

    With --clean-state, the saved configuration is wiped and a fresh
    interactive deployment is launched (equivalent to destroy + deploy).

    This command will:
      1. Stop and remove the tux2lab-engine container
      2. Destroy ALL guest virtual machines and their data
      3. Regenerate service configs and restart the container

OPTIONS:
    --clean-state   Wipe saved config and redeploy interactively (fresh start)
    -h, --help      Show this help message

PRESERVED (default mode):
    - Lab environment configuration (lab_environment.json)
    - SSH keys and SSL certificates
    - Downloaded boot ISOs
    - Golden images
    - Network bridge definitions

PRESERVED (--clean-state mode):
    - Downloaded boot ISOs
    - Network bridge definitions

CONFIRMATION:
    Type 'REBUILD-THE-LAB-INFRA-SERVER' to proceed."
            exit 0
            ;;
        --clean-state)
            clean_state=true
            ;;
        *)
            print_error "Unknown argument: $arg"
            echo "Run 'tux2lab rebuild --help' for usage information."
            exit 1
            ;;
    esac
done

if [[ "$EUID" -eq 0 ]]; then
    print_error "Running as root user is not allowed."
    print_info "This script should be run as a user with sudo privileges, not as root."
    exit 1
fi

# ====== VALIDATE EXISTING DEPLOYMENT ======
readonly LAB_ENV_JSON="/tux2lab-data/lab-config/lab_environment.json"
readonly CONTAINER_NAME="tux2lab-engine"

if [[ ! -f "$LAB_ENV_JSON" ]]; then
    print_error "No existing lab deployment found."
    print_info "Cannot rebuild without existing configuration."
    print_info "Run 'tux2lab deploy' to create a new lab from scratch."
    exit 1
fi

lab_infra_server_hostname=$(jq -r '.lab.engine_fqdn' "$LAB_ENV_JSON")
lab_infra_domain_name=$(jq -r '.lab.domain' "$LAB_ENV_JSON")
lab_infra_admin_username=$(jq -r '.admin.username' "$LAB_ENV_JSON")
lab_infra_server_ipv4_address=$(jq -r '.network.ipv4.address' "$LAB_ENV_JSON")
lab_infra_server_ipv6_address=$(jq -r '.network.ipv6.address' "$LAB_ENV_JSON")

# ====== HEADER ======
print_cyan "═══════════════════════════════════════════════════════════════════"
if $clean_state; then
    print_yellow "         REBUILD LAB (CLEAN STATE) — FULL FRESH REBUILD"
else
    print_yellow "              REBUILD LAB — TEARDOWN + REDEPLOY"
fi
print_cyan "═══════════════════════════════════════════════════════════════════"

echo
print_cyan "Current lab configuration:
  Hostname  : ${lab_infra_server_hostname}
  Domain    : ${lab_infra_domain_name}
  Admin User: ${lab_infra_admin_username}
  IPv4      : ${lab_infra_server_ipv4_address}
  IPv6      : ${lab_infra_server_ipv6_address}
  Container : ${CONTAINER_NAME}"

echo
print_warning "This operation will DESTROY:
  • ALL guest virtual machines and their data
  • The tux2lab-engine container (will be restarted)"
if $clean_state; then
    print_warning "  • Saved lab configuration (lab_environment.json)
  • SSH keys and SSL certificates
  • All golden images"
fi

# ====== LIST VMs THAT WILL BE DESTROYED ======
all_vms=$(sudo virsh list --all --name 2>/dev/null | grep -v "^$" || true)
if [[ -n "$all_vms" ]]; then
    echo
    print_warning "The following VMs will be DESTROYED:"
    while IFS= read -r vm; do
        [[ -z "$vm" ]] && continue
        vm_state=$(sudo virsh domstate "$vm" 2>/dev/null || echo "unknown")
        print_warning "  - ${vm} (${vm_state})"
    done <<< "$all_vms"
fi

echo
echo -n "Type REBUILD-THE-LAB-INFRA-SERVER to confirm: "
read -r confirmation
if [[ "${confirmation}" != "REBUILD-THE-LAB-INFRA-SERVER" ]]; then
    print_info "Operation cancelled. Your lab is safe."
    exit 0
fi

print_cyan "═══════════════════════════════════════════════════════════════════"
print_info "Phase 1: Tearing down existing lab..."
print_cyan "--------------------------------------------------------------"

# ====== STEP 1: STOP AND REMOVE CONTAINER ======
print_task "Stopping tux2lab-engine container..."
if sudo podman container exists "${CONTAINER_NAME}" 2>/dev/null; then
    sudo podman stop "${CONTAINER_NAME}" &>/dev/null || true
    sudo podman rm -f "${CONTAINER_NAME}" &>/dev/null || true
    print_task_done
else
    print_task_skip
fi

# ====== STEP 2: FORCE STOP ALL RUNNING VMs ======
running_vms=$(sudo virsh list --state-running --name 2>/dev/null | grep -v "^$" || true)
if [[ -n "$running_vms" ]]; then
    print_info "Force stopping all running VMs..."
    while IFS= read -r vm_name; do
        [[ -z "$vm_name" ]] && continue
        print_task "Force stopping VM \"${vm_name}\"..."
        if sudo virsh destroy "$vm_name" >/dev/null 2>&1; then
            print_task_done
        else
            print_task_fail
        fi
    done <<< "$running_vms"
else
    print_info "No running VMs to stop."
fi

# ====== STEP 3: UNDEFINE ALL VMs ======
all_vms=$(sudo virsh list --all --name 2>/dev/null | grep -v "^$" || true)
if [[ -n "$all_vms" ]]; then
    print_info "Removing all VMs from libvirt..."
    while IFS= read -r vm_name; do
        [[ -z "$vm_name" ]] && continue
        print_task "Undefining VM \"${vm_name}\"..."
        if sudo virsh undefine "$vm_name" --nvram >/dev/null 2>&1; then
            print_task_done
        elif sudo virsh undefine "$vm_name" >/dev/null 2>&1; then
            print_task_done
        else
            print_task_fail
            print_warning "Could not undefine VM \"${vm_name}\""
        fi

        # Remove VM disk directory
        if [[ -d "/tux2lab-data/vms/${vm_name}" ]]; then
            sudo rm -rf "/tux2lab-data/vms/${vm_name}"
        fi

        # Remove storage pool if it exists
        if sudo virsh pool-info "$vm_name" &>/dev/null; then
            sudo virsh pool-destroy "$vm_name" &>/dev/null || true
            sudo virsh pool-undefine "$vm_name" &>/dev/null || true
        fi
    done <<< "$all_vms"
else
    print_info "No VMs to remove."
fi

# ====== STEP 4: WIPE VM DIRECTORIES ======
if [[ -d "/tux2lab-data/vms" ]]; then
    print_task "Wiping VM directories..."
    sudo rm -rf /tux2lab-data/vms/*
    print_task_done
fi

# ====== STEP 5: WIPE DNS ZONES (will be regenerated) ======
if [[ -d "/tux2lab-data/named/dnsbinder-managed-zone-files" ]]; then
    print_task "Wiping DNS zone files..."
    sudo rm -rf /tux2lab-data/named/dnsbinder-managed-zone-files
    sudo rm -f /tux2lab-data/named/named.conf
    print_task_done
fi

# ====== STEP 6: CLEAN KSMANAGER DATA ======
ksmanager_hub_dir="/tux2lab-data/ksmanager-hub"
if [[ -d "$ksmanager_hub_dir" ]]; then
    print_task "Cleaning ksmanager data..."
    sudo rm -rf "${ksmanager_hub_dir:?}/"*
    print_task_done
fi

# ====== STEP 7: CLEAN /etc/hosts LAB ENTRIES ======
if [[ -n "$lab_infra_domain_name" ]]; then
    print_task "Cleaning lab entries from /etc/hosts..."
    escaped_domain="${lab_infra_domain_name//./\\.}"
    sudo sed -i.bak "/${escaped_domain}/d" /etc/hosts 2>/dev/null || true
    print_task_done
fi

# ====== STEP 8: CLEAN STATE — WIPE CONFIG, KEYS, GOLDEN IMAGES ======
if $clean_state; then
    print_task "Wiping saved lab configuration..."
    rm -rf /tux2lab-data/lab-config
    print_task_done

    print_task "Removing golden images..."
    sudo rm -rf /tux2lab-data/golden-images-disk-store
    print_task_done

    print_task "Removing SSH artifacts..."
    rm -f "$HOME/.ssh/tux2lab_id_rsa" "$HOME/.ssh/tux2lab_id_rsa.pub" 2>/dev/null || true
    if [[ -f "$HOME/.ssh/authorized_keys" ]] && [[ -n "$lab_infra_domain_name" ]]; then
        escaped_domain="${lab_infra_domain_name//./\\.}"
        sed -i "/${escaped_domain}/d" "$HOME/.ssh/authorized_keys" 2>/dev/null || true
    fi
    rm -f "$HOME/.ssh/config.d/tux2lab.conf" 2>/dev/null || true
    print_task_done
fi

print_success "Teardown complete."

# ====== PHASE 2: REDEPLOY ======
print_cyan "--------------------------------------------------------------"
print_info "Phase 2: Redeploying lab infrastructure..."
print_cyan "--------------------------------------------------------------"

if $clean_state; then
    # Clean state: launch fresh interactive deployment
    exec /tux2lab/setup/deploy-lab.sh
else
    # Default: non-interactive rebuild using saved config
    exec /tux2lab/setup/deploy-lab.sh --rebuild
fi
