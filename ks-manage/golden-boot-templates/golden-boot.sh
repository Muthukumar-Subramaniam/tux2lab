#!/bin/bash

# Detect the distribution
if [ -f /etc/os-release ]; then
	source /etc/os-release
	DISTRO_ID="${ID}"
	DISTRO_ID_LIKE="${ID_LIKE}"
else
	echo "ERROR: Cannot detect distribution - /etc/os-release not found"
	exit 1
fi

# Determine distro family
if [[ "${DISTRO_ID}" == "ubuntu" ]] || [[ "${DISTRO_ID_LIKE}" == *"ubuntu"* ]] || [[ "${DISTRO_ID}" == "debian" ]] || [[ "${DISTRO_ID_LIKE}" == *"debian"* ]]; then
	DISTRO_FAMILY="debian"
elif [[ "${DISTRO_ID}" == "opensuse-leap" ]] || [[ "${DISTRO_ID}" == "opensuse" ]] || [[ "${DISTRO_ID_LIKE}" == *"suse"* ]]; then
	DISTRO_FAMILY="opensuse"
elif [[ "${DISTRO_ID}" == "azurelinux" ]] || [[ "${DISTRO_ID}" == "mariner" ]]; then
	DISTRO_FAMILY="azurelinux"
elif [[ "${DISTRO_ID}" == "rhel" ]] || [[ "${DISTRO_ID}" == "centos" ]] || [[ "${DISTRO_ID}" == "centos-stream" ]] || [[ "${DISTRO_ID}" == "almalinux" ]] || [[ "${DISTRO_ID}" == "rocky" ]] || [[ "${DISTRO_ID}" == "ol" ]] || [[ "${DISTRO_ID}" == "oraclelinux" ]] || [[ "${DISTRO_ID}" == "fedora" ]] || [[ "${DISTRO_ID_LIKE}" == *"rhel"* ]] || [[ "${DISTRO_ID_LIKE}" == *"fedora"* ]]; then
	DISTRO_FAMILY="redhat"
else
	echo "ERROR: Unsupported distribution: ${DISTRO_ID}"
	exit 1
fi

# Setup logging to both file and console
LOGFILE="/var/log/golden-boot-${DISTRO_FAMILY}.log"
exec > >(tee -a "$LOGFILE") 2>&1

log() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
	log "FATAL ERROR: $1"
	log "Golden boot configuration failed - check $LOGFILE for details"
	exit 1
}

COMPLETION_MARKER="/root/golden-boot-completed"

if [ -f "$COMPLETION_MARKER" ]; then
	log "Golden boot already completed, exiting"
	exit 0
fi

if [ ! -f /root/golden-image-setup-completed ]; then
	log "Golden image setup not completed, exiting"
	exit 0
fi

log "Starting golden boot configuration for ${DISTRO_ID} (${DISTRO_FAMILY} family)"

log "Checking network connectivity to lab infrastructure server..."
# Wait for network to be fully ready (DHCP may still be in progress on Debian/ifupdown)
WAIT_SECS=0
MAX_WAIT=60
while ! ping -c 1 -W 2 get_lab_infra_server_hostname &>/dev/null; do
	WAIT_SECS=$((WAIT_SECS + 3))
	if [ $WAIT_SECS -ge $MAX_WAIT ]; then
		log "Waited ${MAX_WAIT}s for network connectivity"
		ping -c 3 get_lab_infra_server_hostname || error_exit "Cannot reach lab infrastructure server"
	fi
	log "Waiting for network... (${WAIT_SECS}/${MAX_WAIT}s)"
	sleep 3
done
if [ $WAIT_SECS -gt 0 ]; then
	log "Network became available after ${WAIT_SECS}s"
else
	log "Network available immediately"
fi
ping -c 3 get_lab_infra_server_hostname
log "Network connectivity to lab infrastructure server confirmed"

