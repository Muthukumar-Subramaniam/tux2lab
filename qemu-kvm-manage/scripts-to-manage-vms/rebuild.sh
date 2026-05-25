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

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            print_cyan "USAGE:
    tux2lab rebuild [OPTIONS]

DESCRIPTION:
    Destroys ALL virtual machines (guests and infra server) and redeploys
    the lab infrastructure server.

    By default, the rebuild uses the saved configuration from the
    environment file — no interactive prompts for hostname, domain,
    or credentials.

    With --clean-state, the saved configuration is wiped and a fresh
    interactive deployment is launched (equivalent to destroy + deploy).

    This command will:
      1. Destroy ALL guest virtual machines and their data
      2. Destroy the lab infrastructure server (VM or host services)
      3. Redeploy the lab infrastructure server

OPTIONS:
    --clean-state   Wipe saved config and redeploy interactively (fresh start)
    -h, --help      Show this help message

PRESERVED (default mode):
    - Lab environment configuration (/tux2lab-data/lab_environment_vars)
    - SSH keys
    - Downloaded ISO files
    - Golden images
    - Network bridge definitions

PRESERVED (--clean-state mode):
    - Downloaded ISO files
    - Network bridge definitions

CONFIRMATION:
    Default mode:       Type 'REBUILD-THE-LAB-INFRA-SERVER'
    --clean-state mode: Type 'REBUILD-THE-LAB-INFRA-SERVER'

    Requires an existing lab deployment (environment file must exist)."
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
LAB_ENV_VARS_FILE="/tux2lab-data/lab_environment_vars"

if [[ ! -f "$LAB_ENV_VARS_FILE" ]]; then
    print_error "No existing lab deployment found."
    print_info "Cannot rebuild without an existing configuration."
    print_info "Run 'tux2lab deploy' to create a new lab from scratch."
    exit 1
fi

source "$LAB_ENV_VARS_FILE"

# Determine mode label
if ${lab_infra_server_mode_is_host:-false}; then
    mode_label="HOST"
else
    mode_label="VM"
fi

# ====== HEADER ======
print_cyan "═══════════════════════════════════════════════════════════════════"
if $clean_state; then
    print_yellow "         REBUILD LAB (CLEAN STATE) — FULL FRESH REBUILD"
else
    print_yellow "              REBUILD LAB — TEARDOWN + REDEPLOY"
fi
print_cyan "═══════════════════════════════════════════════════════════════════"

echo
print_info "Current lab configuration:"
print_info "  Hostname  : ${lab_infra_server_hostname}"
print_info "  Domain    : ${lab_infra_domain_name}"
print_info "  Mode      : ${mode_label}"
print_info "  Admin User: ${lab_infra_admin_username}"
print_info "  IPv4      : ${lab_infra_server_ipv4_address}"
print_info "  IPv6      : ${lab_infra_server_ipv6_address}"

echo
print_warning "This operation will DESTROY:"
print_warning "  • ALL guest virtual machines and their data"
print_warning "  • The lab infrastructure server (${lab_infra_server_hostname})"
if $clean_state; then
    print_warning "  • Saved lab configuration (environment file)"
    print_warning "  • SSH keys for lab access"
    print_warning "  • All golden images"
fi

echo
if $clean_state; then
    print_info "After teardown, a FRESH interactive deployment will launch."
    print_info "You will be prompted for hostname, domain, and credentials."
    echo
    print_info "The following will be PRESERVED:"
    print_info "  • Downloaded ISO files"
    print_info "  • Network bridge definitions"
else
    print_info "After teardown, the lab will be redeployed using saved configuration."
    echo
    print_info "The following will be PRESERVED:"
    print_info "  • Lab environment configuration"
    print_info "  • SSH keys"
    print_info "  • Downloaded ISO files"
    print_info "  • Network bridge definitions"
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
if $clean_state; then
    echo -n "Type REBUILD-THE-LAB-INFRA-SERVER to confirm: "
    read -r confirmation
    if [[ "${confirmation}" != "REBUILD-THE-LAB-INFRA-SERVER" ]]; then
        print_info "Operation cancelled. Your lab is safe."
        exit 0
    fi
else
    echo -n "Type REBUILD-THE-LAB-INFRA-SERVER to confirm: "
    read -r confirmation
    if [[ "${confirmation}" != "REBUILD-THE-LAB-INFRA-SERVER" ]]; then
        print_info "Operation cancelled. Your lab is safe."
        exit 0
    fi
fi

print_cyan "═══════════════════════════════════════════════════════════════════"
print_info "Phase 1: Tearing down existing lab..."
print_cyan "--------------------------------------------------------------"

# ====== STEP 1: FORCE STOP ALL RUNNING VMs ======
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

# ====== STEP 2: UNDEFINE ALL VMs ======
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

