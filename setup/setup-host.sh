#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name : setup-host.sh
# Description : Set up the KVM host for tux2lab
#               Installs QEMU/KVM, podman, jq, configures libvirt, creates labbr0 bridge,
#               and installs the tux2lab CLI.
#
# Usage       : /tux2lab/setup/setup-host.sh [--yes]
# If you encounter any issues with this script, or have suggestions or feature requests,
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues
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

# Verify KVM kernel module is loaded
if [[ ! -d /sys/module/kvm ]]; then
    sudo modprobe kvm 2>/dev/null || true
    sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true
    if [[ ! -d /sys/module/kvm ]]; then
        print_error "KVM kernel module is not loaded and could not be loaded."
        print_info "Hardware virtualization (VT-x/AMD-V) must be enabled in your BIOS/UEFI settings."
        print_info "After enabling it, reboot and verify with: lsmod | grep kvm"
        exit 1
    fi
fi

print_warning "This script will configure the tux2lab host environment.
The following actions will be performed:
  - Grant passwordless sudo privileges to user '$USER'
  - Install QEMU/KVM, libvirt, podman, and dependencies
  - Enable and configure libvirtd
  - Create /tux2lab-data directory
  - Set up labbr0 bridge network with dual-stack (IPv4/IPv6)
  - Enable IPv6 forwarding
  - Install tux2lab CLI and bash completion"
if ! $AUTO_YES; then
    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_info "Setup cancelled by user."
        exit 0
    fi
fi

# ============================================================================
# PASSWORDLESS SUDO
# ============================================================================
print_task "Enabling passwordless sudo for $USER..."
cat <<EOF | sudo tee "/etc/sudoers.d/$USER" &>/dev/null
$USER ALL=(ALL) NOPASSWD: ALL
Defaults:$USER !authenticate
EOF
print_task_done

# ============================================================================
# INSTALL PACKAGES
# ============================================================================
REQUIRED_PACKAGES_APT=(
    qemu-kvm qemu-utils libvirt-daemon-system libvirt-clients
    python3-requests python3-libxml2 python3-libvirt
    libosinfo-bin python3-gi gir1.2-libosinfo-1.0 gir1.2-gobject-2.0
    ovmf ed git openssl
    podman jq
    nfs-kernel-server
)
REQUIRED_PACKAGES_DNF=(
    qemu-kvm qemu-img libvirt libvirt-daemon libvirt-daemon-driver-qemu
    python3-requests python3-libxml2 python3-libvirt
    libosinfo python3-gobject gobject-introspection
    edk2-ovmf ed git openssl
    podman jq
    nfs-utils
)
REQUIRED_PACKAGES_ZYPPER=(
    qemu-kvm qemu-tools libvirt libvirt-daemon libvirt-daemon-driver-qemu
    python3-requests python3-libxml2-python python3-libvirt-python
    libosinfo typelib-1_0-Libosinfo-1_0 python3-gobject gobject-introspection
    qemu-ovmf-x86_64 ed git openssl
    podman jq
    nfs-utils
)

if command -v apt-get &>/dev/null; then
    pkg_manager="apt"
    missing_pkgs=()
    for pkg in "${REQUIRED_PACKAGES_APT[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done
elif command -v dnf &>/dev/null; then
    pkg_manager="dnf"
    missing_pkgs=()
    for pkg in "${REQUIRED_PACKAGES_DNF[@]}"; do
        if ! rpm -q "$pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done
elif command -v zypper &>/dev/null; then
    pkg_manager="zypper"
    missing_pkgs=()
    for pkg in "${REQUIRED_PACKAGES_ZYPPER[@]}"; do
        if ! rpm -q "$pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done
else
    print_task "Installing required packages..."
    print_task_fail
    print_error "Unsupported package manager. Only apt-get, dnf, and zypper are supported."
    exit 1
fi

if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
    print_task "Installing required packages..."
    print_task_skip
else
    print_task "Installing required packages..."

    pkg_log=$(mktemp)
    if [[ "$pkg_manager" == "apt" ]]; then
        (sudo apt-get update && sudo apt-get install -y "${missing_pkgs[@]}") &>"$pkg_log" &
        pkg_pid=$!
    elif [[ "$pkg_manager" == "dnf" ]]; then
        sudo dnf install -y "${missing_pkgs[@]}" &>"$pkg_log" &
        pkg_pid=$!
    else
        sudo zypper --non-interactive install "${missing_pkgs[@]}" &>"$pkg_log" &
        pkg_pid=$!
    fi

    elapsed=0
    while kill -0 "$pkg_pid" 2>/dev/null; do
        printf "\r${MAKE_IT_CYAN}[TASK] Installing required packages [%dm %ds]...${RESET_COLOR}\033[K" $((elapsed/60)) $((elapsed%60))
        sleep 1
        elapsed=$((elapsed + 1))
    done
    wait "$pkg_pid" || {
        printf "\r\033[K"
        print_task "Installing required packages..."
        print_task_fail
        print_error "Failed to install required packages:"
        cat "$pkg_log"
        rm -f "$pkg_log"
        exit 1
    }
    rm -f "$pkg_log"
    printf "\r\033[K"
    printf "${MAKE_IT_CYAN}[TASK] Installing required packages (%dm %ds)...${RESET_COLOR}" $((elapsed/60)) $((elapsed%60))
    print_task_done
