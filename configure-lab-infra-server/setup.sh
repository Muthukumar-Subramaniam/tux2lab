#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -euo pipefail

if [[ "$UID" -eq 0 ]]; then
    echo -e "\nPlease do not run as root or with sudo, directly run the script from user who has sudo access! \n"
    exit 1
fi

if command -v ansible &>/dev/null; then
    echo -e "\nAnsible is already installed, Proceeding further . . .\n"
else
    echo -e "\nInstalling Ansible . . . \n"
    if command -v dnf &>/dev/null; then
        sudo dnf install -y ansible-core || exit 1
    elif command -v apt-get &>/dev/null; then
        sudo apt-get update && sudo apt-get install -y ansible-core || exit 1
    else
        echo -e "\nUnsupported package manager. Cannot install ansible-core.\n"
        exit 1
    fi
    echo "## Completed Ansible Installation ##"
fi

ansible-galaxy collection install -r /tux2lab/configure-lab-infra-server/requirements.yml || exit 1

echo -e "\nAdd password-less sudo access for $USER . . . \n"
mgmt_super_user="$USER"
echo "${mgmt_super_user} ALL=(ALL) NOPASSWD:ALL" | sudo tee "/etc/sudoers.d/${mgmt_super_user}" &>/dev/null

echo -e "\nSetting up some custom global vars . . .\n"

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

echo -e "\nSetting Up ansible remote user . . . \n"

export ANSIBLE_REMOTE_USER="$USER"

if ! grep -q '^ANSIBLE_REMOTE_USER=' /etc/environment; then
    echo "ANSIBLE_REMOTE_USER=\"$USER\"" | sudo tee -a /etc/environment &>/dev/null
fi

echo -e "\nSetting up local dns domain with dnsbinder . . .\n"

input_domain_to_dnsbinder=$(sudo bash -c '[[ -f /root/infra_server_on_qemu_kvm_dnsbinder_domain_provided ]] && cat /root/infra_server_on_qemu_kvm_dnsbinder_domain_provided')

if ! sudo bash /tux2lab/named-manage/dnsbinder.sh --setup "${input_domain_to_dnsbinder}"; then
    echo -e "\nError: DNS setup failed\n"
    exit 1
fi

source /etc/environment

# Validate critical variables from dnsbinder setup
: "${dnsbinder_server_short_name:?Error: dnsbinder did not set server name}"
: "${dnsbinder_last24_subnet:?Error: dnsbinder did not set subnet}"

# No CNAME aliases needed — single fixed hostname: tux2lab-engine

echo -e "\nSetting motd . . .\n"

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

echo -e "\nReserve Records for DHCP lease DNS (last 99 IPs: .156-.254) . . .\n"

dhcp_lease_file="$(mktemp /tmp/dhcp-lease-records.XXXXXXXXXX)"
for IP in $(seq 156 254); do
    echo "dhcp-lease${IP} ${dnsbinder_last24_subnet}.${IP}" >> "$dhcp_lease_file"
done
if ! sudo bash /tux2lab/named-manage/dnsbinder.sh -cify --inline "$dhcp_lease_file"; then
    echo -e "\nWarning: Some DHCP lease DNS records may have failed to create.\n"
fi
rm -f "$dhcp_lease_file"

echo -e "\nUpdate Network Interface to conventional naming . . .\n"

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
fi

echo -e "\nDisabling SELinux . . .\n"

sudo grubby --update-kernel ALL --args selinux=0

echo -e "\nRemove crashkernel memory reserve if present . . .\n"

sudo grubby --update-kernel ALL --remove-args=crashkernel

if [[ "${1:-}" != "--invoked-by-automation" ]]; then
    echo -e "\nPlease reboot the server if you did not face any issue with setup script ! \n"
    echo -e "\nAfter Reboot you can ansible playbook configure-lab-infra-server.yaml to setup the system ! \n" 
fi
