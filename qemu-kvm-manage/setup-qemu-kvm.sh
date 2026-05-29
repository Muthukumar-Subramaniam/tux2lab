#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#

source /tux2lab/common-utils/color-functions.sh
set -euo pipefail

AUTO_YES=false
if [[ "${1:-}" == "--yes" ]]; then
    AUTO_YES=true
fi

if [[ "$EUID" -eq 0 ]]; then
    print_error "Running as root user is not allowed."
    print_info "This script should be run as a user with sudo privileges, not as root."
    exit 1
fi

# Cleanup predecessor project (server-hub) if detected
bash /tux2lab/qemu-kvm-manage/cleanup-old-server-hub.sh

# Verify KVM kernel module is loaded (hardware virtualization must be enabled in BIOS/UEFI)
if [[ ! -d /sys/module/kvm ]]; then
    # Module not loaded — attempt to load it before failing
    sudo modprobe kvm 2>/dev/null || true
    sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true
    if [[ ! -d /sys/module/kvm ]]; then
        print_error "KVM kernel module is not loaded and could not be loaded."
        print_info "Hardware virtualization (VT-x/AMD-V) must be enabled in your BIOS/UEFI settings."
        print_info "After enabling it, reboot and verify with: lsmod | grep kvm"
        exit 1
    fi
fi

print_warning "This script will configure QEMU/KVM virtualization environment on this system."
print_cyan "The following actions will be performed:
  - Grant passwordless sudo privileges to user '$USER'
  - Install QEMU/KVM hypervisor and virtualization packages
  - Install and configure libvirtd daemon service
  - Create /tux2lab-data directory for VM storage and management
  - Set up custom labbr0 bridge network with dual-stack (IPv4/IPv6) support
  - Install custom VM management tool (tux2lab)"
echo ""
if ! $AUTO_YES; then
    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_info "Setup cancelled by user."
        exit 0
    fi
fi
echo ""

print_task "Enabling passwordless sudo for $USER..."
cat <<EOF | sudo tee "/etc/sudoers.d/$USER" &>/dev/null
$USER ALL=(ALL) NOPASSWD: ALL
Defaults:$USER !authenticate
EOF
print_task_done

print_task "Installing required packages for QEMU/KVM..."

if command -v apt-get &>/dev/null; then
    sudo apt-get update &>/dev/null && sudo apt-get install -y qemu-kvm qemu-utils libvirt-daemon-system libvirt-clients python3-requests python3-libxml2 python3-libvirt libosinfo-bin python3-gi gir1.2-libosinfo-1.0 gir1.2-gobject-2.0 ovmf ed git openssl &>/dev/null &
    pkg_pid=$!
elif command -v dnf &>/dev/null; then
    sudo dnf install -y qemu-kvm qemu-img libvirt libvirt-daemon libvirt-daemon-driver-qemu python3-requests python3-libxml2 python3-libvirt libosinfo python3-gobject gobject-introspection edk2-ovmf ed git openssl &>/dev/null &
    pkg_pid=$!
else
    print_task_fail
    print_error "Unsupported package manager. Only apt-get and dnf are supported."
    exit 1
fi

elapsed=0
while kill -0 "$pkg_pid" 2>/dev/null; do
    printf "\r${MAKE_IT_CYAN}[TASK] Installing required packages for QEMU/KVM [%dm %ds]...${RESET_COLOR}\033[K" $((elapsed/60)) $((elapsed%60))
    sleep 1
    elapsed=$((elapsed + 1))
done
wait "$pkg_pid" || {
    printf "\r\033[K"
    print_task "Installing required packages for QEMU/KVM..."
    print_task_fail
    print_error "Failed to install required packages."
    exit 1
}
printf "\r\033[K"
print_task "Installing required packages for QEMU/KVM..."
print_task_done

print_task "Disabling libvirtd-tls and libvirtd-tcp sockets..."
sudo systemctl disable --now libvirtd-tls.socket libvirtd-tcp.socket 2>/dev/null || true
sudo systemctl mask libvirtd-tls.socket libvirtd-tcp.socket 2>/dev/null || true
print_task_done