fi

# ============================================================================
# CONFIGURE LIBVIRTD
# ============================================================================
print_task "Disabling libvirtd-tls and libvirtd-tcp sockets..."
sudo systemctl disable --now libvirtd-tls.socket libvirtd-tcp.socket 2>/dev/null || true
sudo systemctl mask libvirtd-tls.socket libvirtd-tcp.socket 2>/dev/null || true
print_task_done

print_task "Enabling and restarting libvirtd..."
sudo systemctl enable libvirtd &>/dev/null
sudo systemctl restart libvirtd &>/dev/null
retries=0
while ! sudo virsh version &>/dev/null; do
    retries=$((retries + 1))
    if [[ $retries -ge 30 ]]; then
        printf "\r\033[K"
        print_task "Enabling and restarting libvirtd..."
        print_task_fail
        print_error "libvirtd failed to become ready after restart."
        exit 1
    fi
    printf "\r${MAKE_IT_CYAN}[TASK] Enabling and restarting libvirtd [%dm %ds]...${RESET_COLOR}\033[K" $((retries/60)) $((retries%60))
    sleep 1
done
printf "\r\033[K"
printf "${MAKE_IT_CYAN}[TASK] Enabling and restarting libvirtd (%dm %ds)...${RESET_COLOR}" $((retries/60)) $((retries%60))
print_task_done

# ============================================================================
# CREATE DATA DIRECTORY
# ============================================================================
print_task "Creating /tux2lab-data directory..."
sudo mkdir -p /tux2lab-data/vms
sudo chown -R "$USER":"$(id -g)" /tux2lab-data || {
    print_task_fail
    print_error "Failed to set ownership of /tux2lab-data."
    exit 1
}
print_task_done

# ============================================================================
# SETUP BRIDGE NETWORK (labbr0 — dual-stack)
# ============================================================================
virsh_network_name="tux2lab"
virsh_network_definition="/tux2lab/qemu-kvm-manage/labbr0.xml"

if [[ ! -f "$virsh_network_definition" ]]; then
    print_error "Network definition file not found: $virsh_network_definition"
    exit 1
fi

ipv4_labbr0=$(awk -F"'" '/<ip address=/ && !/family=/ {print $2}' "$virsh_network_definition" | head -1)
ipv6_labbr0=$(awk -F"'" '/<ip family=.ipv6/ {print $4}' "$virsh_network_definition")

if [[ -z "$ipv4_labbr0" ]]; then
    print_error "Failed to extract IPv4 address from $virsh_network_definition"
    exit 1
fi
if [[ -z "$ipv6_labbr0" ]]; then
    print_error "Failed to extract IPv6 address from $virsh_network_definition"
    exit 1
fi

run_virsh_cmd() {
    sudo virsh "$@" &>/dev/null
}

if ( ip link show labbr0 &>/dev/null && ip addr show labbr0 | grep -q "$ipv4_labbr0" && ip addr show labbr0 | grep -q "$ipv6_labbr0" ) && \
   sudo virsh net-info "$virsh_network_name" &>/dev/null; then
    print_task "Setting up bridge network labbr0..."
    print_task_skip
else
    print_task "Setting up bridge network labbr0..."
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

# Remove libvirt default network (virbr0 + dnsmasq conflicts with kea)
if sudo virsh net-info default &>/dev/null; then
    print_task "Removing libvirt default network (virbr0)..."
    run_virsh_cmd net-destroy default || true
    run_virsh_cmd net-undefine default || true
    print_task_done
fi

# Attach dummy interface to keep labbr0 UP (provides carrier for bridge)
source /tux2lab/shared-functions/lablink0.sh
ensure_lablink0 labbr0

# ============================================================================
# INSTALL tux2lab CLI
# ============================================================================
print_task "Installing tux2lab CLI..."
scripts_directory="/tux2lab/qemu-kvm-manage/scripts-to-manage-vms"
if [[ ! -f "$scripts_directory/tux2lab.sh" ]]; then
    print_task_fail
    print_error "tux2lab.sh not found at $scripts_directory/tux2lab.sh"
    exit 1
fi
sudo ln -sf "$scripts_directory/tux2lab.sh" /usr/local/bin/tux2lab
print_task_done

print_task "Installing bash completion..."
if [[ -f "$scripts_directory/tux2lab-completion.bash" ]]; then
    sudo ln -sf "$scripts_directory/tux2lab-completion.bash" /etc/bash_completion.d/tux2lab-completion.bash
    print_task_done
else
    print_task_skip
fi

# ============================================================================
# DONE
# ============================================================================
print_success "Host setup completed!"
print_info "Next: run 'tux2lab deploy' to deploy the lab infrastructure."

exit 0