log "Creating systemd network configuration directory"
mkdir -p /etc/systemd/network

log "Creating .link files for predictable interface naming"
V_count=0
for v_interface in /sys/class/net/*; do
	v_interface=$(basename "$v_interface")
	[[ "$v_interface" == "lo" ]] && continue
	mac_addr=$(ip link show "$v_interface" | awk '/link\/ether/ {print $2}')
	log "Creating link file for interface $v_interface (MAC: $mac_addr) -> eth$V_count"
	echo -e "[Match]\nMACAddress=$mac_addr\n\n[Link]\nName=eth$V_count" > /etc/systemd/network/7$V_count-eth$V_count.link
	V_count=$((V_count+1))
done

log "Retrieving MAC address for eth0"
get_mac_address_path=$(grep '^MACAddress=' /etc/systemd/network/70-eth0.link | cut -d= -f2 | sed 's/:/-/g')
log "MAC address path: $get_mac_address_path"

log "Downloading network configuration from lab infrastructure server"
if ! curl -fsSL "http://get_lab_infra_server_hostname/ksmanager-hub/golden-boot-mac-configs/network-config-${get_mac_address_path}" -o "/root/network-config-$get_mac_address_path"; then
	error_exit "Failed to download network configuration for MAC: $get_mac_address_path"
fi

if [ ! -f "/root/network-config-$get_mac_address_path" ] || [ ! -s "/root/network-config-$get_mac_address_path" ]; then
	error_exit "Network configuration file is missing or empty"
fi

log "Loading network configuration"
source "/root/network-config-$get_mac_address_path"

# Validate required IPv4 variables
if [ -z "$HOST_NAME" ] || [ -z "$IPv4_ADDRESS" ] || [ -z "$IPv4_CIDR" ] || [ -z "$IPv4_GATEWAY" ] || [ -z "$IPv4_DNS_SERVER" ] || [ -z "$IPv4_DNS_DOMAIN" ]; then
	error_exit "Required network configuration variables are missing"
fi

# Check if IPv6 is configured
if [ -n "$IPv6_ADDRESS" ] && [ -n "$IPv6_PREFIX" ]; then
	log "IPv6 configuration detected: ${IPv6_ADDRESS}/${IPv6_PREFIX}"
	IPV6_ENABLED=true
else
	log "IPv6 not configured, using IPv4 only"
	IPV6_ENABLED=false
fi

log "Setting hostname to: ${HOST_NAME}"
hostnamectl set-hostname "${HOST_NAME}"

log "Configuring kernel hostname"
cat << EOF > /etc/sysctl.d/hostname.conf
kernel.hostname=${HOST_NAME}
EOF

log "Applying sysctl settings"
sysctl --system > /dev/null 2>&1

log "Restarting syslog daemon to pick up new hostname"
if systemctl is-active --quiet rsyslog.service; then
	systemctl restart rsyslog.service
	log "rsyslog restarted successfully"
elif systemctl is-active --quiet syslog.service; then
	systemctl restart syslog.service
	log "syslog restarted successfully"
else
	log "No traditional syslog daemon active (journald handles hostname natively)"
fi

# Distro-specific network cleanup and configuration
case "${DISTRO_FAMILY}" in
	redhat)
		log "Performing RedHat-based network cleanup"
		
		log "Creating backup directory for existing network connections"
		mkdir -p /root/system-connections-golden-image
		
		log "Backing up existing NetworkManager connections"
		if [ -n "$(ls -A /etc/NetworkManager/system-connections/ 2>/dev/null)" ]; then
			rsync -avPh /etc/NetworkManager/system-connections/* /root/system-connections-golden-image/ > /dev/null 2>&1
			log "Backup completed"
		else
			log "No existing connections to backup"
		fi
		
		log "Deleting all existing NetworkManager connections"
		nmcli -t -f UUID,TYPE connection show | while IFS=: read -r uuid type; do
			if [ "$type" = "loopback" ]; then
				log "  Skipping loopback connection UUID: $uuid"
				continue
			fi
			log "  Bringing down connection UUID: $uuid"
			nmcli connection down uuid "$uuid" 2>/dev/null || true
			log "  Deleting connection UUID: $uuid"
			nmcli connection delete uuid "$uuid" 2>/dev/null || true
		done
		
		log "Deleting any remaining connection files from disk"
		if [ -d /etc/NetworkManager/system-connections ]; then
			rm -f /etc/NetworkManager/system-connections/*.nmconnection
			log "Deleted connection files from /etc/NetworkManager/system-connections/"
		fi
		
		if [ -d /etc/sysconfig/network-scripts ]; then
			rm -f /etc/sysconfig/network-scripts/ifcfg-*
			log "Deleted legacy ifcfg files from /etc/sysconfig/network-scripts/"
		fi
		
		log "Reloading NetworkManager connections"
		nmcli connection reload
		;;
	
	debian)
		log "Performing Debian/Ubuntu network cleanup"
		if command -v netplan &>/dev/null; then
			# Ubuntu: uses netplan
			log "netplan detected (Ubuntu) — backing up existing configs"
			mkdir -p /etc/netplan
			mkdir -p /etc/netplan/old
			mv /etc/netplan/*.yaml /etc/netplan/old/ 2>/dev/null || log "No existing netplan configs to backup"
		else
			# Debian: uses /etc/network/interfaces
			log "ifupdown detected (Debian) — backing up existing config"
			cp -p /etc/network/interfaces /etc/network/interfaces.bak.golden 2>/dev/null || true
		fi
		;;
	
	opensuse)
		log "Performing OpenSUSE network cleanup"
		# Leap 16+ uses NetworkManager; 15.x uses wicked
		if command -v nmcli &>/dev/null && systemctl is-active --quiet NetworkManager; then
			log "  NetworkManager detected (Leap 16+) - removing existing connections"
			nmcli -t -f UUID,DEVICE connection show | while IFS=: read -r uuid dev; do
				[[ "${dev}" == "lo" ]] && continue
				nmcli connection delete uuid "${uuid}" 2>/dev/null || true
			done
		else
			log "  Wicked detected (Leap 15.x) - minimal cleanup"
		fi
		;;

	azurelinux)
		log "Performing Azure Linux network cleanup (systemd-networkd)"
		
		log "Creating backup directory for existing network configs"
		mkdir -p /root/systemd-network-golden-image
		
		log "Backing up existing systemd-networkd configs"
		if [ -n "$(ls -A /etc/systemd/network/*.network 2>/dev/null)" ]; then
			cp -a /etc/systemd/network/*.network /root/systemd-network-golden-image/ 2>/dev/null || true
			log "Backup completed"
		else
			log "No existing .network files to backup"
		fi
		
		log "Removing existing .network files (preserving .link files for interface naming)"
		rm -f /etc/systemd/network/*.network
		log "Deleted .network files from /etc/systemd/network/"
		;;
esac

log "Bringing down all network interfaces"
for v_interface in /sys/class/net/*; do
	v_interface=$(basename "$v_interface")
	[[ "$v_interface" == "lo" ]] && continue
	log "  Bringing down interface: $v_interface"
	ip link set $v_interface down
done

log "Reloading udev rules for interface renaming"
udevadm control --reload-rules
udevadm trigger --action=add --subsystem-match=net

log "Waiting for eth0 interface to be available..."
timeout=30
counter=0
while [ ! -e /sys/class/net/eth0 ] && [ $counter -lt $timeout ]; do
	sleep 0.5
	counter=$((counter + 1))
done

if [ ! -e /sys/class/net/eth0 ]; then
	error_exit "eth0 interface not found after rename (timeout after ${timeout}s)"
fi
log "eth0 interface is available"

log "Bringing up all network interfaces"
for v_interface in /sys/class/net/*; do
	v_interface=$(basename "$v_interface")
	[[ "$v_interface" == "lo" ]] && continue
	log "  Bringing up interface: $v_interface"
	ip link set $v_interface up
done

# Distro-specific network configuration
case "${DISTRO_FAMILY}" in
	redhat)
		log "Configuring network using NetworkManager"
		log "Creating new NetworkManager connection for eth0"
		log "  IPv4: ${IPv4_ADDRESS}/${IPv4_CIDR}"
		log "  IPv4 Gateway: ${IPv4_GATEWAY}"
		if [ "$IPV6_ENABLED" = true ]; then
			log "  IPv6: ${IPv6_ADDRESS}/${IPv6_PREFIX}"
		fi
		log "  DNS: ${IPv4_DNS_SERVER},${IPv6_DNS_SERVER}"
		log "  Search domain: ${IPv4_DNS_DOMAIN}"
		
		if [ "$IPV6_ENABLED" = true ]; then
			if ! nmcli connection add type ethernet ifname eth0 con-name eth0 \
			  ipv4.addresses "${IPv4_ADDRESS}"/"${IPv4_CIDR}" \
			  ipv4.gateway "${IPv4_GATEWAY}" \
			  ipv4.dns "${IPv4_DNS_SERVER}" \
			  ipv4.dns-search "${IPv4_DNS_DOMAIN}" \
			  ipv4.method manual \
			  ipv6.addresses "${IPv6_ADDRESS}"/"${IPv6_PREFIX}" \
			  ipv6.dns "${IPv6_DNS_SERVER}" \
			  ipv6.dns-search "${IPv4_DNS_DOMAIN}" \
			  ipv6.method manual \
			  connection.autoconnect yes > /dev/null 2>&1; then
				error_exit "Failed to create NetworkManager connection for eth0"
			fi
		else
			if ! nmcli connection add type ethernet ifname eth0 con-name eth0 \
			  ipv4.addresses "${IPv4_ADDRESS}"/"${IPv4_CIDR}" \
			  ipv4.gateway "${IPv4_GATEWAY}" \
			  ipv4.dns "${IPv4_DNS_SERVER}" \
			  ipv4.dns-search "${IPv4_DNS_DOMAIN}" \
			  ipv4.method manual \
			  ipv6.method disabled \
			  connection.autoconnect yes > /dev/null 2>&1; then
				error_exit "Failed to create NetworkManager connection for eth0"
			fi
		fi
		
		log "Reloading NetworkManager to pick up new connection"
		nmcli connection reload
		
		log "Activating eth0 connection"
		if ! nmcli connection up eth0; then
			error_exit "Failed to activate eth0 connection"
		fi
		;;
	
	debian)
		if command -v netplan &>/dev/null; then
			# Ubuntu: uses netplan
			log "Configuring network using netplan"
			log "Creating netplan configuration for eth0"
			log "  IPv4: ${IPv4_ADDRESS}/${IPv4_CIDR}"
			log "  IPv4 Gateway: ${IPv4_GATEWAY}"
			if [ "$IPV6_ENABLED" = true ]; then
				log "  IPv6: ${IPv6_ADDRESS}/${IPv6_PREFIX}"
			fi
			log "  DNS: ${IPv4_DNS_SERVER},${IPv6_DNS_SERVER}"
			log "  Search domain: ${IPv4_DNS_DOMAIN}"
			
			if [ "$IPV6_ENABLED" = true ]; then
				cat << EOF > /etc/netplan/eth0.yaml
network:
    version: 2
    ethernets:
        eth0:
            dhcp4: false
            dhcp6: false
            accept-ra: false
            addresses:
              - ${IPv4_ADDRESS}/${IPv4_CIDR}
              - ${IPv6_ADDRESS}/${IPv6_PREFIX}
            routes:
              - to: default
                via: ${IPv4_GATEWAY}
                on-link: true
            nameservers:
              addresses: [${IPv4_DNS_SERVER}, ${IPv6_DNS_SERVER}]
              search: [${IPv4_DNS_DOMAIN}]
EOF
			else
				cat << EOF > /etc/netplan/eth0.yaml
network:
    version: 2
    ethernets:
        eth0:
            dhcp4: false
            dhcp6: false
            accept-ra: false
            addresses:
              - ${IPv4_ADDRESS}/${IPv4_CIDR}
            routes:
              - to: default
                via: ${IPv4_GATEWAY}
                on-link: true
            nameservers:
              addresses: [${IPv4_DNS_SERVER}, ${IPv6_DNS_SERVER}]
              search: [${IPv4_DNS_DOMAIN}]
EOF
			fi
			
			chmod 600 /etc/netplan/eth0.yaml
			log "Netplan configuration created"
			
			log "Applying netplan configuration"
			if ! netplan apply; then
				error_exit "Failed to apply netplan configuration"
			fi
		else
			# Debian: uses /etc/network/interfaces
			log "Configuring network using /etc/network/interfaces"
			log "Creating interfaces configuration for eth0"
			log "  IPv4: ${IPv4_ADDRESS}/${IPv4_CIDR}"
			log "  IPv4 Gateway: ${IPv4_GATEWAY}"
			if [ "$IPV6_ENABLED" = true ]; then
				log "  IPv6: ${IPv6_ADDRESS}/${IPv6_PREFIX}"
			fi
			log "  DNS: ${IPv4_DNS_SERVER}"
			log "  Search domain: ${IPv4_DNS_DOMAIN}"
			
			if [ "$IPV6_ENABLED" = true ]; then
				cat << EOF > /etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address ${IPv4_ADDRESS}/${IPv4_CIDR}
    gateway ${IPv4_GATEWAY}
    dns-nameservers ${IPv4_DNS_SERVER} ${IPv6_DNS_SERVER}
    dns-search ${IPv4_DNS_DOMAIN}

iface eth0 inet6 static
    address ${IPv6_ADDRESS}/${IPv6_PREFIX}
EOF
			else
				cat << EOF > /etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    address ${IPv4_ADDRESS}/${IPv4_CIDR}
    gateway ${IPv4_GATEWAY}
    dns-nameservers ${IPv4_DNS_SERVER}
    dns-search ${IPv4_DNS_DOMAIN}
EOF
			fi
			
			log "/etc/network/interfaces configuration created"
			
			log "Restarting networking"
			if ! systemctl restart networking; then
				error_exit "Failed to restart networking"
			fi
		fi
		;;
	
	opensuse)
		log "Configuring network for OpenSUSE"
		log "Creating network configuration for eth0"
		log "  IPv4: ${IPv4_ADDRESS}/${IPv4_CIDR}"
		log "  IPv4 Gateway: ${IPv4_GATEWAY}"
		if [ "$IPV6_ENABLED" = true ]; then
			log "  IPv6: ${IPv6_ADDRESS}/${IPv6_PREFIX}"
		fi
		log "  DNS: ${IPv4_DNS_SERVER}"
		
		if command -v nmcli &>/dev/null && systemctl is-active --quiet NetworkManager; then
			# Leap 16+ uses NetworkManager
			log "Using NetworkManager (Leap 16+)"
			nmcli connection add type ethernet con-name eth0 ifname eth0 \
				ipv4.method manual \
				ipv4.addresses "${IPv4_ADDRESS}/${IPv4_CIDR}" \
				ipv4.gateway "${IPv4_GATEWAY}" \
				ipv4.dns "${IPv4_DNS_SERVER}" \
				connection.autoconnect yes
			if [ "$IPV6_ENABLED" = true ]; then
				nmcli connection modify eth0 \
					ipv6.method manual \
					ipv6.addresses "${IPv6_ADDRESS}/${IPv6_PREFIX}" \
					ipv6.dns "${IPv6_DNS_SERVER}"
			fi
			log "Activating NetworkManager connection"
			if ! nmcli connection up eth0; then
				error_exit "Failed to activate NetworkManager connection"
			fi
		else
			# Leap 15.x uses wicked
			log "Using wicked (Leap 15.x)"
			if [ "$IPV6_ENABLED" = true ]; then
				cat << EOF > /etc/sysconfig/network/ifcfg-eth0
IPADDR='${IPv4_ADDRESS}/${IPv4_CIDR}'
IPADDR_0='${IPv6_ADDRESS}/${IPv6_PREFIX}'
BOOTPROTO='static'
STARTMODE='auto'
ZONE=public
EOF
			else
				cat << EOF > /etc/sysconfig/network/ifcfg-eth0
IPADDR='${IPv4_ADDRESS}/${IPv4_CIDR}'
BOOTPROTO='static'
STARTMODE='auto'
ZONE=public
EOF
			fi
			
			cat << EOF > /etc/sysconfig/network/ifroute-eth0
default ${IPv4_GATEWAY} - eth0
EOF
			
			log "Restarting network service to apply configuration"
			if ! systemctl restart network; then
				error_exit "Failed to restart network service"
			fi
		fi
		;;

	azurelinux)
		log "Configuring network using systemd-networkd for Azure Linux"
		log "Creating systemd-networkd config for eth0"
		log "  IPv4: ${IPv4_ADDRESS}/${IPv4_CIDR}"
		log "  IPv4 Gateway: ${IPv4_GATEWAY}"
		if [ "$IPV6_ENABLED" = true ]; then
			log "  IPv6: ${IPv6_ADDRESS}/${IPv6_PREFIX}"
		fi
		log "  DNS: ${IPv4_DNS_SERVER}"
		log "  Search domain: ${IPv4_DNS_DOMAIN}"
		
		if [ "$IPV6_ENABLED" = true ]; then
			cat << EOF > /etc/systemd/network/10-eth0.network
[Match]
Name=eth0

[Network]
DHCP=no
IPv6AcceptRA=no
Address=${IPv4_ADDRESS}/${IPv4_CIDR}
Gateway=${IPv4_GATEWAY}
DNS=${IPv4_DNS_SERVER}
DNS=${IPv6_DNS_SERVER}
Domains=${IPv4_DNS_DOMAIN}
Address=${IPv6_ADDRESS}/${IPv6_PREFIX}
EOF
		else
			cat << EOF > /etc/systemd/network/10-eth0.network
[Match]
Name=eth0

[Network]
DHCP=no
Address=${IPv4_ADDRESS}/${IPv4_CIDR}
Gateway=${IPv4_GATEWAY}
DNS=${IPv4_DNS_SERVER}
Domains=${IPv4_DNS_DOMAIN}
LinkLocalAddressing=no
EOF
		fi
		
		log "Reloading and restarting systemd-networkd to apply configuration"
		networkctl reload 2>/dev/null || true
		if ! systemctl restart systemd-networkd; then
			error_exit "Failed to restart systemd-networkd"
		fi
		;;
esac

log "Waiting for network to become ready..."
timeout=10
counter=0
while ! ip addr show eth0 | grep -q "inet ${IPv4_ADDRESS}" && [ $counter -lt $timeout ]; do
	sleep 0.5
	counter=$((counter + 1))
done

if ! ip addr show eth0 | grep -q "inet ${IPv4_ADDRESS}"; then
	error_exit "Network interface did not receive IP address"
fi
log "Network interface configured with IP ${IPv4_ADDRESS}/${IPv4_CIDR}"

log "Verifying network connectivity to lab infrastructure server..."
# Wait for DNS resolution to become available after network restart
dns_timeout=10
dns_counter=0
while ! getent hosts get_lab_infra_server_hostname >/dev/null 2>&1 && [ $dns_counter -lt $dns_timeout ]; do
	sleep 1
	dns_counter=$((dns_counter + 1))
done
if [ $dns_counter -gt 0 ]; then
	log "Waited ${dns_counter}s for DNS resolution to become available"
else
	log "DNS resolution available immediately"
fi
if ! ping -c 3 get_lab_infra_server_hostname; then
	error_exit "Cannot reach lab infrastructure server after reconfiguration"
fi
log "Network connectivity to lab infrastructure server confirmed with new IP configuration"

log "Creating system installation timestamp in /etc/bigbang"
date '+%Y-%m-%d %H:%M:%S %Z' > /etc/bigbang
log "Installation timestamp: $(cat /etc/bigbang)"

log "Downloading self-signed SSL certificate from lab infrastructure server"
case "${DISTRO_FAMILY}" in
	redhat)
		if curl -fsSL "http://get_lab_infra_server_hostname/ksmanager-hub/addons-for-kickstarts/ca-certs/tux2lab-nginx-selfsigned.crt" -o /etc/pki/ca-trust/source/anchors/tux2lab-nginx-selfsigned.crt; then
			update-ca-trust
			log "SSL certificate installed and CA trust updated (RedHat)"
		else
			log "WARNING: Failed to download SSL certificate, continuing anyway"
		fi
		;;
	debian)
		if curl -fsSL "http://get_lab_infra_server_hostname/ksmanager-hub/addons-for-kickstarts/ca-certs/tux2lab-nginx-selfsigned.crt" -o /usr/local/share/ca-certificates/tux2lab-nginx-selfsigned.crt; then
			update-ca-certificates
			log "SSL certificate installed and CA certificates updated (Debian/Ubuntu)"
		else
			log "WARNING: Failed to download SSL certificate, continuing anyway"
		fi
		;;
	opensuse)
		if curl -fsSL "http://get_lab_infra_server_hostname/ksmanager-hub/addons-for-kickstarts/ca-certs/tux2lab-nginx-selfsigned.crt" -o /etc/pki/trust/anchors/tux2lab-nginx-selfsigned.crt; then
			update-ca-certificates
			log "SSL certificate installed and CA certificates updated (OpenSUSE)"
		else
			log "WARNING: Failed to download SSL certificate, continuing anyway"
		fi
		;;
	azurelinux)
		if curl -fsSL "http://get_lab_infra_server_hostname/ksmanager-hub/addons-for-kickstarts/ca-certs/tux2lab-nginx-selfsigned.crt" -o /etc/pki/ca-trust/source/anchors/tux2lab-nginx-selfsigned.crt; then
			update-ca-trust
			log "SSL certificate installed and CA trust updated (Azure Linux)"
		else
			log "WARNING: Failed to download SSL certificate, continuing anyway"
		fi
		;;
esac

# Sync credentials from lab server (update if changed since golden image build)
log "Checking credentials against lab server..."
ADDONS_URL="http://get_lab_infra_server_hostname/ksmanager-hub/addons-for-kickstarts"
ADMIN_USER="get_mgmt_super_user"

# Password sync
current_hash=$(curl -fsSL "${ADDONS_URL}/shadow-hash" 2>/dev/null) || true
if [[ -n "$current_hash" ]]; then
	existing_hash=$(awk -F: -v user="root" '$1==user{print $2}' /etc/shadow)
	if [[ "$current_hash" != "$existing_hash" ]]; then
		echo "root:${current_hash}" | chpasswd -e
		echo "${ADMIN_USER}:${current_hash}" | chpasswd -e
		log "Password UPDATED (changed since golden image was built)"
	else
		log "Password unchanged (matches golden image)"
	fi
else
	log "WARNING: Could not fetch password hash from lab server, skipping"
fi

# SSH authorized_keys sync
current_keys=$(curl -fsSL "${ADDONS_URL}/authorized_keys" 2>/dev/null) || true
if [[ -n "$current_keys" ]]; then
	existing_keys=$(cat /home/${ADMIN_USER}/.ssh/authorized_keys 2>/dev/null) || true
	if [[ "$current_keys" != "$existing_keys" ]]; then
		mkdir -p /home/${ADMIN_USER}/.ssh /root/.ssh
		echo "$current_keys" > /home/${ADMIN_USER}/.ssh/authorized_keys
		echo "$current_keys" > /root/.ssh/authorized_keys
		chmod 600 /home/${ADMIN_USER}/.ssh/authorized_keys /root/.ssh/authorized_keys
		chown ${ADMIN_USER}:${ADMIN_USER} /home/${ADMIN_USER}/.ssh/authorized_keys
		log "SSH authorized_keys UPDATED (changed since golden image was built)"
	else
		log "SSH authorized_keys unchanged (matches golden image)"
	fi
else
	log "WARNING: Could not fetch authorized_keys from lab server, skipping"
fi

# SSH private key sync
current_privkey=$(curl -fsSL "${ADDONS_URL}/tux2lab_id_rsa" 2>/dev/null) || true
if [[ -n "$current_privkey" ]]; then
	existing_privkey=$(cat /home/${ADMIN_USER}/.ssh/tux2lab_id_rsa 2>/dev/null) || true
	if [[ "$current_privkey" != "$existing_privkey" ]]; then
		echo "$current_privkey" > /home/${ADMIN_USER}/.ssh/tux2lab_id_rsa
		echo "$current_privkey" > /root/.ssh/tux2lab_id_rsa
		chmod 600 /home/${ADMIN_USER}/.ssh/tux2lab_id_rsa /root/.ssh/tux2lab_id_rsa
		chown ${ADMIN_USER}:${ADMIN_USER} /home/${ADMIN_USER}/.ssh/tux2lab_id_rsa
		log "SSH private key UPDATED (changed since golden image was built)"
	else
		log "SSH private key unchanged (matches golden image)"
	fi
else
	log "WARNING: Could not fetch SSH private key from lab server, skipping"
fi

log "Running lab rootfs extender"
if ! curl -fsSL "http://get_lab_infra_server_hostname/tux2lab/common-utils/lab-rootfs-extender" | bash -s -- localhost --lab-infra-host=get_lab_infra_server_hostname; then
	log "WARNING: Lab rootfs extender failed, continuing anyway"
fi

log "Generating SSH host keys"
if ! ssh-keygen -A; then
	log "WARNING: SSH host key generation failed, continuing anyway"
else
	log "SSH host keys generated successfully"
	# Ensure keys are written to disk
	sync
	# Verify key files exist
	if ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
		log "SSH host key files verified on disk"
	else
		log "WARNING: SSH host key files not found after generation"
	fi
fi

log "Starting SSH service with new host keys"
if systemctl list-unit-files sshd.service 2>/dev/null | grep -q 'sshd.service'; then
	log "Found sshd.service, enabling and starting..."
	systemctl enable sshd 2>/dev/null || true
	systemctl start sshd && log "SSH service started successfully" || log "WARNING: SSH service start failed"
elif systemctl list-unit-files ssh.service 2>/dev/null | grep -q 'ssh.service'; then
	log "Found ssh.service, enabling and starting..."
	systemctl enable ssh 2>/dev/null || true
	systemctl start ssh && log "SSH service started successfully" || log "WARNING: SSH service start failed"
else
	log "WARNING: No SSH service unit found (sshd.service or ssh.service)"
fi

log "Marking golden boot as completed"
touch "$COMPLETION_MARKER"

log "Disabling golden-boot.service to prevent future execution"
systemctl disable golden-boot.service 2>/dev/null || true

log "Golden boot configuration completed successfully for ${DISTRO_ID}"