# ====== STEP 3: STOP AND REMOVE SYSTEMD SERVICE ======
if systemctl list-unit-files tux2lab.service &>/dev/null 2>&1; then
    print_task "Stopping and removing tux2lab.service..."
    sudo systemctl stop tux2lab.service --no-block 2>/dev/null || true
    sudo systemctl disable tux2lab.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/tux2lab.service
    sudo systemctl daemon-reload
    print_task_done
fi

# ====== STEP 4: STOP HOST-MODE LAB SERVICES (IF APPLICABLE) ======
if ${lab_infra_server_mode_is_host:-false}; then
    print_info "Stopping host-mode lab services..."
    host_services=("nginx" "nfs-server" "tftp.socket" "kea-ctrl-agent" "kea-dhcp4" "kea-dhcp6" "radvd" "named")
    for service_name in "${host_services[@]}"; do
        print_task "Stopping ${service_name}..."
        if sudo systemctl stop "$service_name" 2>/dev/null; then
            print_task_done
        else
            print_task_fail
        fi
    done

    # Stop, disable and remove tux2lab-iso-mounts service
    if systemctl list-unit-files tux2lab-iso-mounts.service &>/dev/null 2>&1; then
        print_task "Stopping and removing tux2lab-iso-mounts.service..."
        sudo systemctl stop tux2lab-iso-mounts.service 2>/dev/null || true
        sudo systemctl disable tux2lab-iso-mounts.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/tux2lab-iso-mounts.service
        sudo systemctl daemon-reload
        print_task_done
    fi

    # Clean infra server ISO fstab entry
    if grep -q '/tux2lab-data/os-repos/.*iso9660' /etc/fstab 2>/dev/null; then
        print_task "Removing infra server ISO fstab entry..."
        sudo sed -i '\|/tux2lab-data/os-repos/.*iso9660|d' /etc/fstab
        sudo systemctl daemon-reload
        print_task_done
    fi

    # Remove dummy interface
    if ip link show dummy-vnet &>/dev/null; then
        print_task "Removing dummy interface dummy-vnet..."
        sudo ip link set dummy-vnet down 2>/dev/null || true
        sudo ip link del dummy-vnet 2>/dev/null || true
        print_task_done
    fi
fi

# ====== STEP 5: CLEAN /etc/hosts LAB ENTRIES ======
if [[ -n "$lab_infra_domain_name" ]]; then
    print_task "Cleaning lab entries from /etc/hosts..."
    escaped_domain="${lab_infra_domain_name//./\\.}"
    sudo sed -i.bak "/${escaped_domain}/d" /etc/hosts 2>/dev/null || true
    print_task_done
fi

# ====== STEP 6: WIPE VM DIRECTORIES (KEEP ISO, ENV FILE) ======
if [[ -d "/tux2lab-data/vms" ]]; then
    print_task "Wiping VM directories..."
    sudo rm -rf /tux2lab-data/vms/*
    print_task_done
fi

# ====== STEP 7: CLEAN KSMANAGER DATA ======
# In VM mode, ksmanager data lives inside the infra server VM — it's implicitly
# destroyed when the VM is undefined in step 2. In host mode, the data resides
# on the local filesystem and must be explicitly cleaned.
if ${lab_infra_server_mode_is_host:-false}; then
    ksmanager_hub_dir="/tux2lab-data/ksmanager-hub"
    if [[ -d "$ksmanager_hub_dir" ]]; then
        print_task "Cleaning ksmanager data..."
        sudo rm -rf "${ksmanager_hub_dir:?}/"*
        print_task_done
    fi
fi

# ====== STEP 8: CLEAN STATE — WIPE ENV FILE AND SSH ARTIFACTS ======
if $clean_state; then
    print_task "Wiping saved lab configuration..."
    rm -f "$LAB_ENV_VARS_FILE"
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
    sudo rm -f /etc/ssh/ssh_config.d/999-tux2lab.conf 2>/dev/null || true
    if [[ -f "$HOME/.ssh/config.custom" ]]; then
        sed -i '/# tux2lab SSH Config - Start/,/# tux2lab SSH Config - End/d' "$HOME/.ssh/config.custom" 2>/dev/null || true
        sed -i '/# KVM Lab SSH Config - Start/,/# KVM Lab SSH Config - End/d' "$HOME/.ssh/config.custom" 2>/dev/null || true
    fi
    print_task_done
fi

print_success "Teardown complete."

# ====== PHASE 2: REDEPLOY ======
print_cyan "--------------------------------------------------------------"
print_info "Phase 2: Redeploying lab infrastructure server..."
print_cyan "--------------------------------------------------------------"

if $clean_state; then
    # Clean state: launch fresh interactive deployment
    exec /tux2lab/qemu-kvm-manage/deploy-lab-infra-server.sh
else
    # Default: non-interactive rebuild using saved env file
    exec /tux2lab/qemu-kvm-manage/deploy-lab-infra-server.sh --rebuild
fi
