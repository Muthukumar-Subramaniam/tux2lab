#!/bin/bash
set -uo pipefail

# =============================================================================
# tux2lab post-install validation script (all distros)
# Validates that a freshly installed VM has all expected configuration.
# Run as root on the target VM, or remotely via SSH.
#
# Usage:
#   ./run-post-install-validation.sh [hostname]
#   If hostname is provided, runs remotely via SSH.
#   If no hostname, runs locally (must be root).
# =============================================================================

# --- Color output ---
fn_pass() { echo -e "  \e[32m[PASS]\e[0m $1"; }
fn_fail() { echo -e "  \e[31m[FAIL]\e[0m $1"; FAILURES=$((FAILURES + 1)); }
fn_warn() { echo -e "  \e[33m[WARN]\e[0m $1"; WARNINGS=$((WARNINGS + 1)); }
fn_section() { echo -e "\n\e[1;36m=== $1 ===\e[0m"; }

PASS_COUNT=0
FAILURES=0
WARNINGS=0

fn_check() {
    # Usage: fn_check "description" command
    local desc="$1"
    shift
    if "$@" &>/dev/null; then
        fn_pass "$desc"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fn_fail "$desc"
    fi
}

fn_check_output() {
    # Usage: fn_check_output "description" expected_pattern command...
    local desc="$1"
    local pattern="$2"
    shift 2
    local output
    output=$("$@" 2>/dev/null)
    if echo "$output" | grep -qiE "$pattern"; then
        fn_pass "$desc"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        fn_fail "$desc (got: $output)"
    fi
}

# =============================================================================
# Determine execution mode (local or remote)
# =============================================================================
TARGET_HOST="${1:-}"
if [[ -n "$TARGET_HOST" ]]; then
    # Remote mode — generate the validation payload and run via SSH
    echo "Running validation remotely on: $TARGET_HOST"
    # Re-exec this script on the remote host
    exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=QUIET "root@${TARGET_HOST}" "bash -s" < "$0"
fi

# =============================================================================
# Local execution starts here (on the target VM)
# =============================================================================
if [[ $(id -u) -ne 0 ]]; then
    echo "ERROR: Must run as root" >&2
    exit 1
fi

# --- Detect distro family ---
source /etc/os-release 2>/dev/null || { echo "ERROR: /etc/os-release not found"; exit 1; }
DISTRO_ID="${ID}"
DISTRO_VERSION="${VERSION_ID}"

if [[ "$DISTRO_ID" == "ubuntu" ]] || [[ "${ID_LIKE:-}" == *"debian"* ]]; then
    DISTRO_FAMILY="ubuntu"
elif [[ "$DISTRO_ID" == "opensuse-leap" ]] || [[ "$DISTRO_ID" == "opensuse"* ]] || [[ "${ID_LIKE:-}" == *"suse"* ]]; then
    DISTRO_FAMILY="opensuse"
else
    DISTRO_FAMILY="redhat"
fi

HOSTNAME_FQDN=$(hostname -f 2>/dev/null || hostname)
DOMAIN=$(echo "$HOSTNAME_FQDN" | cut -d. -f2-)
SHORT_HOST=$(echo "$HOSTNAME_FQDN" | cut -d. -f1)

echo "============================================================"
echo " tux2lab Post-Install Validation"
echo " Host:   $HOSTNAME_FQDN"
echo " Distro: $DISTRO_ID $DISTRO_VERSION ($DISTRO_FAMILY)"
echo " Date:   $(date)"
echo "============================================================"

# =============================================================================
# 1. IDENTITY & HOSTNAME
# =============================================================================
fn_section "Identity & Hostname"

fn_check "FQDN contains domain" echo "$HOSTNAME_FQDN" | grep -q '\.'
fn_check "/etc/hostname or hostnamectl is set" [[ -n "$(hostnamectl --static 2>/dev/null)" ]]

# DNS forward resolution
if host "$HOSTNAME_FQDN" &>/dev/null; then
    fn_pass "DNS forward lookup resolves"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    fn_warn "DNS forward lookup failed (may be expected if DNS not yet populated)"
fi

# =============================================================================
# 2. NETWORKING
# =============================================================================
fn_section "Networking"

# IPv4
IPV4_ADDR=$(ip -4 addr show dev eth0 2>/dev/null | grep -oP 'inet \K[0-9.]+')
if [[ -n "$IPV4_ADDR" ]]; then
    fn_pass "eth0 has IPv4 address: $IPV4_ADDR"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    fn_fail "eth0 missing IPv4 address"
fi

# IPv6
IPV6_ADDR=$(ip -6 addr show dev eth0 scope global 2>/dev/null | grep -oP 'inet6 \K[0-9a-f:]+')
if [[ -n "$IPV6_ADDR" ]]; then
    fn_pass "eth0 has IPv6 global address: $IPV6_ADDR"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    fn_fail "eth0 missing IPv6 global address"
