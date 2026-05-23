#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: destroy.sh                                                               #
# Description: Permanently destroy the entire tux2lab environment                        #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh

# ====== FLAG PARSING ======
wipe_iso_files=false

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            print_cyan "USAGE:
    tux2lab destroy [OPTIONS]

DESCRIPTION:
    Permanently destroys the entire tux2lab environment, including:
      - All virtual machines and their data
      - The lab infrastructure server (VM or host services)
      - Lab network configuration
      - Lab data files (/tux2lab-data/ contents, excluding ISOs)
      - SSH keys and configuration for lab access
      - tux2lab-lab-infra systemd service

    Downloaded ISO files are preserved by default.

    After destruction, start fresh from setup-qemu-kvm.sh to rebuild your lab.

OPTIONS:
    --wipe-iso-files-too    Also delete downloaded ISO files
    -h, --help              Show this help message

    Requires typing 'DESTROY-THE-LAB-AND-ALL-ITS-DATA' to confirm."
            exit 0
            ;;
        --wipe-iso-files-too)
            wipe_iso_files=true
            ;;
        *)
            print_error "Unknown argument: $arg"
            echo "Run 'tux2lab destroy --help' for usage information."
            exit 1
            ;;
    esac
done

if [[ "$EUID" -eq 0 ]]; then
    print_error "Running as root user is not allowed."
    print_info "This script should be run as a user with sudo privileges, not as root."
    exit 1
fi

# ====== SUMMARY COUNTERS ======
completed_steps=0
skipped_steps=0
failed_steps=0

# ====== SOURCE ENVIRONMENT (OPTIONAL — PROCEED EVEN IF MISSING) ======
LAB_ENV_VARS_FILE="/tux2lab-data/lab_environment_vars"
lab_infra_server_hostname=""
lab_infra_domain_name=""

if [[ -f "$LAB_ENV_VARS_FILE" ]]; then
    source "$LAB_ENV_VARS_FILE"
fi

# ====== HEADER ======
print_cyan "═══════════════════════════════════════════════════════════════════"
print_red  "              DESTROY LAB — COMPLETE LAB TEARDOWN"
print_cyan "═══════════════════════════════════════════════════════════════════"

echo
print_warning "This operation will PERMANENTLY DESTROY:"
print_warning "  • All virtual machines and their data"
if [[ -n "$lab_infra_server_hostname" ]]; then
    print_warning "  • Lab infrastructure server (${lab_infra_server_hostname})"
else
    print_warning "  • Lab infrastructure server"
fi
print_warning "  • Lab network bridge and virtual network"
print_warning "  • Lab data in /tux2lab-data/ (env vars, VM disks, ksmanager data)"
print_warning "  • SSH keys and config for lab access"
print_warning "  • tux2lab-lab-infra systemd service"

if $wipe_iso_files; then
    print_warning "  • Downloaded ISO files (--wipe-iso-files-too)"
else
    print_info "  ISO files will be PRESERVED (use --wipe-iso-files-too to remove)"
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
print_red "THIS ACTION CANNOT BE UNDONE."
echo
echo -n "Type DESTROY-THE-LAB-AND-ALL-ITS-DATA to confirm: "
read -r confirmation

if [[ "${confirmation}" != "DESTROY-THE-LAB-AND-ALL-ITS-DATA" ]]; then
    print_info "Operation cancelled. Your lab is safe."
    exit 0
fi

print_cyan "═══════════════════════════════════════════════════════════════════"

# ====== STEP 1: FORCE STOP ALL RUNNING VMs ======
running_vms=$(sudo virsh list --state-running --name 2>/dev/null | grep -v "^$" || true)
if [[ -n "$running_vms" ]]; then
    while IFS= read -r vm_name; do
        [[ -z "$vm_name" ]] && continue
        print_task "Force stopping VM \"${vm_name}\"..."
        if sudo virsh destroy "$vm_name" >/dev/null 2>&1; then
            print_task_done
            ((++completed_steps))
        else
            print_task_fail
            ((++failed_steps))
        fi
    done <<< "$running_vms"
else
    print_task "Force stopping running VMs..."
    print_task_skip
    ((++skipped_steps))
fi

