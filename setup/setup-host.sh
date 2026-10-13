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

usage="Usage: /tux2lab/setup/setup-host.sh [--yes]"
AUTO_YES=false
if [[ $# -gt 1 ]]; then
    print_error "Too many arguments."
    print_info "$usage"
    exit 1
fi
case "${1:-}" in
    "") ;;
    --yes) AUTO_YES=true ;;
    -h|--help) print_info "$usage"; exit 0 ;;
    *)
        print_error "Unknown option: $1"
        print_info "$usage"
        exit 1
        ;;
esac

host_arch=$(uname -m)
if [[ "$host_arch" != "x86_64" ]]; then
    print_error "Unsupported host architecture: $host_arch. tux2lab requires an x86_64 host."
    exit 1
fi

if [[ "$EUID" -eq 0 ]]; then
    print_error "Running as root user is not allowed."
    print_info "This script should be run as a user with sudo privileges, not as root."
    exit 1
fi

if ! command -v sudo &>/dev/null; then
    print_error "sudo is not installed."
    print_info "As root, install sudo and grant '$USER' sudo rights, then rerun setup."
    exit 1
fi
# sudo -v prompts whenever any matching rule needs a password, even if a NOPASSWD rule also matches
if ! sudo -n true 2>/dev/null && ! sudo -v; then
    print_error "User '$USER' cannot use sudo."
    print_info "Grant '$USER' sudo rights, then rerun setup."
    exit 1
fi

# /dev/kvm only exists once kvm_intel or kvm_amd initialises; the kvm core module alone proves nothing
if [[ ! -c /dev/kvm ]]; then
    sudo modprobe kvm_intel 2>/dev/null || sudo modprobe kvm_amd 2>/dev/null || true
    if [[ ! -c /dev/kvm ]]; then
        print_error "KVM is not available: /dev/kvm is missing."
        print_info "Enable hardware virtualization (VT-x/AMD-V) in BIOS/UEFI, or nested virtualization if this host is a VM."
        print_info "Diagnose with: grep -Ec 'vmx|svm' /proc/cpuinfo; sudo dmesg | grep -i kvm"
        exit 1
    fi
fi

print_yellow "This script will configure the tux2lab host environment.
The following actions will be performed:
  - Grant passwordless sudo privileges to user '$USER'
  - Install QEMU/KVM, libvirt, podman, and dependencies
  - Enable and configure libvirtd
  - Create /tux2lab-data directory
  - Set up labbr0 bridge network with dual-stack (IPv4/IPv6)
  - Remove the libvirt 'default' network (virbr0)
  - Trust labbr0 in the host firewall
  - Enable IPv6 forwarding
  - Install tux2lab CLI and bash completion"
if ! $AUTO_YES; then
    read -rp "Are you sure you want to continue? (yes/no): " confirm || { [[ -t 0 ]] && echo; confirm=""; }
    if [[ "$confirm" != "yes" ]]; then
        print_info "Setup cancelled by user."
        exit 0
    fi
fi

# ============================================================================
# PASSWORDLESS SUDO
# ============================================================================
print_task "Enabling passwordless sudo for $USER..."
# sudo skips sudoers.d files whose names contain '.', so map dots in the username
sudoers_file="/etc/sudoers.d/${USER//./_}"
# Staged under a dotted name so sudo ignores it until it is validated and renamed
sudoers_stage="$sudoers_file.tux2lab-tmp"
sudoers_content="$USER ALL=(ALL) NOPASSWD: ALL"$'\n'
# sudo-rs has no 'authenticate' setting and rejects the whole file if it is present
if [[ "$(sudo --version 2>/dev/null)" != sudo-rs* ]]; then
    sudoers_content+="Defaults:$USER !authenticate"$'\n'
fi
if ! printf '%s' "$sudoers_content" \
        | sudo tee "$sudoers_stage" >/dev/null 2>&1 \
    || ! sudo chmod 0440 "$sudoers_stage" 2>/dev/null \
    || ! sudo visudo -cqf "$sudoers_stage" >/dev/null 2>&1 \
    || ! sudo mv -f "$sudoers_stage" "$sudoers_file" 2>/dev/null; then
    sudo rm -f "$sudoers_stage" 2>/dev/null || true
    print_task_fail
    print_error "Could not install $sudoers_file; existing sudo configuration was left untouched."
    print_info "Diagnose with: sudo visudo -c"
    exit 1
fi
print_task_done

# ============================================================================
# INSTALL PACKAGES
# ============================================================================
REQUIRED_PACKAGES_APT=(
    qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients
    python3-requests python3-libxml2 python3-libvirt
    libosinfo-bin python3-gi gir1.2-libosinfo-1.0 gir1.2-glib-2.0
    ovmf ed git openssl
    podman jq bind9-dnsutils
    nfs-kernel-server rsync
)
REQUIRED_PACKAGES_DNF=(
    qemu-kvm qemu-img libvirt libvirt-daemon libvirt-daemon-driver-qemu
    python3-requests python3-libxml2 python3-libvirt
    libosinfo python3-gobject gobject-introspection
    edk2-ovmf ed git openssl
    podman jq bind-utils
    nfs-utils rsync
)
REQUIRED_PACKAGES_ZYPPER=(
    qemu-kvm qemu-tools libvirt libvirt-daemon libvirt-daemon-driver-qemu
    python3-requests python3-libxml2-python python3-libvirt-python
    libosinfo typelib-1_0-Libosinfo-1_0 python3-gobject gobject-introspection
    qemu-ovmf-x86_64 ed git openssl
    podman jq bind-utils
    nfs-utils rsync
)