fi

# Default gateway
fn_check "IPv4 default route exists" ip -4 route show default | grep -q via

# IPv6 DAD disabled
DAD_SYSCTL=$(sysctl -n net.ipv6.conf.all.accept_dad 2>/dev/null)
if [[ "$DAD_SYSCTL" == "0" ]]; then
    fn_pass "IPv6 DAD disabled (sysctl)"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    fn_warn "IPv6 DAD not disabled (value=$DAD_SYSCTL) — may cause bind errors"
fi

# Network manager check (distro-specific)
case "$DISTRO_FAMILY" in
    redhat)
        fn_check "NetworkManager is active" systemctl is-active NetworkManager
        ;;
    ubuntu)
        # Netplan with systemd-networkd
        fn_check "systemd-networkd is active" systemctl is-active systemd-networkd
        ;;
    opensuse)
        fn_check "wicked is active" systemctl is-active wicked
        ;;
esac

# Firewall disabled
case "$DISTRO_FAMILY" in
    redhat)
        if systemctl is-active firewalld &>/dev/null; then
            fn_fail "firewalld is still active"
        else
            fn_pass "firewalld is inactive"
            PASS_COUNT=$((PASS_COUNT + 1))
        fi
        ;;
    ubuntu)
        if ufw status 2>/dev/null | grep -q "inactive"; then
            fn_pass "UFW is inactive"
            PASS_COUNT=$((PASS_COUNT + 1))
        elif ! command -v ufw &>/dev/null; then
            fn_pass "UFW not installed (firewall off)"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            fn_fail "UFW is active"
        fi
        ;;
    opensuse)
        if systemctl is-active firewalld &>/dev/null; then
            fn_fail "firewalld is active"
        else
            fn_pass "firewall is inactive"
            PASS_COUNT=$((PASS_COUNT + 1))
        fi
        ;;
esac

# =============================================================================
# 3. FILESYSTEM & DISK
# =============================================================================
fn_section "Filesystem & Disk"

ROOT_FS=$(df -T / | awk 'NR==2{print $2}')
if [[ "$ROOT_FS" == "xfs" ]]; then
    fn_pass "Root filesystem is XFS"
    PASS_COUNT=$((PASS_COUNT + 1))
elif [[ "$ROOT_FS" == "ext4" ]] && [[ "$DISTRO_FAMILY" == "ubuntu" ]]; then
    fn_pass "Root filesystem is ext4 (Ubuntu default)"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    fn_fail "Root filesystem is $ROOT_FS (expected xfs)"
fi

# Disk size check — should be extended beyond default
ROOT_SIZE_GB=$(df -BG / | awk 'NR==2{gsub(/G/,"",$2); print $2}')
if [[ "$ROOT_SIZE_GB" -ge 15 ]]; then
    fn_pass "Root disk extended: ${ROOT_SIZE_GB}G"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    fn_warn "Root disk only ${ROOT_SIZE_GB}G (may not have been grown)"
fi

# EFI partition exists
if mountpoint -q /boot/efi 2>/dev/null; then
    fn_pass "/boot/efi mounted (UEFI)"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    fn_fail "/boot/efi not mounted"
fi

# =============================================================================
# 4. SERVICES
# =============================================================================
fn_section "Services"

# SSH
case "$DISTRO_FAMILY" in
    ubuntu)
        fn_check "SSH service active" systemctl is-active ssh
        ;;
    *)
        fn_check "SSH service active" systemctl is-active sshd
        ;;
esac

# Chrony/NTP
case "$DISTRO_FAMILY" in
    ubuntu)
        fn_check "Chrony service active" systemctl is-active chrony
        ;;
    *)
        fn_check "Chrony service active" systemctl is-active chronyd
        ;;
esac

# NTP sync check
if chronyc tracking 2>/dev/null | grep -qiE "Reference.*:.*[0-9]|Leap status.*Normal"; then
    fn_pass "Chrony is synchronized"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    fn_warn "Chrony may not be synchronized yet"
fi

# Autofs
fn_check "autofs service active" systemctl is-active autofs

# =============================================================================
# 5. NFS AUTOMOUNTS
# =============================================================================
fn_section "NFS Automounts"

for MOUNT_DIR in /tux2lab /tux2lab-data /lab-share; do
    if ls "$MOUNT_DIR/" &>/dev/null && mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
        fn_pass "$MOUNT_DIR auto-mounted via NFS"
        PASS_COUNT=$((PASS_COUNT + 1))
    elif [[ -d "$MOUNT_DIR" ]]; then
        # Directory exists, try to trigger automount
        ls "$MOUNT_DIR/" &>/dev/null
        sleep 1
        if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
            fn_pass "$MOUNT_DIR auto-mounted via NFS (triggered)"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            fn_fail "$MOUNT_DIR directory exists but NFS not mounting"
        fi
    else
        fn_fail "$MOUNT_DIR directory missing"
    fi