# ====== STEP 2: UNDEFINE ALL VMs ======
all_vms=$(sudo virsh list --all --name 2>/dev/null | grep -v "^$" || true)
if [[ -n "$all_vms" ]]; then
    while IFS= read -r vm_name; do
        [[ -z "$vm_name" ]] && continue
        print_task "Undefining VM \"${vm_name}\"..."
        if sudo virsh undefine "$vm_name" --nvram >/dev/null 2>&1; then
            print_task_done
            ((++completed_steps))
        elif sudo virsh undefine "$vm_name" >/dev/null 2>&1; then
            print_task_done
            ((++completed_steps))
        else
            print_task_fail
            print_warning "Could not undefine VM \"${vm_name}\""
            ((++failed_steps))
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
    print_task "Removing VMs from libvirt..."
    print_task_skip
    ((++skipped_steps))
fi

# ====== STEP 3: STOP AND REMOVE SYSTEMD SERVICE ======
print_task "Stopping and removing tux2lab-lab-infra.service..."
if systemctl list-unit-files tux2lab-lab-infra.service &>/dev/null 2>&1; then
    sudo systemctl stop tux2lab-lab-infra.service --no-block 2>/dev/null || true
    sudo systemctl disable tux2lab-lab-infra.service 2>/dev/null || true
    sudo rm -f /etc/systemd/system/tux2lab-lab-infra.service
    sudo systemctl daemon-reload
    print_task_done
    ((++completed_steps))
else
    print_task_skip
    ((++skipped_steps))
fi

# ====== STEP 4: STOP HOST-MODE LAB SERVICES ======
# Detect if any host-mode artifacts exist on this machine
host_services=("nginx" "nfs-server" "tftp.socket" "kea-ctrl-agent" "kea-dhcp4" "kea-dhcp6" "radvd" "named")
host_mode_detected=false
for service_name in "${host_services[@]}"; do
    if systemctl is-enabled "$service_name" &>/dev/null || systemctl is-active "$service_name" &>/dev/null; then
        host_mode_detected=true
        break
    fi
done
if ! $host_mode_detected; then
    # Also check for other host-mode artifacts
    if systemctl list-unit-files tux2lab-iso-mounts.service &>/dev/null 2>&1 || \
       ip link show dummy-vnet &>/dev/null 2>&1 || \
       [[ -f /etc/chrony.d/tux2lab.conf ]] || \
       [[ -f /etc/named.conf ]] || \
       grep -q -E '^(dnsbinder_|mgmt_super_user|mgmt_interface_name)' /etc/environment 2>/dev/null; then
        host_mode_detected=true
    fi
fi

if $host_mode_detected; then
    print_info "Stopping and disabling host-mode lab services..."
    for service_name in "${host_services[@]}"; do
        print_task "Stopping and disabling ${service_name}..."
        if systemctl is-enabled "$service_name" &>/dev/null || systemctl is-active "$service_name" &>/dev/null; then
            sudo systemctl stop "$service_name" 2>/dev/null || true
            if sudo systemctl disable "$service_name" 2>/dev/null; then
                print_task_done
                ((++completed_steps))
            else
                print_task_fail
                ((++failed_steps))
            fi
        else
            print_task_skip
            ((++skipped_steps))
        fi
    done

    # Stop, disable and remove tux2lab-iso-mounts service
    print_task "Stopping and removing tux2lab-iso-mounts.service..."
    if systemctl list-unit-files tux2lab-iso-mounts.service &>/dev/null 2>&1; then
        sudo systemctl stop tux2lab-iso-mounts.service 2>/dev/null || true
        sudo systemctl disable tux2lab-iso-mounts.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/tux2lab-iso-mounts.service
        sudo systemctl daemon-reload
        print_task_done
        ((++completed_steps))
    else
        print_task_skip
        ((++skipped_steps))
    fi

    # Remove dummy interface
    print_task "Removing dummy interface dummy-vnet..."
    if ip link show dummy-vnet &>/dev/null; then
        sudo ip link set dummy-vnet down 2>/dev/null || true
        sudo ip link del dummy-vnet 2>/dev/null || true
        print_task_done
        ((++completed_steps))
    else
        print_task_skip
        ((++skipped_steps))
    fi

    # Remove chrony tux2lab drop-in config (chrony stays running)
    print_task "Removing chrony tux2lab drop-in config..."
    if [[ -f /etc/chrony.d/tux2lab.conf ]]; then
        sudo rm -f /etc/chrony.d/tux2lab.conf
        sudo systemctl restart chronyd 2>/dev/null || true
        print_task_done
        ((++completed_steps))
    else
        print_task_skip
        ((++skipped_steps))
    fi

    # Remove firewalld trusted zone rules for lab network
    print_task "Removing firewalld trusted zone rules..."
    if systemctl is-active firewalld &>/dev/null; then
        trusted_sources=$(sudo firewall-cmd --permanent --zone=trusted --list-sources 2>/dev/null || true)
        if [[ -n "$trusted_sources" ]]; then
            for src in $trusted_sources; do
                sudo firewall-cmd --permanent --zone=trusted --remove-source="$src" &>/dev/null || true
            done
            sudo firewall-cmd --reload &>/dev/null || true
            print_task_done
            ((++completed_steps))
        else
            print_task_skip
            ((++skipped_steps))
        fi
    else
        print_task_skip
        ((++skipped_steps))
    fi