print_task "Enabling and restarting libvirtd..."
sudo systemctl enable libvirtd &>/dev/null
sudo systemctl restart libvirtd &>/dev/null
# Wait for libvirtd socket to become ready
retries=0
while ! sudo virsh version &>/dev/null; do
    retries=$((retries + 1))
    if [[ $retries -ge 30 ]]; then
        print_task_fail
        print_error "libvirtd failed to become ready after restart."
        exit 1
    fi
    sleep 1
done
print_task_done

print_task "Creating /tux2lab-data/vms to manage VMs..."
sudo mkdir -p /tux2lab-data/vms || {
    print_task_fail
    print_error "Failed to create /tux2lab-data/vms directory."
    exit 1
}
sudo chown -R "$USER":"$(id -g)" /tux2lab-data || {
    print_task_fail
    print_error "Failed to change ownership of /tux2lab-data directory."
    exit 1
}
print_task_done

virsh_network_name="tux2lab"
virsh_network_definition="/tux2lab/qemu-kvm-manage/labbr0.xml"

if [[ ! -f "$virsh_network_definition" ]]; then
    print_error "Network definition file not found: $virsh_network_definition"
    exit 1
fi

# Extract both IPv4 and IPv6 addresses from labbr0.xml (dual-stack)
ipv4_labbr0=$(awk -F"'" '/<ip address=/ && !/family=/ {print $2}' "$virsh_network_definition" | head -1)
ipv6_labbr0=$(awk -F"'" '/<ip family=.ipv6/ {print $4}' "$virsh_network_definition")

if [[ -z "$ipv4_labbr0" ]]; then
    print_error "Failed to extract IPv4 address from $virsh_network_definition"
    exit 1
fi

if [[ -z "$ipv6_labbr0" ]]; then
    print_error "Failed to extract IPv6 address from $virsh_network_definition"
    print_info "Dual-stack support required. Please ensure labbr0.xml has IPv6 configured."
    exit 1
fi

run_virsh_cmd() {
    sudo virsh "$@" &>/dev/null
}

# Check if the virsh network is already active with correct IPs
if ( ip link show labbr0 &>/dev/null && ip addr show labbr0 | grep -q "$ipv4_labbr0" && ip addr show labbr0 | grep -q "$ipv6_labbr0" ) && \
   sudo virsh net-info "$virsh_network_name" &>/dev/null; then
    print_task "Setting up custom bridge network labbr0 for QEMU/KVM..."
    print_task_skip
else
    print_task "Setting up custom bridge network labbr0 for QEMU/KVM..."
    run_virsh_cmd net-destroy "$virsh_network_name" || true
    run_virsh_cmd net-undefine "$virsh_network_name" || true
    run_virsh_cmd net-define "$virsh_network_definition" || {
        print_error "Failed to define network from $virsh_network_definition"
        exit 1
    }
    run_virsh_cmd net-start "$virsh_network_name" || {
        print_error "Failed to start network $virsh_network_name"
        exit 1
    }
    run_virsh_cmd net-autostart "$virsh_network_name"
    print_task_done
fi

# Remove libvirt's default network (virbr0 + dnsmasq) — its dnsmasq binds 0.0.0.0:67
# which blocks Kea DHCP from opening raw sockets on labbr0
if sudo virsh net-info default &>/dev/null; then
    print_task "Removing libvirt default network (virbr0)..."
    run_virsh_cmd net-destroy default || true
    run_virsh_cmd net-undefine default || true
    print_task_done
fi

print_task "Creating custom tools to manage QEMU/KVM..."
scripts_directory="/tux2lab/qemu-kvm-manage/scripts-to-manage-vms"
if [[ ! -f "$scripts_directory/tux2lab.sh" ]]; then
    print_task_fail
    print_error "tux2lab.sh not found at $scripts_directory/tux2lab.sh"
    exit 1
fi
sudo ln -sf "$scripts_directory/tux2lab.sh" /usr/local/bin/tux2lab
print_task_done

print_task "Installing bash completion for tux2lab..."
if [[ ! -f "$scripts_directory/tux2lab-completion.bash" ]]; then
    print_task_fail
    print_error "tux2lab-completion.bash not found at $scripts_directory/tux2lab-completion.bash"
    exit 1
fi
sudo ln -sf "$scripts_directory/tux2lab-completion.bash" /etc/bash_completion.d/tux2lab-completion.bash
print_task_done

print_success "QEMU/KVM setup completed successfully!"

exit 0