done

# Autofs map file exists
LOCAL_LAB_INFO=$(echo "$DOMAIN" | sed 's/\./-/g')
AUTOFS_MAP="/etc/auto.master.d/auto-${LOCAL_LAB_INFO}"
fn_check "Autofs map file exists ($AUTOFS_MAP)" [[ -f "$AUTOFS_MAP" ]]

# =============================================================================
# 6. USER & AUTHENTICATION
# =============================================================================
fn_section "User & Authentication"

# Detect management user from sudoers.d
MGMT_USER=$(ls /etc/sudoers.d/ 2>/dev/null | grep -v README | head -1)
if [[ -z "$MGMT_USER" ]]; then
    MGMT_USER="tux2lab"  # fallback
fi

fn_check "Management user '$MGMT_USER' exists" id "$MGMT_USER"
fn_check "Sudoers file exists for $MGMT_USER" [[ -f "/etc/sudoers.d/$MGMT_USER" ]]

# SSH keys
fn_check "SSH authorized_keys for $MGMT_USER" [[ -s "/home/$MGMT_USER/.ssh/authorized_keys" ]]
fn_check "SSH private key for $MGMT_USER" [[ -f "/home/$MGMT_USER/.ssh/tux2lab_id_rsa" ]]
fn_check "SSH public key for $MGMT_USER" [[ -f "/home/$MGMT_USER/.ssh/tux2lab_id_rsa.pub" ]]

# Root SSH keys
fn_check "SSH authorized_keys for root" [[ -s "/root/.ssh/authorized_keys" ]]
fn_check "SSH private key for root" [[ -f "/root/.ssh/tux2lab_id_rsa" ]]

# SSH client config
fn_check "SSH client config (999-tux2lab.conf)" [[ -f "/etc/ssh/ssh_config.d/999-tux2lab.conf" ]]

# =============================================================================
# 7. CA CERTIFICATE
# =============================================================================
fn_section "CA Certificate"

case "$DISTRO_FAMILY" in
    redhat)
        CA_PATH="/etc/pki/ca-trust/source/anchors/tux2lab-nginx-selfsigned.crt"
        ;;
    ubuntu)
        CA_PATH="/usr/local/share/ca-certificates/tux2lab-nginx-selfsigned.crt"
        ;;
    opensuse)
        CA_PATH="/etc/pki/trust/anchors/tux2lab-nginx-selfsigned.crt"
        ;;
esac

fn_check "CA certificate file exists ($CA_PATH)" [[ -f "$CA_PATH" ]]

# Verify it's trusted in the system bundle
if [[ "$DISTRO_FAMILY" == "redhat" ]]; then
    TRUSTED_BUNDLE="/etc/pki/tls/certs/ca-bundle.crt"
elif [[ "$DISTRO_FAMILY" == "ubuntu" ]]; then
    TRUSTED_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
elif [[ "$DISTRO_FAMILY" == "opensuse" ]]; then
    TRUSTED_BUNDLE="/etc/ssl/ca-bundle.pem"
fi

CA_CN=$(openssl x509 -in "$CA_PATH" -noout -subject 2>/dev/null | sed 's/.*CN *= *//')
if [[ -n "$CA_CN" ]] && grep -q "tux2lab" "$TRUSTED_BUNDLE" 2>/dev/null; then
    fn_pass "CA cert trusted in system bundle (CN=$CA_CN)"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    fn_fail "CA cert not found in trusted bundle"
fi

# =============================================================================
# 8. TIMEZONE & LOCALE
# =============================================================================
fn_section "Timezone & Locale"

TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null)
if [[ "$TZ" == "UTC" ]]; then
    fn_pass "Timezone is UTC"
    PASS_COUNT=$((PASS_COUNT + 1))
else
    fn_fail "Timezone is $TZ (expected UTC)"
fi

# =============================================================================
# 9. SHELL CUSTOMIZATION
# =============================================================================
fn_section "Shell Customization"

fn_check "HISTSIZE set in $MGMT_USER .bashrc" grep -q "HISTSIZE=-1" "/home/$MGMT_USER/.bashrc"
fn_check "PS1 customized in $MGMT_USER .bashrc" grep -q "PS1" "/home/$MGMT_USER/.bashrc"
fn_check "Motd exists" [[ -s "/etc/motd" ]]

# =============================================================================
# 10. DISTRO-SPECIFIC CHECKS
# =============================================================================
fn_section "Distro-Specific ($DISTRO_FAMILY)"

