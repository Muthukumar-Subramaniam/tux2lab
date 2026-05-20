#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: cleanup-old-server-hub.sh                                                 #
# Description: Detect and remove all artifacts from the predecessor project (server-hub) #
#              before tux2lab setup begins. Migrates ISOs and checksums to tux2lab paths. #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh

if [[ "$EUID" -eq 0 ]]; then
    print_error "Running as root user is not allowed."
    print_info "This script should be run as a user with sudo privileges, not as root."
    exit 1
fi

# ====== PHASE 1: DETECTION ======
old_server_hub_dir="/server-hub"
old_kvm_hub_dir="/kvm-hub"
old_lab_env_vars_file="/kvm-hub/lab_environment_vars"
old_ssh_key="$HOME/.ssh/kvm_lab_global_id_rsa"
old_qlabvmctl="/usr/local/bin/qlabvmctl"

detected=false

if [[ -d "$old_server_hub_dir" ]]; then
    detected=true
elif [[ -d "$old_kvm_hub_dir" ]]; then
    detected=true
elif [[ -f "$old_lab_env_vars_file" ]]; then
    detected=true
elif [[ -L "$old_qlabvmctl" || -f "$old_qlabvmctl" ]]; then
    detected=true
elif [[ -f "$old_ssh_key" ]]; then
    detected=true
fi

if [[ "$detected" == false ]]; then
    # No server-hub deployment found — nothing to do
    exit 0
fi

# ====== SOURCE OLD ENVIRONMENT (OPTIONAL — PROCEED EVEN IF MISSING) ======
lab_infra_server_hostname=""
lab_infra_domain_name=""
lab_infra_server_mode_is_host=false

if [[ -f "$old_lab_env_vars_file" ]]; then
    source "$old_lab_env_vars_file" 2>/dev/null || true
fi

# ====== HEADER ======
print_cyan "═══════════════════════════════════════════════════════════════════"
print_yellow "     CLEANUP — Removing predecessor project (server-hub)"
print_cyan "═══════════════════════════════════════════════════════════════════"

echo
print_warning "A previous server-hub deployment has been detected on this system."
print_warning "The following will be PERMANENTLY REMOVED to prepare for tux2lab:"
echo
print_warning "  • All VMs with disks under /kvm-hub/vms/"
if [[ -n "$lab_infra_server_hostname" ]]; then
    print_warning "  • Lab infrastructure server (${lab_infra_server_hostname})"
fi
print_warning "  • All libvirt storage pools"
print_warning "  • Virtual network 'default' (labbr0)"
if [[ "$lab_infra_server_mode_is_host" == "true" ]]; then
    print_warning "  • Host-mode lab services (named, kea, nginx, etc.)"
    if [[ -n "$lab_infra_server_hostname" ]]; then
        print_warning "  • Web root directory (/${lab_infra_server_hostname}/)"
    fi
    print_warning "  • DNS zone files (/var/named/dnsbinder-managed-zone-files/)"
fi
print_warning "  • SSH keys and config (kvm_lab_global_id_rsa, 999-kvm-lab-global.conf)"
print_warning "  • CLI tools (qlabvmctl, qlabstart, qlabhealth, qlabdnsbinder, ksmanager)"
print_warning "  • Directories: /server-hub, /kvm-hub, /iso-files"
print_warning "  • /etc/sudoers.d/$USER"
if [[ -d "/iso-files" ]]; then
    print_info "  ISO files from /iso-files/ will be MIGRATED to /tux2lab-data/iso-files/"
fi

# ====== LIST VMs THAT WILL BE DESTROYED ======
old_vms=()
if sudo virsh list --all --name &>/dev/null; then
    while IFS= read -r vm; do
        [[ -z "$vm" ]] && continue
        disk_path=$(sudo virsh domblklist "$vm" 2>/dev/null | awk '/\/kvm-hub\/vms\// {print $2; exit}')
        if [[ -n "$disk_path" ]]; then
            old_vms+=("$vm")
        fi
    done < <(sudo virsh list --all --name 2>/dev/null | grep -v "^$")
fi

