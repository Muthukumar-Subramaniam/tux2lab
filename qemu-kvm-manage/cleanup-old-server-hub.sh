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

print_yellow "A previous server-hub deployment has been detected on this system.
The following will be PERMANENTLY REMOVED to prepare for tux2lab:"

# Optional entries, empty when they do not apply
infra_server_entry=""
if [[ -n "$lab_infra_server_hostname" ]]; then
    infra_server_entry="
  • Lab infrastructure server (${lab_infra_server_hostname})"
fi

host_mode_entries=""
if [[ "$lab_infra_server_mode_is_host" == "true" ]]; then
    host_mode_entries="
  • Host-mode lab services (named, kea, nginx, etc.)"
    if [[ -n "$lab_infra_server_hostname" ]]; then
        host_mode_entries+="
  • Web root directory (/${lab_infra_server_hostname}/)"
    fi
    host_mode_entries+="
  • DNS zone files (/var/named/dnsbinder-managed-zone-files/)"
fi

iso_entry=""
if [[ -d "/iso-files" ]]; then
    iso_entry="
  • Boot ISO files under /iso-files/ (not reusable by tux2lab)"
fi

print_yellow "  • All VMs with disks under /kvm-hub/vms/${infra_server_entry}
  • All libvirt storage pools
  • Virtual network 'default' (labbr0)${host_mode_entries}
  • SSH keys and config (kvm_lab_global_id_rsa, 999-kvm-lab-global.conf)
  • CLI tools (qlabvmctl, qlabstart, qlabhealth, qlabdnsbinder, ksmanager)
  • Directories: /server-hub, /kvm-hub, /iso-files
  • /etc/sudoers.d/${USER}${iso_entry}"

# ====== LIST VMs THAT WILL BE DESTROYED ======
# Single virsh call yields name and state, so only domblklist runs per VM
old_vms=()
vm_list=""
while IFS='|' read -r vm vm_state; do
    [[ -z "$vm" ]] && continue
    # awk exits on first match, so the producer may take SIGPIPE under pipefail
    disk_path=$(sudo virsh domblklist "$vm" 2>/dev/null | awk '/\/kvm-hub\/vms\// {print $2; exit}' || true)
    if [[ -n "$disk_path" ]]; then
        old_vms+=("$vm")
        vm_list+="
  - ${vm} (${vm_state})"
    fi
done < <(sudo virsh list --all 2>/dev/null | awk 'NR>2 && NF {name=$2; $1=""; $2=""; sub(/^[ \t]+/,""); sub(/[ \t]+$/,""); print name"|"$0}')

if [[ -n "$vm_list" ]]; then
    print_yellow "The following VMs will be DESTROYED:${vm_list}"
fi

print_red "THIS ACTION CANNOT BE UNDONE."
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
    host_services=("named" "kea-dhcp4" "kea-dhcp6" "radvd" "nfs-server" "tftp.socket" "nginx" "lab-services-restart")
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

    # Remove custom service unit file
    sudo rm -f /etc/systemd/system/lab-services-restart.service 2>/dev/null || true
    sudo systemctl daemon-reload 2>/dev/null || true

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

    # Restore named.conf to clean state (remove server-hub's dnsbinder markers)
    if [[ -f /etc/named.conf ]] && grep -q 'zones-are-managed-by-dnsbinder' /etc/named.conf 2>/dev/null; then
        print_task "Restoring named.conf to clean state..."
        if [[ -f /etc/named.conf_bkp_by_dnsbinder ]]; then
            sudo cp -p /etc/named.conf_bkp_by_dnsbinder /etc/named.conf
        else
            sudo sed -i '/# BEGIN zones-of-.*-domain/,/# END zones-of-.*-domain/d' /etc/named.conf
        fi
        sudo rm -f /etc/named.conf_bkp_by_dnsbinder
        print_task_done
        ((++completed_steps))
    fi

    # Remove old nginx server config from conf.d (server-hub named it after the FQDN)
    if [[ -n "$lab_infra_server_hostname" && -f "/etc/nginx/conf.d/${lab_infra_server_hostname}.conf" ]]; then
        print_task "Removing old nginx config /etc/nginx/conf.d/${lab_infra_server_hostname}.conf..."
        sudo rm -f "/etc/nginx/conf.d/${lab_infra_server_hostname}.conf"
        print_task_done
        ((++completed_steps))
    fi

    # Remove old SSL cert/key files (server-hub used <FQDN>-nginx-selfsigned.{key,crt})
    if [[ -n "$lab_infra_server_hostname" ]]; then
        old_ssl_key="/etc/pki/tls/private/${lab_infra_server_hostname}-nginx-selfsigned.key"
        old_ssl_cert="/etc/pki/tls/certs/${lab_infra_server_hostname}-nginx-selfsigned.crt"
        old_ssl_anchor="/etc/pki/ca-trust/source/anchors/${lab_infra_server_hostname}-nginx-selfsigned.crt"
        if [[ -f "$old_ssl_key" || -f "$old_ssl_cert" || -f "$old_ssl_anchor" ]]; then
            print_task "Removing old server-hub SSL cert/key files..."
            sudo rm -f "$old_ssl_key" "$old_ssl_cert" "$old_ssl_anchor"
            sudo update-ca-trust 2>/dev/null || true
            print_task_done
            ((++completed_steps))
        fi
    fi

    # Remove old chrony/NTP markers from /etc/chrony.conf (server-hub blockinfile)
    if [[ -n "$lab_infra_server_hostname" ]] && grep -q "ntp-${lab_infra_server_hostname}-settings" /etc/chrony.conf 2>/dev/null; then
        print_task "Removing old NTP config markers from /etc/chrony.conf..."
        sudo sed -i "/# BEGIN ntp-${lab_infra_server_hostname}-settings/,/# END ntp-${lab_infra_server_hostname}-settings/d" /etc/chrony.conf
        # Restore commented pool lines
        sudo sed -i 's/^#pool /pool /' /etc/chrony.conf
        sudo systemctl restart chronyd 2>/dev/null || true
        print_task_done
        ((++completed_steps))
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
sudo rm -f /usr/local/bin/wait-for-ipv6.sh 2>/dev/null || true
sudo rm -f /usr/sbin/dnsbinder 2>/dev/null || true
sudo rm -f /usr/bin/dnsbinder 2>/dev/null || true
# Remove legacy virt-install wrapper (pre-vendored versions wrote a shell wrapper here)
sudo rm -f /usr/local/bin/virt-install 2>/dev/null || true
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
    sed -i '/# tux2lab SSH Config - Start/,/# tux2lab SSH Config - End/d' "$HOME/.ssh/config.custom" 2>/dev/null || true
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

# ====== PHASE 6: DIRECTORY CLEANUP ======
# v1 media is not carried over: v2 uses boot ISOs under different filenames
for old_dir in /kvm-hub /iso-files /server-hub; do
    if [[ -d "$old_dir" ]]; then
        print_task "Removing ${old_dir}/..."
        if sudo rm -rf "$old_dir"; then
            print_task_done
            ((++completed_steps))
        else
            print_task_fail
            ((++failed_steps))
        fi
    fi
done

# ====== SUMMARY ======
print_cyan "═══════════════════════════════════════════════════════════════════"
print_success "Server-hub cleanup completed."
print_info "Summary: ${completed_steps} completed, ${skipped_steps} skipped, ${failed_steps} failed"
print_info "System is ready for tux2lab setup. Proceeding..."
print_cyan "═══════════════════════════════════════════════════════════════════"

exit 0