if command -v apt-get &>/dev/null; then
    pkg_manager="apt"
    missing_pkgs=()
    for pkg in "${REQUIRED_PACKAGES_APT[@]}"; do
        # Removed-but-not-purged packages pass 'dpkg -s'; the prefix match tolerates multiarch duplicates
        if [[ "$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null)" != installed* ]]; then
            missing_pkgs+=("$pkg")
        fi
    done
elif command -v dnf &>/dev/null; then
    pkg_manager="dnf"
    os_id=$(. /etc/os-release 2>/dev/null; echo "${ID:-}")
    # Azure Linux ships libosinfo, podman and crun only in its extended repository
    if [[ "$os_id" == "azurelinux" ]]; then
        REQUIRED_PACKAGES_DNF+=(crun netavark)
        print_task "Enabling Azure Linux extended repository..."
        if rpm -q azurelinux-repos-extended &>/dev/null; then
            print_task_skip
        elif sudo dnf install -y azurelinux-repos-extended &>/dev/null; then
            print_task_done
        else
            print_task_fail
            print_error "Failed to install azurelinux-repos-extended."
            print_info "Diagnose with: sudo dnf install azurelinux-repos-extended"
            exit 1
        fi
    fi
    missing_pkgs=()
    for pkg in "${REQUIRED_PACKAGES_DNF[@]}"; do
        # --whatprovides also matches virtual names that resolve to a differently named package
        if ! rpm -q --whatprovides "$pkg" &>/dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done
elif command -v zypper &>/dev/null; then
    pkg_manager="zypper"
    missing_pkgs=()
    for pkg in "${REQUIRED_PACKAGES_ZYPPER[@]}"; do
        # Leap installs qemu-kvm as qemu and nfs-utils as nfs-kernel-server
        if ! rpm -q --whatprovides "$pkg" &>/dev/null; then
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

    pkg_log=$(mktemp) || {
        print_task_fail
        print_error "Could not create a temporary log file."
        exit 1
    }
    if [[ "$pkg_manager" == "apt" ]]; then
        (sudo apt-get update \
            && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
                -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
                "${missing_pkgs[@]}") &>"$pkg_log" &
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
remote_sockets=(libvirtd-tls.socket libvirtd-tcp.socket)
if [[ "$(systemctl is-enabled "${remote_sockets[@]}" 2>/dev/null | sort -u)" == "masked" ]] \
    && ! systemctl is-active --quiet "${remote_sockets[@]}"; then
    print_task_skip
elif sudo systemctl disable --now "${remote_sockets[@]}" &>/dev/null \
    && sudo systemctl mask "${remote_sockets[@]}" &>/dev/null; then
    print_task_done
else
    print_task_fail
    print_error "Failed to disable and mask ${remote_sockets[*]}."
    exit 1
fi

# tux2lab drives the monolithic libvirtd; the modular daemons claim the same sockets and must stay off
print_task "Disabling libvirt modular daemons..."
mapfile -t modular_units < <( {
    systemctl list-unit-files --no-legend --plain --state=enabled,enabled-runtime 'virt*d.service' 'virt*d*.socket'
    systemctl list-units --no-legend --plain --state=active 'virt*d.service' 'virt*d*.socket'
} 2>/dev/null | awk '$1 !~ /^virtlo(g|ck)d/ {print $1}' | sort -u)
if (( ${#modular_units[@]} == 0 )); then
    print_task_skip
elif sudo systemctl disable --now "${modular_units[@]}" &>/dev/null; then
    print_task_done
else
    print_task_fail
    print_error "Failed to disable libvirt modular daemons: ${modular_units[*]}"
    exit 1
fi

print_task "Enabling and starting libvirtd..."
# systemd refuses to open libvirtd's sockets while the service is already running without them
if systemctl is-active --quiet libvirtd.service && ! systemctl is-active --quiet libvirtd.socket; then
    sudo systemctl stop libvirtd.service &>/dev/null || true
fi
if ! sudo systemctl enable --now libvirtd.service libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket &>/dev/null; then
    print_task_fail
    print_error "Failed to enable and start libvirtd."
    print_info "Diagnose with: sudo systemctl status libvirtd"
    exit 1
fi
retries=0
while ! sudo virsh version &>/dev/null; do
    retries=$((retries + 1))
    if [[ $retries -ge 30 ]]; then
        printf "\r\033[K"
        print_task "Enabling and starting libvirtd..."
        print_task_fail
        print_error "libvirtd failed to become ready after start."
        exit 1
    fi
    printf "\r${MAKE_IT_CYAN}[TASK] Enabling and starting libvirtd [%dm %ds]...${RESET_COLOR}\033[K" $((retries/60)) $((retries%60))
    sleep 1
done
printf "\r\033[K"
printf "${MAKE_IT_CYAN}[TASK] Enabling and starting libvirtd (%dm %ds)...${RESET_COLOR}" $((retries/60)) $((retries%60))
print_task_done

# ============================================================================
# CREATE DATA DIRECTORY
# ============================================================================
print_task "Creating /tux2lab-data directory..."
sudo mkdir -p /tux2lab-data/vms
# Not recursive: on a rerun the tree holds files owned by service accounts (named's logs) that must keep their owner
sudo chown "$USER":"$(id -g)" /tux2lab-data /tux2lab-data/vms || {
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

# Open firewall for lab bridge (if host has restrictive iptables)
source /tux2lab/shared-functions/bridge-firewall.sh
open_bridge_firewall labbr0

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
    sudo mkdir -p /etc/bash_completion.d
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