if [[ ${#old_vms[@]} -gt 0 ]]; then
    echo
    print_warning "The following VMs will be DESTROYED:"
    for vm in "${old_vms[@]}"; do
        vm_state=$(sudo virsh domstate "$vm" 2>/dev/null || echo "unknown")
        print_warning "  - ${vm} (${vm_state})"
    done
fi

echo
print_red "THIS ACTION CANNOT BE UNDONE."
echo
echo -n "Type CLEANUP-SERVER-HUB to confirm: "
read -r confirmation

if [[ "${confirmation}" != "CLEANUP-SERVER-HUB" ]]; then
    print_info "Cleanup cancelled. No changes were made."
    exit 0
fi

print_cyan "═══════════════════════════════════════════════════════════════════"

# ====== SUMMARY COUNTERS ======
completed_steps=0
skipped_steps=0
failed_steps=0

# ====== PHASE 2: STOP & UNDEFINE ALL VMs ======
if [[ ${#old_vms[@]} -gt 0 ]]; then
    # Force stop running VMs
    print_info "Force stopping running VMs..."
    for vm_name in "${old_vms[@]}"; do
        vm_state=$(sudo virsh domstate "$vm_name" 2>/dev/null || echo "unknown")
        if [[ "$vm_state" == "running" ]]; then
            print_task "Force stopping VM \"${vm_name}\"..."
            if sudo virsh destroy "$vm_name" >/dev/null 2>&1; then
                print_task_done
                ((++completed_steps))
            else
                print_task_fail
                ((++failed_steps))
            fi
        fi
    done

    # Undefine all VMs
    print_info "Removing all server-hub VMs from libvirt..."
    for vm_name in "${old_vms[@]}"; do
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
        if [[ -d "/kvm-hub/vms/${vm_name}" ]]; then
            sudo rm -rf "/kvm-hub/vms/${vm_name}"
        fi
    done
else
    print_info "No server-hub VMs to remove."
    ((++skipped_steps))
fi

# Bulk remove ALL storage pools
all_pools=$(sudo virsh pool-list --all --name 2>/dev/null | grep -v "^$" || true)
if [[ -n "$all_pools" ]]; then
    print_info "Removing all storage pools..."
    while IFS= read -r pool_name; do
        [[ -z "$pool_name" ]] && continue
        print_task "Removing storage pool \"${pool_name}\"..."
        sudo virsh pool-destroy "$pool_name" &>/dev/null || true
        if sudo virsh pool-undefine "$pool_name" &>/dev/null; then
            print_task_done
            ((++completed_steps))
        else
            print_task_fail
            ((++failed_steps))
        fi
    done <<< "$all_pools"
else
    print_info "No storage pools to remove."
    ((++skipped_steps))
fi

# ====== PHASE 3: HOST MODE EXTRAS ======
if [[ "$lab_infra_server_mode_is_host" == "true" ]]; then
    print_info "Stopping and disabling host-mode lab services..."
    host_services=("named" "kea-dhcp4" "kea-dhcp6" "radvd" "nfs-server" "tftp.socket" "nginx")
    for service_name in "${host_services[@]}"; do
        if systemctl list-unit-files "${service_name}.service" &>/dev/null 2>&1 || \
           systemctl list-unit-files "${service_name}" &>/dev/null 2>&1; then
            print_task "Stopping and disabling ${service_name}..."
            sudo systemctl stop "$service_name" 2>/dev/null || true
            if sudo systemctl disable "$service_name" 2>/dev/null; then
                print_task_done
                ((++completed_steps))
            else
                print_task_fail
                ((++failed_steps))
            fi
        fi
    done

    # Remove dummy-vnet interface
    if ip link show dummy-vnet &>/dev/null; then
        print_task "Removing dummy interface dummy-vnet..."
        sudo ip link set dummy-vnet down 2>/dev/null || true
        if sudo ip link del dummy-vnet 2>/dev/null; then
            print_task_done
            ((++completed_steps))
        else
            print_task_fail
            ((++failed_steps))
        fi
    fi

    # Remove dnsbinder zone files
    if [[ -d "/var/named/dnsbinder-managed-zone-files" ]]; then
        print_task "Removing DNS zone files (/var/named/dnsbinder-managed-zone-files/)..."
        if sudo rm -rf /var/named/dnsbinder-managed-zone-files; then
            print_task_done
            ((++completed_steps))
        else
            print_task_fail
            ((++failed_steps))
        fi
    fi

    # Remove web root directory (/<fqdn>/)
    if [[ -n "$lab_infra_server_hostname" && -d "/${lab_infra_server_hostname}" ]]; then
        # Unmount any filesystems mounted under the web root (ISOs, bind mounts)
        while IFS= read -r mount_point; do
            sudo umount -l "$mount_point" 2>/dev/null || true
        done < <(findmnt -rn -o TARGET | grep "^/${lab_infra_server_hostname}/" | sort -r)
        print_task "Removing web root directory (/${lab_infra_server_hostname}/)..."
        if sudo rm -rf "/${lab_infra_server_hostname}"; then
            print_task_done
            ((++completed_steps))
        else
            print_task_fail
            ((++failed_steps))
        fi
    fi

    # Clean /etc/environment
    if [[ -f /etc/environment ]]; then
        print_task "Cleaning /etc/environment of server-hub variables..."
        sudo sed -i '/^mgmt_super_user=/d' /etc/environment 2>/dev/null || true
        sudo sed -i '/^mgmt_interface_name=/d' /etc/environment 2>/dev/null || true
        sudo sed -i '/^default_linux_distro_iso_path=/d' /etc/environment 2>/dev/null || true
        sudo sed -i '/^dnsbinder_/d' /etc/environment 2>/dev/null || true
        print_task_done
        ((++completed_steps))
    fi

    # Remove firewalld trusted zone sources
    if systemctl is-active firewalld &>/dev/null; then
        print_task "Removing firewalld trusted zone rules..."
        trusted_sources=$(sudo firewall-cmd --permanent --zone=trusted --list-sources 2>/dev/null || true)
        if [[ -n "$trusted_sources" ]]; then
            for src in $trusted_sources; do
                sudo firewall-cmd --permanent --zone=trusted --remove-source="$src" &>/dev/null || true
            done
            sudo firewall-cmd --reload &>/dev/null || true
        fi
        print_task_done
        ((++completed_steps))
    fi

    # Clean /etc/fstab entries from server-hub
    if [[ -f /etc/fstab ]]; then
        fstab_dirty=false

        # Unmount active mounts before removing fstab entries
        # ISO mounts: /iso-files/*.iso → /<fqdn>/<distro>
        while IFS= read -r mount_target; do
            [[ -z "$mount_target" ]] && continue
            if mountpoint -q "$mount_target" 2>/dev/null; then
                sudo umount -l "$mount_target" 2>/dev/null || true
            fi
        done < <(awk '/\/iso-files\/.*iso9660/ {print $2}' /etc/fstab 2>/dev/null)

        # Bind mount: /server-hub → /<fqdn>/server-hub
        while IFS= read -r mount_target; do
            [[ -z "$mount_target" ]] && continue
            if mountpoint -q "$mount_target" 2>/dev/null; then
                sudo umount -l "$mount_target" 2>/dev/null || true
            fi
        done < <(awk '/\/server-hub.*bind/ {print $2}' /etc/fstab 2>/dev/null)

        # Remove fstab entries referencing /iso-files/ with iso9660
        if grep -q '/iso-files/.*iso9660' /etc/fstab 2>/dev/null; then
            fstab_dirty=true
            sudo sed -i '\|/iso-files/.*iso9660|d' /etc/fstab 2>/dev/null || true
        fi

        # Remove fstab entries for /server-hub bind mount
        if grep -q '/server-hub' /etc/fstab 2>/dev/null; then
            fstab_dirty=true
            sudo sed -i '\|/server-hub|d' /etc/fstab 2>/dev/null || true
        fi

        # Remove fstab entries referencing old FQDN as mount target
        if [[ -n "$lab_infra_server_hostname" ]]; then
            if grep -q "/${lab_infra_server_hostname}/" /etc/fstab 2>/dev/null; then
                fstab_dirty=true
                sudo sed -i "\|/${lab_infra_server_hostname}/|d" /etc/fstab 2>/dev/null || true
            fi
        fi

        if [[ "$fstab_dirty" == true ]]; then
            print_task "Cleaning /etc/fstab of server-hub mount entries..."
            sudo systemctl daemon-reload
            print_task_done
            ((++completed_steps))
        fi
    fi
fi

# ====== PHASE 4: NETWORK ======
print_task "Destroying virsh network 'default'..."
if sudo virsh net-info default &>/dev/null; then
    sudo virsh net-destroy default &>/dev/null || true
    if sudo virsh net-undefine default &>/dev/null; then
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

if ip link show labbr0 &>/dev/null; then
    print_task "Flushing labbr0 addresses..."
    sudo ip addr flush dev labbr0 2>/dev/null || true
    print_task_done
    ((++completed_steps))
fi

# Clear DNS routing config on labbr0
sudo resolvectl revert labbr0 2>/dev/null || true

# ====== PHASE 5: COMMON ARTIFACTS ======
# Remove CLI symlinks
print_task "Removing server-hub CLI tools from /usr/local/bin/..."
sudo rm -f /usr/local/bin/qlabvmctl 2>/dev/null || true
sudo rm -f /usr/local/bin/qlabstart 2>/dev/null || true
sudo rm -f /usr/local/bin/qlabhealth 2>/dev/null || true
sudo rm -f /usr/local/bin/qlabdnsbinder 2>/dev/null || true
sudo rm -f /usr/local/bin/ksmanager 2>/dev/null || true
sudo rm -f /usr/local/bin/prepare-distro-for-ksmanager 2>/dev/null || true
print_task_done
((++completed_steps))

# Remove bash completion
print_task "Removing bash completion for qlabvmctl..."
sudo rm -f /etc/bash_completion.d/qlabvmctl-completion.bash 2>/dev/null || true
print_task_done
((++completed_steps))

# Remove SSH keys
print_task "Removing SSH artifacts..."
rm -f "$HOME/.ssh/kvm_lab_global_id_rsa" "$HOME/.ssh/kvm_lab_global_id_rsa.pub" 2>/dev/null || true

# Remove old key from authorized_keys
if [[ -f "$HOME/.ssh/authorized_keys" && -n "$lab_infra_domain_name" ]]; then
    escaped_domain="${lab_infra_domain_name//./\\.}"
    sed -i "/${escaped_domain}/d" "$HOME/.ssh/authorized_keys" 2>/dev/null || true
fi

# Remove system-wide SSH config
sudo rm -f /etc/ssh/ssh_config.d/999-kvm-lab-global.conf 2>/dev/null || true

# Remove lab entries from user SSH config.custom
if [[ -f "$HOME/.ssh/config.custom" ]]; then
    sed -i '/# KVM Lab SSH Config - Start/,/# KVM Lab SSH Config - End/d' "$HOME/.ssh/config.custom" 2>/dev/null || true
fi
print_task_done
((++completed_steps))

# Clean /etc/hosts entries
if [[ -n "$lab_infra_domain_name" ]]; then
    print_task "Cleaning lab entries from /etc/hosts..."
    escaped_domain="${lab_infra_domain_name//./\\.}"
    sudo sed -i "/${escaped_domain}/d" /etc/hosts 2>/dev/null || true
    sudo rm -f /etc/hosts.bak 2>/dev/null || true
    print_task_done
    ((++completed_steps))
elif [[ -n "$lab_infra_server_hostname" ]]; then
    print_task "Cleaning lab entries from /etc/hosts..."
    sudo sed -i "/${lab_infra_server_hostname}/d" /etc/hosts 2>/dev/null || true
    sudo rm -f /etc/hosts.bak 2>/dev/null || true
    print_task_done
    ((++completed_steps))
else
    ((++skipped_steps))
fi

# Remove sudoers file
if [[ -f "/etc/sudoers.d/$USER" ]]; then
    print_task "Removing /etc/sudoers.d/$USER..."
    if sudo rm -f "/etc/sudoers.d/$USER"; then
        print_task_done
        ((++completed_steps))
    else
        print_task_fail
        ((++failed_steps))
    fi
else
    ((++skipped_steps))
fi

# Unmount any /mnt/iso-for-* mount points
for mount_point in /mnt/iso-for-*; do
    [[ -d "$mount_point" ]] || continue
    if mountpoint -q "$mount_point" 2>/dev/null; then
        print_task "Unmounting ${mount_point}..."
        if sudo umount -l "$mount_point" 2>/dev/null; then
            print_task_done
            ((++completed_steps))
        else
            print_task_fail
            ((++failed_steps))
        fi
    fi
    sudo rmdir "$mount_point" 2>/dev/null || true
done

# ====== PHASE 6: DIRECTORY CLEANUP & ISO MIGRATION ======
iso_migrated=false
if [[ -d "/iso-files" ]]; then
    # Migrate all ISO files (filenames are identical between projects)
    iso_files_found=false
    for iso_file in /iso-files/*.iso; do
        [[ -f "$iso_file" ]] || continue
        iso_files_found=true
        break
    done

    if [[ "$iso_files_found" == true ]]; then
        print_task "Migrating ISO files from /iso-files/ to /tux2lab-data/iso-files/..."
        sudo mkdir -p /tux2lab-data/iso-files
        sudo chown "$USER":"$(id -g)" /tux2lab-data/iso-files
        migration_failed=false
        for iso_file in /iso-files/*.iso; do
            [[ -f "$iso_file" ]] || continue
            if ! sudo mv "$iso_file" /tux2lab-data/iso-files/; then
                print_warning "Failed to migrate $(basename "$iso_file")"
                migration_failed=true
            fi
        done
        if [[ "$migration_failed" == false ]]; then
            print_task_done
            ((++completed_steps))
        else
            print_task_fail
            ((++failed_steps))
        fi

        # Check if infra server ISO was among migrated files
        if [[ -f "/tux2lab-data/iso-files/AlmaLinux-10-latest-x86_64-dvd.iso" ]]; then
            iso_migrated=true
        fi
    fi

    # Migrate and rename checksum file for infra server ISO
    if [[ -f "/iso-files/CHECKSUM" ]]; then
        print_task "Migrating checksum file (CHECKSUM → almalinux-10-CHECKSUM)..."
        sudo mkdir -p /tux2lab-data/iso-files
        sudo chown "$USER":"$(id -g)" /tux2lab-data/iso-files
        if sudo mv /iso-files/CHECKSUM /tux2lab-data/iso-files/almalinux-10-CHECKSUM; then
            print_task_done
            ((++completed_steps))
        else
            print_task_fail
            ((++failed_steps))
        fi
    fi

    # Write marker files (only if infra ISO was migrated successfully)
    if [[ "$iso_migrated" == true ]]; then
        print_task "Writing infra server ISO marker files..."
        echo "AlmaLinux-10-latest-x86_64-dvd.iso" > /tux2lab-data/iso-files/infra-server-iso
        echo "almalinux" > /tux2lab-data/iso-files/infra-server-distro
        print_task_done
        ((++completed_steps))
    fi
fi

# Remove directories
if [[ -d "/kvm-hub" ]]; then
    print_task "Removing /kvm-hub/..."
    if sudo rm -rf /kvm-hub; then
        print_task_done
        ((++completed_steps))
    else
        print_task_fail
        ((++failed_steps))
    fi
fi

if [[ -d "/iso-files" ]]; then
    print_task "Removing /iso-files/..."
    if sudo rm -rf /iso-files; then
        print_task_done
        ((++completed_steps))
    else
        print_task_fail
        ((++failed_steps))
    fi
fi

if [[ -d "/server-hub" ]]; then
    print_task "Removing /server-hub/..."
    if sudo rm -rf /server-hub; then
        print_task_done
        ((++completed_steps))
    else
        print_task_fail
        ((++failed_steps))
    fi
fi

# ====== SUMMARY ======
print_cyan "═══════════════════════════════════════════════════════════════════"
print_success "Server-hub cleanup completed."
echo
print_info "Summary: ${completed_steps} completed, ${skipped_steps} skipped, ${failed_steps} failed"
if [[ "$iso_migrated" == true ]]; then
    print_info "ISO migrated to /tux2lab-data/iso-files/AlmaLinux-10-latest-x86_64-dvd.iso"
    print_info "Infra server ISO markers written — no need to run 'tux2lab distro download-infra-iso'."
fi
echo
print_info "System is ready for tux2lab setup. Proceeding..."
print_cyan "═══════════════════════════════════════════════════════════════════"

exit 0
