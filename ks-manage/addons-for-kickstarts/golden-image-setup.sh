#!/bin/bash
#Golden Image Preparation Script
if [ -f /root/golden-image-setup-completed ]; then
	exit
fi

LOG=/root/golden-image-setup.log
echo -e "\nGolden Image Cleanup Started: $(date)\n" | tee -a "$LOG"

# 1. Clear machine-id
echo "Clearing machine-id..." | tee -a "$LOG"
truncate -s 0 /etc/machine-id

# 2. Clear hostname so deployed VMs don't boot with golden image name
echo "Clearing hostname..." | tee -a "$LOG"
truncate -s 0 /etc/hostname
rm -f /etc/sysctl.d/hostname.conf 2>>"$LOG"

# 3. Remove SSH host keys and disable SSH service
echo "Removing SSH host keys..." | tee -a "$LOG"
rm -f /etc/ssh/ssh_host_* 2>>"$LOG"
echo "Disabling SSH service and socket (will be re-enabled by golden-boot script)..." | tee -a "$LOG"
if systemctl list-unit-files 2>/dev/null | grep -q '^sshd.service'; then
	systemctl disable sshd 2>>"$LOG" || true
	systemctl disable sshd.socket 2>>"$LOG" || true
elif systemctl list-unit-files 2>/dev/null | grep -q '^ssh.service'; then
	systemctl disable ssh 2>>"$LOG" || true
	systemctl disable ssh.socket 2>>"$LOG" || true
fi

# 4. Disable cloud-init if present
echo "Disabling cloud-init (if present)..." | tee -a "$LOG"
#touch /etc/cloud/cloud-init.disabled 2>>"$LOG"

# 5. Remove NetworkManager system connections
echo "Removing NetworkManager system connections..." | tee -a "$LOG"
if grep -qi "rhel" /etc/os-release; then
	rm -f /etc/NetworkManager/system-connections/* 2>>"$LOG"
elif grep -qi "debian" /etc/os-release; then
	rm -rf /etc/netplan/* 2>>"$LOG"
	cat << EOF > /etc/netplan/50-golden-boot-dhcp.yaml
network:
    version: 2
    ethernets:
        golden-boot-dhcp:
            match:
                name: "e*"
            dhcp4: true
EOF
	chmod 600 /etc/netplan/50-golden-boot-dhcp.yaml
elif grep -qi "suse" /etc/os-release; then
if command -v nmcli &>/dev/null && systemctl is-active --quiet NetworkManager; then
	# Leap 16+ uses NetworkManager
	nmcli connection delete eth0 2>/dev/null || true
	nmcli connection add type ethernet con-name eth0 ifname eth0 \
		ipv4.method auto connection.autoconnect yes
else
	# Leap 15.x uses wicked
	cat << EOF > /etc/sysconfig/network/ifcfg-eth0
BOOTPROTO='dhcp'
STARTMODE='auto'
ZONE='public'
EOF
fi
fi

# 6. Remove systemd-networkd configs
echo "Removing systemd network configuration files..." | tee -a "$LOG"
rm -f /etc/systemd/network/*.link 2>>"$LOG"

# 7. Self-disable this service
echo "Disabling this service after successful run..." | tee -a "$LOG"
systemctl disable golden-image-setup.service 2>>"$LOG"

# 8. Bring down the interface so that other script won't get activated
echo "Bringing down eth0 interface..." | tee -a "$LOG"
ip link set dev eth0 down

# 9. Touch a file to mark completion of this script
touch /root/golden-image-setup-completed

# 10. Stop syslog to prevent buffered messages from being written after truncation
systemctl stop rsyslog 2>/dev/null || true

# 11. Truncate all log files under /var/log
find /var/log -type f -exec truncate -s 0 {} \;

# 12. Clear journald persistent logs
rm -rf /var/log/journal/*

# 13. Final shutdown
shutdown -h now