fi

# ====== STEP 5: CLEAN /etc/hosts ENTRIES ======
print_task "Cleaning lab entries from /etc/hosts..."
if [[ -n "$lab_infra_domain_name" ]] && grep -q "${lab_infra_domain_name}" /etc/hosts 2>/dev/null; then
    # Escape dots for regex (sufficient for valid domain names)
    escaped_domain="${lab_infra_domain_name//./\\.}"
    sudo sed -i "/${escaped_domain}/d" /etc/hosts 2>/dev/null || true
    print_task_done
    ((++completed_steps))
else
    print_task_skip
    ((++skipped_steps))
fi

# ====== STEP 6: REMOVE SSH ARTIFACTS ======
print_task "Removing SSH artifacts..."
if [[ -f "$HOME/.ssh/tux2lab_id_rsa" ]] || [[ -f /etc/ssh/ssh_config.d/999-tux2lab.conf ]]; then
    rm -f "$HOME/.ssh/tux2lab_id_rsa" "$HOME/.ssh/tux2lab_id_rsa.pub" 2>/dev/null || true

    # Remove tux2lab key from authorized_keys
    if [[ -f "$HOME/.ssh/authorized_keys" ]] && [[ -n "$lab_infra_domain_name" ]]; then
        escaped_domain="${lab_infra_domain_name//./\\.}"
        sed -i "/${escaped_domain}/d" "$HOME/.ssh/authorized_keys" 2>/dev/null || true
    fi

    # Remove system-wide SSH config
    sudo rm -f /etc/ssh/ssh_config.d/999-tux2lab.conf 2>/dev/null || true

    # Remove lab entries from user SSH config.custom
    if [[ -f "$HOME/.ssh/config.custom" ]]; then
        sed -i '/# tux2lab SSH Config - Start/,/# tux2lab SSH Config - End/d' "$HOME/.ssh/config.custom" 2>/dev/null || true
        sed -i '/# KVM Lab SSH Config - Start/,/# KVM Lab SSH Config - End/d' "$HOME/.ssh/config.custom" 2>/dev/null || true
    fi
    print_task_done
    ((++completed_steps))
else
    print_task_skip
    ((++skipped_steps))
fi

# ====== STEP 7: DESTROY VIRTUAL NETWORK ======
print_task "Destroying tux2lab virtual network..."
if sudo virsh net-info tux2lab &>/dev/null || ip link show labbr0 &>/dev/null; then
    sudo virsh net-destroy tux2lab &>/dev/null || true
    sudo virsh net-undefine tux2lab &>/dev/null || true
    if ip link show labbr0 &>/dev/null; then
        sudo ip addr flush dev labbr0 2>/dev/null || true
    fi
    print_task_done
    ((++completed_steps))
else
    print_task_skip
    ((++skipped_steps))
fi

