#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh

if [[ "$UID" -eq 0 ]]; then
    print_error "Please do not run as root or with sudo, directly run the script from user who has sudo access!"
    exit 1
fi

print_task "Enabling passwordless sudo for $USER..."
mgmt_super_user="$USER"
echo "${mgmt_super_user} ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/${mgmt_super_user}" &>/dev/null
print_task_done

print_task "Setting up environment variables..."
if ! grep -q mgmt_super_user /etc/environment;then
    echo "mgmt_super_user=\"${mgmt_super_user}\"" | sudo tee -a /etc/environment &>/dev/null
fi

# Set mgmt_interface_name in environment
if ! grep -q mgmt_interface_name /etc/environment; then
  echo "mgmt_interface_name=\"eth0\"" | sudo tee -a /etc/environment &>/dev/null
fi

# Set default_linux_distro_iso_path in environment
if ! grep -q default_linux_distro_iso_path /etc/environment; then
  echo "default_linux_distro_iso_path=\"/dev/sr0\"" | sudo tee -a /etc/environment &>/dev/null
fi

# Set infra server distro and version fallback defaults
# These are normally set by the kickstart %post or deploy script;
# fallback to almalinux/10 if not already present
if ! grep -q infra_server_distro /etc/environment; then
  echo "infra_server_distro=\"almalinux\"" | sudo tee -a /etc/environment &>/dev/null
fi
if ! grep -q infra_server_version /etc/environment; then
  echo "infra_server_version=\"10\"" | sudo tee -a /etc/environment &>/dev/null
fi

# Backup environment file
sudo cp -p /etc/environment "/root/environment_bkp_$(date +%F)"
print_task_done

print_info "Setting up local DNS domain with dnsbinder..."

input_domain_to_dnsbinder=$(sudo bash -c '[[ -f /root/infra_server_on_qemu_kvm_dnsbinder_domain_provided ]] && cat /root/infra_server_on_qemu_kvm_dnsbinder_domain_provided')

if ! sudo bash /tux2lab/named-manage/dnsbinder.sh --setup "${input_domain_to_dnsbinder}"; then
    print_error "DNS setup failed"
    exit 1
fi

source /etc/environment

# Validate critical variables from dnsbinder setup
: "${dnsbinder_server_short_name:?Error: dnsbinder did not set server name}"
: "${dnsbinder_last24_subnet:?Error: dnsbinder did not set subnet}"

print_task "Setting server MOTD..."
cat << EOF | sudo tee /etc/motd &>/dev/null
+-------------------------------------------------------------+
|               Welcome to your Lab Infra Server              |
+-------------------------------------------------------------+
| This host provisions and manages all lab hosts.             |
| All essential services for your lab environment run here.   |
| It is critical to the lab — please handle with care.        |
| Automation toolkits are available to manage the lab.        |
+-------------------------------------------------------------+
| Have a bug report, suggestion, or query? Drop it here:      |
| https://github.com/Muthukumar-Subramaniam/tux2lab/issues    |
+-------------------------------------------------------------+
EOF
print_task_done

print_task "Reserving DNS records for DHCP leases (${dnsbinder_last24_subnet}.156 - ${dnsbinder_last24_subnet}.254)..."
dhcp_lease_file="$(mktemp /tmp/dhcp-lease-records.XXXXXXXXXX)"
for IP in $(seq 156 254); do
    echo "dhcp-lease${IP} ${dnsbinder_last24_subnet}.${IP}" >> "$dhcp_lease_file"
done
if ! sudo bash /tux2lab/named-manage/dnsbinder.sh -cify --inline "$dhcp_lease_file" &>/dev/null; then
    print_task_fail
    print_warning "Some DHCP lease DNS records may have failed to create."
else
    print_task_done
fi
rm -f "$dhcp_lease_file"

print_task "Configuring network interface naming..."
if ! ip link | grep -q eth0; then

    sudo mkdir -p /etc/systemd/network
    V_count=0
    while IFS= read -r v_interface; do
        if [[ "$v_interface" != "lo" ]]; then
            mac_addr=$(ip link show "$v_interface" 2>/dev/null | awk '/link\/ether/ {print $2}')
            if [[ -n "$mac_addr" ]]; then
                echo -e "[Match]\nMACAddress=$mac_addr\n\n[Link]\nName=eth$V_count" | sudo tee "/etc/systemd/network/7$V_count-eth$V_count.link" &>/dev/null
                V_count=$((V_count+1))
            fi
        fi
    done < <(ls -1 /sys/class/net 2>/dev/null)

    sudo mkdir -p /root/system-connections/orig-during-install

    sudo cp -a /etc/NetworkManager/system-connections/* /root/system-connections/orig-during-install/ 2>/dev/null || true

    v_count=0
    for v_interface_file in /etc/NetworkManager/system-connections/*; do
        [[ -f "$v_interface_file" ]] || continue
        filename=$(basename "$v_interface_file")
            sudo mv "$v_interface_file" "/etc/NetworkManager/system-connections/eth$v_count.nmconnection"
            v_interface="${filename%%.*}"
            sudo sed -i "s/\b${v_interface}\b/eth$v_count/g" "/etc/NetworkManager/system-connections/eth$v_count.nmconnection"
            v_count=$((v_count+1))
    done

    sudo mv /etc/NetworkManager/system-connections/eth* /root/system-connections 2>/dev/null || true

    sudo rm -rf /etc/NetworkManager/system-connections/*

    sudo cp -a /root/system-connections/. /etc/NetworkManager/system-connections/. 2>/dev/null || true

    sudo rm -rf /etc/NetworkManager/system-connections/orig-during-install
    print_task_done
else
    print_task_skip
fi

print_task "Handling SELinux..."
if command -v getenforce &>/dev/null && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
    if [[ "${1:-}" == "--invoked-by-automation" ]]; then
        # VM mode: disable permanently (disposable lab VM)
        sudo setenforce 0 2>/dev/null || true
        sudo grubby --update-kernel ALL --args selinux=0
    else
        # Host mode: SELinux stays enforcing, contexts applied by configure script
        true
    fi
fi
print_task_done

print_task "Removing crashkernel memory reserve..."
sudo grubby --update-kernel ALL --remove-args=crashkernel &>/dev/null || true
print_task_done

if [[ "${1:-}" != "--invoked-by-automation" ]]; then
    print_info "Please reboot the server, then run configure-lab-infra-server.sh to complete setup."
fi
