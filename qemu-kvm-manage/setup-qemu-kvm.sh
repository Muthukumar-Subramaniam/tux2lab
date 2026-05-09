#!/bin/bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#

source /tux2lab/common-utils/color-functions.sh

if [[ "$EUID" -eq 0 ]]; then
    print_error "Running as root user is not allowed."
    print_info "This script should be run as a user with sudo privileges, not as root."
    exit 1
fi

# Check if we're inside a QEMU guest
if command -v dmidecode &>/dev/null; then
    if sudo dmidecode -s system-manufacturer | grep -qi 'QEMU'; then
        print_error "This script cannot be executed inside a QEMU guest VM."
        print_info "This script must be run on the host system managing QEMU/KVM virtual machines."
        print_info "Current environment is a QEMU guest, which is not supported."
        exit 1
    fi
fi

print_warning "This script will configure QEMU/KVM virtualization environment on this system."
print_info "The following actions will be performed:
  - Grant passwordless sudo privileges to user '$USER'
  - Install QEMU/KVM hypervisor and virtualization packages
  - Install and configure libvirtd daemon service
  - Create /kvm-hub directory for VM storage and management
  - Set up custom labbr0 bridge network with dual-stack (IPv4/IPv6) support
  - Install custom VM management tools (qlabvmctl, qlabstart, qlabhealth, qlabdnsbinder)"
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    print_info "Setup cancelled by user."
    exit 0
fi
echo ""

print_task "Enabling passwordless sudo for $USER"
cat <<EOF | sudo tee "/etc/sudoers.d/$USER" &>/dev/null
$USER ALL=(ALL) NOPASSWD: ALL
Defaults:$USER !authenticate
EOF
print_task_done

print_info "Installing required packages for QEMU/KVM..."

if command -v apt-get &>/dev/null; then
    sudo apt-get update && sudo apt-get install -y qemu-kvm qemu-utils libvirt-daemon-system libvirt-clients python3-requests python3-libxml2 python3-libvirt libosinfo-bin python3-gi gir1.2-libosinfo-1.0 gir1.2-gobject-2.0 ovmf ed git openssl || {
        print_error "Failed to install required packages."
        exit 1
    }
elif command -v dnf &>/dev/null; then
    sudo dnf install -y qemu-kvm qemu-img libvirt libvirt-daemon libvirt-daemon-driver-qemu python3-requests python3-libxml2 python3-libvirt libosinfo python3-gobject gobject-introspection edk2-ovmf ed git openssl || {
        print_error "Failed to install required packages."
        exit 1
    }
else
    print_error "Unsupported package manager. Only apt-get and dnf are supported."
    exit 1
fi

print_info "Disabling libvirtd-tls and libvirtd-tcp sockets..."
sudo systemctl disable --now libvirtd-tls.socket libvirtd-tcp.socket
sudo systemctl mask libvirtd-tls.socket libvirtd-tcp.socket

print_info "Enabling and starting libvirtd..."
sudo systemctl enable --now libvirtd
sudo systemctl status libvirtd -l --no-pager

print_task "Creating /kvm-hub/vms to manage VMs"
sudo mkdir -p /kvm-hub/vms || {
    print_error "Failed to create /kvm-hub/vms directory."
    exit 1
}
sudo chown -R "$USER":"$(id -g)" /kvm-hub || {
    print_error "Failed to change ownership of /kvm-hub directory."
    exit 1
}
print_task_done

VENDORED_VIRT_MANAGER_DIR="/tux2lab/vendor/virt-manager"
if [[ ! -d "${VENDORED_VIRT_MANAGER_DIR}/virtinst" || ! -f "${VENDORED_VIRT_MANAGER_DIR}/virt-install" ]]; then
    print_error "Vendored virt-manager files not found at ${VENDORED_VIRT_MANAGER_DIR}."
    print_info "Expected: ${VENDORED_VIRT_MANAGER_DIR}/virtinst and ${VENDORED_VIRT_MANAGER_DIR}/virt-install"
    exit 1
fi

print_task "Ensuring vendored virt-manager entrypoints are executable"
sudo chmod +x "${VENDORED_VIRT_MANAGER_DIR}/virt-install"
print_task_done

print_info "Using direct vendored invocation for virt-install (no /usr/local/bin wrappers)."

virsh_network_name="default"
virsh_network_definition="/tux2lab/qemu-kvm-manage/labbr0.xml"

if [[ ! -f "$virsh_network_definition" ]]; then
    print_error "Network definition file not found: $virsh_network_definition"
    exit 1
fi

# Extract both IPv4 and IPv6 addresses from labbr0.xml (dual-stack)
ipv4_labbr0=$(grep -oP "<ip address='\K[^']+" "$virsh_network_definition" | head -1)
ipv6_labbr0=$(grep -oP "<ip family='ipv6' address='\K[^']+" "$virsh_network_definition")

if [[ -z "$ipv4_labbr0" ]]; then
    print_error "Failed to extract IPv4 address from $virsh_network_definition"
    exit 1
fi

if [[ -z "$ipv6_labbr0" ]]; then
    print_error "Failed to extract IPv6 address from $virsh_network_definition"
    print_info "Dual-stack support required. Please ensure labbr0.xml has IPv6 configured."
    exit 1
fi

if ( ip link show labbr0 &>/dev/null && ip addr show labbr0 | grep -q "$ipv4_labbr0" && ip addr show labbr0 | grep -q "$ipv6_labbr0" ); then
    print_success "labbr0 already has dual-stack configured (IPv4: $ipv4_labbr0, IPv6: $ipv6_labbr0) — skipping task."
else
    print_task "Setting up custom bridge network labbr0 for QEMU/KVM"
    run_virsh_cmd() {
        sudo virsh "$@" &>/dev/null
    }
    run_virsh_cmd net-destroy "$virsh_network_name"
    run_virsh_cmd net-undefine "$virsh_network_name"
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

print_task "Creating custom tools to manage QEMU/KVM"
scripts_directory="/tux2lab/qemu-kvm-manage/scripts-to-manage-vms"
sudo ln -sf "$scripts_directory/qlabvmctl.sh" /usr/local/bin/qlabvmctl
sudo ln -sf "$scripts_directory/qlabstart.sh" /usr/local/bin/qlabstart
sudo ln -sf "$scripts_directory/qlabhealth.sh" /usr/local/bin/qlabhealth
sudo ln -sf "$scripts_directory/qlabdnsbinder.sh" /usr/local/bin/qlabdnsbinder
print_task_done

print_task "Installing bash completion for qlabvmctl"
sudo ln -sf "$scripts_directory/qlabvmctl-completion.bash" /etc/bash_completion.d/qlabvmctl-completion.bash
print_task_done

print_success "QEMU/KVM setup completed successfully!"

exit 0