case "$DISTRO_FAMILY" in
    redhat)
        # SELinux
        SELINUX_STATUS=$(getenforce 2>/dev/null || echo "unknown")
        if [[ "$SELINUX_STATUS" == "Disabled" ]] || [[ "$SELINUX_STATUS" == "Permissive" ]]; then
            fn_pass "SELinux is $SELINUX_STATUS"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            fn_warn "SELinux is $SELINUX_STATUS (lab template disables it)"
        fi

        # systemd-resolved
        fn_check "systemd-resolved enabled" systemctl is-enabled systemd-resolved

        # /etc/resolv.conf is symlink to stub
        if [[ -L /etc/resolv.conf ]] && readlink /etc/resolv.conf | grep -q "stub-resolv"; then
            fn_pass "/etc/resolv.conf -> stub-resolv.conf"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            fn_fail "/etc/resolv.conf not symlinked to stub-resolv.conf"
        fi

        # dnf-makecache masked
        if systemctl show dnf-makecache.timer -p LoadState --value 2>/dev/null | grep -q masked; then
            fn_pass "dnf-makecache.timer masked"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            fn_warn "dnf-makecache.timer not masked"
        fi

        # Yum repo configured
        fn_check "Lab yum repo configured" ls /etc/yum.repos.d/*tux2lab* 2>/dev/null || ls /etc/yum.repos.d/*lab* 2>/dev/null

        # cloud-utils-growpart installed
        fn_check "cloud-utils-growpart available" command -v growpart
        ;;

    ubuntu)
        # cloud-init disabled
        fn_check "cloud-init disabled" [[ -f /etc/cloud/cloud-init.disabled ]]

        # Netplan config exists for eth0
        fn_check "Netplan config for eth0" ls /etc/netplan/*eth0* 2>/dev/null || grep -rl "eth0" /etc/netplan/ 2>/dev/null

        # Packages that should be present
        for pkg in chrony autofs nfs-common vim tmux kexec-tools; do
            if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
                fn_pass "Package installed: $pkg"
                PASS_COUNT=$((PASS_COUNT + 1))
            else
                fn_fail "Package missing: $pkg"
            fi
        done

        # lvm2 should be removed
        if dpkg -l lvm2 2>/dev/null | grep -q "^ii"; then
            fn_fail "lvm2 still installed (should be removed)"
        else
            fn_pass "lvm2 not installed"
            PASS_COUNT=$((PASS_COUNT + 1))
        fi
        ;;

    opensuse)
        # AppArmor
        if systemctl is-active apparmor &>/dev/null; then
            fn_pass "AppArmor active"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            fn_warn "AppArmor not active"
        fi

        # Chrony NTP server pointing to lab
        if [[ -f /etc/chrony.d/tux2lab.conf ]]; then
            fn_pass "Chrony tux2lab.conf exists"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            fn_fail "Chrony tux2lab.conf missing"
        fi

        # Installation timestamp
        fn_check "Installation timestamp (/etc/bigbang)" [[ -f /etc/bigbang ]]

        # Packages that should be present
        for pkg in autofs chrony tmux tar openssh wicked xfsprogs kexec-tools; do
            if rpm -q "$pkg" &>/dev/null; then
                fn_pass "Package installed: $pkg"
                PASS_COUNT=$((PASS_COUNT + 1))
            else
                fn_fail "Package missing: $pkg"
            fi
        done

        # Services that should NOT be enabled (previously removed)
        for svc in cups smartd mcelog irqbalance postfix; do
            if systemctl is-enabled "$svc" &>/dev/null 2>&1; then
                fn_fail "Service $svc is still enabled (should be removed)"
            else
                fn_pass "Service $svc not enabled"
                PASS_COUNT=$((PASS_COUNT + 1))
            fi
        done
        ;;
esac

# =============================================================================
# 11. INSTALLATION LOG & TIMESTAMP
# =============================================================================
fn_section "Installation Artifacts"

fn_check "Post-install log exists" [[ -f /root/tux2lab-post-install.log ]]
fn_check "Post-install script exists" [[ -f /root/tux2lab-post-install.sh ]]

if [[ "$DISTRO_FAMILY" == "opensuse" ]] || [[ "$DISTRO_FAMILY" == "redhat" ]]; then
    fn_check "Installation timestamp (/etc/bigbang)" [[ -f /etc/bigbang ]]
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo "============================================================"
echo -e " \e[1mValidation Summary\e[0m"
echo "============================================================"
echo -e "  \e[32mPassed:   $PASS_COUNT\e[0m"
echo -e "  \e[31mFailed:   $FAILURES\e[0m"
echo -e "  \e[33mWarnings: $WARNINGS\e[0m"
echo "============================================================"

if [[ $FAILURES -gt 0 ]]; then
    echo -e "  \e[31mRESULT: VALIDATION FAILED\e[0m"
    exit 1
else
    echo -e "  \e[32mRESULT: VALIDATION PASSED\e[0m"
    exit 0
fi