# ====== STEP 8: STOP AND DISABLE LIBVIRTD ======
print_task "Stopping and disabling libvirtd..."
if systemctl is-enabled libvirtd &>/dev/null || systemctl is-active libvirtd &>/dev/null; then
    sudo systemctl stop libvirtd libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket 2>/dev/null || true
    sudo systemctl disable libvirtd libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket 2>/dev/null || true
    print_task_done
    ((++completed_steps))
else
    print_task_skip
    ((++skipped_steps))
fi

# ====== STEP 9: WIPE /tux2lab-data/ CONTENTS ======
# Remove host-mode config artifacts (named.conf, /etc/environment)
if $host_mode_detected; then
    print_task "Removing named.conf..."
    if [[ -f /etc/named.conf ]]; then
        sudo rm -f /etc/named.conf /etc/named.conf_bkp_by_dnsbinder
        print_task_done
        ((++completed_steps))
    else
        print_task_skip
        ((++skipped_steps))
    fi

    print_task "Removing tux2lab variables from /etc/environment..."
    if grep -q -E '^(dnsbinder_|mgmt_super_user|mgmt_interface_name)' /etc/environment 2>/dev/null; then
        sudo sed -i '/^dnsbinder_/d; /^mgmt_super_user/d; /^mgmt_interface_name/d' /etc/environment
        print_task_done
        ((++completed_steps))
    else
        print_task_skip
        ((++skipped_steps))
    fi
fi

# Unmount any active mounts under /tux2lab-data/ (bind mounts, ISO mounts)
print_task "Unmounting active mounts under /tux2lab-data/..."
if findmnt --list --output TARGET | grep -q '/tux2lab-data/'; then
    findmnt --list --output TARGET | grep '/tux2lab-data/' | sort -r | while IFS= read -r mnt; do
        sudo umount -l "$mnt" 2>/dev/null || true
    done
    print_task_done
    ((++completed_steps))
else
    print_task_skip
    ((++skipped_steps))
fi

# Clean fstab entries for mounts under /tux2lab-data/ (bind mounts, ISO mounts)
print_task "Removing /tux2lab-data/ fstab entries..."
if grep -q '/tux2lab-data/' /etc/fstab 2>/dev/null; then
    sudo sed -i '\|/tux2lab-data/|d' /etc/fstab
    sudo systemctl daemon-reload
    print_task_done
    ((++completed_steps))
else
    print_task_skip
    ((++skipped_steps))
fi

if [[ -d "/tux2lab-data" ]]; then
    if $wipe_iso_files; then
        print_task "Wiping /tux2lab-data/ contents (including ISOs)..."
        if compgen -G "/tux2lab-data/*" >/dev/null 2>&1; then
            sudo rm -rf /tux2lab-data/*
            print_task_done
            ((++completed_steps))
        else
            print_task_skip
            ((++skipped_steps))
        fi
    else
        # Check if anything besides iso-files/ exists
        has_content=false
        for item in /tux2lab-data/*; do
            [[ ! -e "$item" ]] && continue
            [[ "$(basename "$item")" == "iso-files" ]] && continue
            has_content=true
            break
        done
        print_task "Wiping /tux2lab-data/ contents (preserving ISOs)..."
        if $has_content; then
            for item in /tux2lab-data/*; do
                [[ "$(basename "$item")" == "iso-files" ]] && continue
                sudo rm -rf "$item"
            done
            print_task_done
            ((++completed_steps))
        else
            print_task_skip
            ((++skipped_steps))
        fi
    fi
fi

# ====== SUMMARY ======
print_cyan "═══════════════════════════════════════════════════════════════════"
if [[ $completed_steps -eq 0 && $failed_steps -eq 0 ]]; then
    print_success "Lab is already clean — nothing left to destroy."
elif [[ $failed_steps -eq 0 ]]; then
    print_success "Lab has been completely destroyed."
else
    print_warning "Lab destruction completed with ${failed_steps} failed step(s)."
fi
echo
print_info "Summary: ${completed_steps} completed, ${skipped_steps} skipped, ${failed_steps} failed"
if ! $wipe_iso_files && [[ -d "/tux2lab-data/iso-files" ]]; then
    print_info "ISO files preserved at /tux2lab-data/iso-files/"
fi
echo
print_info "To rebuild your lab, run: tux2lab deploy"
print_cyan "═══════════════════════════════════════════════════════════════════"

exit 0
