#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -uo pipefail
# Script Name : kvm-validate.sh
# Description : Validate post-install state of VM(s) — networking, services, security, NFS
# Usage       : tux2lab vm validate [OPTIONS]

source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# SSH options for connecting to VMs
ssh_options=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=QUIET
    -o ConnectTimeout=5
    -o PasswordAuthentication=no
    -o PubkeyAuthentication=yes
    -o PreferredAuthentications=publickey
    -o BatchMode=yes
)

# ====== HELP ======
show_usage() {
    print_cyan "Usage: tux2lab vm validate [OPTIONS]

Validate post-install configuration of VM(s).
Checks networking, services, filesystem, NFS mounts, security, and distro-specific settings.

OPTIONS:
    -H, --hosts <hosts>     Comma-separated list of hostnames (e.g., vm1,vm2,vm3)
    -h, --help              Show this help message

BEHAVIOR:
    - Without arguments: Validates all running VMs
    - With -H flag: Validates specified comma-separated VMs

EXIT CODES:
    0   All validations passed
    1   One or more validations failed
    2   Could not reach any target VM

EXAMPLES:
    tux2lab vm validate                        # Validate all running VMs
    tux2lab vm validate -H test-rhel-10        # Validate a single VM
    tux2lab vm validate -H vm1,vm2,vm3         # Validate multiple VMs
"
}

# ====== ARGUMENT PARSING ======
hosts_list=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_usage
            exit 0
            ;;
        -H|--hosts)
            shift
            if [[ -z "${1:-}" ]]; then
                print_error "Option -H/--hosts requires a comma-separated list of hostnames"
                exit 1
            fi
            hosts_list="$1"
            shift
            ;;
        -*)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            print_error "Unexpected argument: $1"
            print_info "Use -H/--hosts to specify hostname(s)."
            show_usage
            exit 1
            ;;
    esac
done

# ====== DETERMINE TARGET VMs ======
declare -a target_vms

if [[ -n "$hosts_list" ]]; then
    IFS=',' read -ra hosts_array <<< "$hosts_list"
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/validate-and-process-hostnames.sh
    if ! validate_and_process_hostnames hosts_array; then
        exit 1
    fi
    # Reject the lab infra server — it has a different validation path
    for vm_candidate in "${VALIDATED_HOSTS[@]}"; do
        if [[ "$vm_candidate" == "$lab_infra_server_hostname" ]]; then
            print_error "Cannot validate the lab infra server with this command."
            print_info "Use 'tux2lab health' to check lab infrastructure services."
            exit 1
        fi
    done
    target_vms=("${VALIDATED_HOSTS[@]}")
else
    # All running VMs (exclude lab infra server)
    mapfile -t target_vms < <(sudo virsh list --state-running --name 2>/dev/null | grep -v "^$" | grep -v "^${lab_infra_server_hostname}$" || true)

    if [[ ${#target_vms[@]} -eq 0 ]]; then
        print_warning "No VMs running other than lab infra server VM ${lab_infra_server_hostname}"
        exit 0
    fi
fi

# ====== VALIDATION ENGINE ======
# Counters (per-VM, reset for each host)
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# Global counters (across all VMs)
TOTAL_VMS=0
TOTAL_PASSED_VMS=0
TOTAL_FAILED_VMS=0
TOTAL_SKIPPED_VMS=0

fn_pass() {
    echo -e "    ${MAKE_IT_GREEN}[PASS]${RESET_COLOR} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fn_fail() {
    echo -e "    ${MAKE_IT_RED}[FAIL]${RESET_COLOR} $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

fn_warn() {
    echo -e "    ${MAKE_IT_YELLOW}[WARN]${RESET_COLOR} $1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

fn_section() {
    echo -e "  ${MAKE_IT_CYAN}── $1${RESET_COLOR}"
}

# ====== REMOTE VALIDATION PAYLOAD ======
# This function generates the script that runs ON the target VM via SSH.
# The lab infra server hostname is passed as $1 to the remote script.
fn_generate_validation_payload() {
    cat << 'VALIDATION_SCRIPT'
#!/bin/bash
set -uo pipefail

LAB_INFRA_SERVER="${1:-}"

# Detect distro family
source /etc/os-release 2>/dev/null || exit 99
DISTRO_ID="${ID}"
DISTRO_VERSION="${VERSION_ID}"

if [[ "$DISTRO_ID" == "ubuntu" ]] || [[ "${ID_LIKE:-}" == *"debian"* ]]; then
    DISTRO_FAMILY="ubuntu"
elif [[ "$DISTRO_ID" == "opensuse-leap" ]] || [[ "$DISTRO_ID" == "opensuse"* ]] || [[ "${ID_LIKE:-}" == *"suse"* ]]; then
    DISTRO_FAMILY="opensuse"
else
    DISTRO_FAMILY="redhat"
fi

HOSTNAME_FQDN=$(hostnamectl --static 2>/dev/null)
DOMAIN=$(echo "$HOSTNAME_FQDN" | cut -d. -f2-)

# Output structured results: CHECK_NAME|STATUS|DETAIL
# STATUS: PASS, FAIL, WARN
emit() { echo "RESULT|$1|$2|$3"; }

# --- Identity ---
[[ "$HOSTNAME_FQDN" == *.* ]] && emit "FQDN set" "PASS" "$HOSTNAME_FQDN" || emit "FQDN set" "FAIL" "$HOSTNAME_FQDN"

# Real DNS validation: forward and reverse lookup
if host "$HOSTNAME_FQDN" &>/dev/null; then
    emit "DNS forward lookup" "PASS" ""
    # Verify reverse lookup matches
    RESOLVED_IP=$(host "$HOSTNAME_FQDN" | head -1 | awk '{print $NF}')
    if host "$RESOLVED_IP" 2>/dev/null | grep -q "$HOSTNAME_FQDN"; then
        emit "DNS reverse lookup" "PASS" "$RESOLVED_IP"
    else
        emit "DNS reverse lookup" "WARN" "PTR may not match"
    fi
else
    emit "DNS forward lookup" "WARN" "may not be populated yet"
fi

# --- Networking ---
IPV4_ADDR=$(ip -4 addr show dev eth0 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
[[ -n "$IPV4_ADDR" ]] && emit "eth0 IPv4" "PASS" "$IPV4_ADDR" || emit "eth0 IPv4" "FAIL" "missing"

IPV6_ADDR=$(ip -6 addr show dev eth0 scope global 2>/dev/null | grep -oP 'inet6 \K[0-9a-f:]+' | head -1)
[[ -n "$IPV6_ADDR" ]] && emit "eth0 IPv6 global" "PASS" "$IPV6_ADDR" || emit "eth0 IPv6 global" "FAIL" "missing"

ip -4 route show default | grep -q via && emit "IPv4 default route" "PASS" "" || emit "IPv4 default route" "FAIL" ""

DAD_VAL=$(sysctl -n net.ipv6.conf.all.accept_dad 2>/dev/null)
[[ "$DAD_VAL" == "0" ]] && emit "IPv6 DAD disabled" "PASS" "" || emit "IPv6 DAD disabled" "WARN" "value=$DAD_VAL"

# Real connectivity: ping the lab infra server (IPv4 + IPv6)
if timeout 3 ping -c 1 "$LAB_INFRA_SERVER" &>/dev/null; then
    emit "Ping infra server (IPv4)" "PASS" ""
else
    emit "Ping infra server (IPv4)" "FAIL" "$LAB_INFRA_SERVER unreachable"
fi

if timeout 3 ping6 -c 1 "$LAB_INFRA_SERVER" &>/dev/null 2>&1 || timeout 3 ping -6 -c 1 "$LAB_INFRA_SERVER" &>/dev/null 2>&1; then
    emit "Ping infra server (IPv6)" "PASS" ""
else
    emit "Ping infra server (IPv6)" "WARN" "IPv6 may not be routable yet"
fi

# Network manager
case "$DISTRO_FAMILY" in
    redhat)   systemctl is-active NetworkManager &>/dev/null && emit "NetworkManager active" "PASS" "" || emit "NetworkManager active" "FAIL" "" ;;
    ubuntu)   systemctl is-active systemd-networkd &>/dev/null && emit "systemd-networkd active" "PASS" "" || emit "systemd-networkd active" "FAIL" "" ;;
    opensuse)
        suse_major="${DISTRO_VERSION%%.*}"
        if [[ "$suse_major" -ge 16 ]]; then
            systemctl is-active NetworkManager &>/dev/null && emit "NetworkManager active" "PASS" "" || emit "NetworkManager active" "FAIL" ""
        else
            systemctl is-active wicked &>/dev/null && emit "wicked active" "PASS" "" || emit "wicked active" "FAIL" ""
        fi
        ;;
esac

# Firewall disabled
case "$DISTRO_FAMILY" in
    redhat|opensuse)
        if systemctl is-active firewalld &>/dev/null; then emit "Firewall disabled" "FAIL" "firewalld active"
        else emit "Firewall disabled" "PASS" ""; fi ;;
    ubuntu)
        if command -v ufw &>/dev/null && ! ufw status 2>/dev/null | grep -q "inactive"; then
            emit "Firewall disabled" "FAIL" "ufw active"
        else emit "Firewall disabled" "PASS" ""; fi ;;
esac

# --- Filesystem ---
ROOT_FS=$(df -T / | awk 'NR==2{print $2}')
if [[ "$ROOT_FS" == "xfs" ]]; then
    emit "Root filesystem" "PASS" "xfs"
elif [[ "$ROOT_FS" == "ext4" ]] && [[ "$DISTRO_FAMILY" == "ubuntu" ]]; then
    emit "Root filesystem" "PASS" "ext4"
else
    emit "Root filesystem" "FAIL" "$ROOT_FS"
fi

ROOT_SIZE_GB=$(df -BG / | awk 'NR==2{gsub(/G/,"",$2); print $2}')
[[ "$ROOT_SIZE_GB" -ge 15 ]] && emit "Root disk grown" "PASS" "${ROOT_SIZE_GB}G" || emit "Root disk grown" "WARN" "${ROOT_SIZE_GB}G"

mountpoint -q /boot/efi 2>/dev/null && emit "EFI partition mounted" "PASS" "" || emit "EFI partition mounted" "FAIL" ""

# --- Services ---
case "$DISTRO_FAMILY" in
    ubuntu) systemctl is-active ssh &>/dev/null && emit "SSH active" "PASS" "" || emit "SSH active" "FAIL" "" ;;
    *)      systemctl is-active sshd &>/dev/null && emit "SSH active" "PASS" "" || emit "SSH active" "FAIL" "" ;;
esac

case "$DISTRO_FAMILY" in
    ubuntu) systemctl is-active chrony &>/dev/null && emit "Chrony active" "PASS" "" || emit "Chrony active" "FAIL" "" ;;
    *)      systemctl is-active chronyd &>/dev/null && emit "Chrony active" "PASS" "" || emit "Chrony active" "FAIL" "" ;;
esac

# Real NTP validation: check chrony is synced to the lab infra server
NTP_SOURCE=$(chronyc sources 2>/dev/null | grep -E '^\^\*' | awk '{print $2}')
if [[ -n "$NTP_SOURCE" ]]; then
    emit "NTP synchronized" "PASS" "source: $NTP_SOURCE"
elif chronyc tracking 2>/dev/null | grep -qiE "Leap status.*Normal"; then
    emit "NTP synchronized" "PASS" ""
else
    emit "NTP synchronized" "WARN" "may still be syncing"
fi

# --- User & Auth ---
MGMT_USER=$(ls /etc/sudoers.d/ 2>/dev/null | grep -v README | head -1)
[[ -z "$MGMT_USER" ]] && MGMT_USER="unknown"

id "$MGMT_USER" &>/dev/null && emit "Mgmt user exists" "PASS" "$MGMT_USER" || emit "Mgmt user exists" "FAIL" "$MGMT_USER"
[[ -f "/etc/sudoers.d/$MGMT_USER" ]] && emit "Sudoers file" "PASS" "" || emit "Sudoers file" "FAIL" ""

# Real sudo validation: actually run a command as the user
if su - "$MGMT_USER" -c "sudo -n true" &>/dev/null; then
    emit "Sudo NOPASSWD works" "PASS" "$MGMT_USER"
else
    emit "Sudo NOPASSWD works" "FAIL" "$MGMT_USER cannot sudo without password"
fi

[[ -s "/home/$MGMT_USER/.ssh/authorized_keys" ]] && emit "SSH authorized_keys" "PASS" "" || emit "SSH authorized_keys" "FAIL" ""
[[ -f "/home/$MGMT_USER/.ssh/tux2lab_id_rsa" ]] && emit "SSH private key" "PASS" "" || emit "SSH private key" "FAIL" ""
[[ -f "/root/.ssh/tux2lab_id_rsa" ]] && emit "Root SSH key" "PASS" "" || emit "Root SSH key" "FAIL" ""
[[ -f "/etc/ssh/ssh_config.d/999-tux2lab.conf" ]] && emit "SSH client config" "PASS" "" || emit "SSH client config" "FAIL" ""

# --- CA Certificate (real HTTPS test) ---
case "$DISTRO_FAMILY" in
    redhat)   CA_PATH="/etc/pki/ca-trust/source/anchors/tux2lab-nginx-selfsigned.crt" ;;
    ubuntu)   CA_PATH="/usr/local/share/ca-certificates/tux2lab-nginx-selfsigned.crt" ;;
    opensuse) CA_PATH="/etc/pki/trust/anchors/tux2lab-nginx-selfsigned.crt" ;;
esac

[[ -f "$CA_PATH" ]] && emit "CA cert file exists" "PASS" "" || emit "CA cert file exists" "FAIL" "$CA_PATH"

# Real validation: HTTPS to lab infra server without --insecure
if curl -sf --max-time 5 "https://${LAB_INFRA_SERVER}/" -o /dev/null 2>/dev/null; then
    emit "HTTPS to infra (trusted)" "PASS" "cert verified by system CA bundle"
else
    # Check if HTTP works (to distinguish cert issue from connectivity)
    if curl -sf --max-time 5 "http://${LAB_INFRA_SERVER}/" -o /dev/null 2>/dev/null; then
        emit "HTTPS to infra (trusted)" "FAIL" "HTTP works but HTTPS cert not trusted"
    else
        emit "HTTPS to infra (trusted)" "WARN" "infra server may not have HTTPS configured"
    fi
fi

# --- Timezone ---
TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "unknown")
[[ "$TZ" == "UTC" || "$TZ" == "Etc/UTC" ]] && emit "Timezone UTC" "PASS" "" || emit "Timezone UTC" "FAIL" "$TZ"

# --- Shell customization ---
[[ -s "/etc/motd" ]] && emit "Motd" "PASS" "" || emit "Motd" "FAIL" ""
grep -q "HISTSIZE=-1" "/home/$MGMT_USER/.bashrc" 2>/dev/null && emit "HISTSIZE set" "PASS" "" || emit "HISTSIZE set" "FAIL" ""
grep -q "PS1" "/home/$MGMT_USER/.bashrc" 2>/dev/null && emit "PS1 customized" "PASS" "" || emit "PS1 customized" "FAIL" ""

# --- Distro-specific ---
case "$DISTRO_FAMILY" in
    redhat)
        SELINUX_STATUS=$(getenforce 2>/dev/null || echo "unknown")
        [[ "$SELINUX_STATUS" == "Disabled" || "$SELINUX_STATUS" == "Permissive" ]] \
            && emit "SELinux disabled" "PASS" "$SELINUX_STATUS" \
            || emit "SELinux disabled" "WARN" "$SELINUX_STATUS"

        systemctl is-enabled systemd-resolved &>/dev/null \
            && emit "systemd-resolved enabled" "PASS" "" \
            || emit "systemd-resolved enabled" "FAIL" ""

        # Real DNS resolution test via systemd-resolved
        if resolvectl query "$LAB_INFRA_SERVER" &>/dev/null; then
            emit "DNS resolution (resolved)" "PASS" ""
        elif [[ -L /etc/resolv.conf ]] && readlink /etc/resolv.conf | grep -q "stub-resolv"; then
            emit "DNS resolution (resolved)" "WARN" "symlink ok but query failed"
        else
            emit "DNS resolution (resolved)" "FAIL" ""
        fi

        if systemctl show dnf-makecache.timer -p LoadState --value 2>/dev/null | grep -q masked; then
            emit "dnf-makecache masked" "PASS" ""
        else
            emit "dnf-makecache masked" "WARN" ""
        fi

        # Real yum repo validation: actually query metadata
        local repo_pattern="${lab_infra_domain_name//./-}"
        if dnf repolist 2>/dev/null | grep -qiE "${repo_pattern}|lab|tux2lab"; then
            emit "Lab yum repo" "PASS" "reachable"
        elif ls /etc/yum.repos.d/*"${repo_pattern}"* &>/dev/null || ls /etc/yum.repos.d/*lab* &>/dev/null || ls /etc/yum.repos.d/*tux2lab* &>/dev/null; then
            emit "Lab yum repo" "WARN" "file exists but repo metadata unreachable"
        else
            emit "Lab yum repo" "FAIL" ""
        fi

        command -v growpart &>/dev/null \
            && emit "growpart available" "PASS" "" \
            || emit "growpart available" "FAIL" ""
        ;;

    ubuntu)
        [[ -f /etc/cloud/cloud-init.disabled ]] \
            && emit "cloud-init disabled" "PASS" "" \
            || emit "cloud-init disabled" "FAIL" ""

        grep -rl "eth0" /etc/netplan/ &>/dev/null \
            && emit "Netplan eth0 config" "PASS" "" \
            || emit "Netplan eth0 config" "FAIL" ""

        for pkg in chrony nfs-common vim tmux kexec-tools; do
            dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" \
                && emit "Package: $pkg" "PASS" "" \
                || emit "Package: $pkg" "FAIL" ""
        done

        if dpkg -l lvm2 2>/dev/null | grep -q "^ii"; then
            emit "lvm2 removed" "FAIL" "still installed"
        else
            emit "lvm2 removed" "PASS" ""
        fi
        ;;

    opensuse)
        systemctl is-active apparmor &>/dev/null \
            && emit "AppArmor active" "PASS" "" \
            || emit "AppArmor active" "WARN" ""

        [[ -f /etc/chrony.d/tux2lab.conf ]] \
            && emit "Chrony tux2lab.conf" "PASS" "" \
            || emit "Chrony tux2lab.conf" "FAIL" ""

        [[ -f /etc/bigbang ]] \
            && emit "Install timestamp" "PASS" "" \
            || emit "Install timestamp" "FAIL" ""

        for pkg in nfs-client xfsprogs kexec-tools; do
            rpm -q "$pkg" &>/dev/null \
                && emit "Package: $pkg" "PASS" "" \
                || emit "Package: $pkg" "FAIL" ""
        done
        ;;
esac

# --- Installation artifacts ---
[[ -f /root/tux2lab-post-install.log ]] && emit "Post-install log" "PASS" "" || emit "Post-install log" "FAIL" ""
[[ -f /root/tux2lab-post-install.sh ]] && emit "Post-install script" "PASS" "" || emit "Post-install script" "FAIL" ""

if [[ "$DISTRO_FAMILY" == "redhat" || "$DISTRO_FAMILY" == "opensuse" ]]; then
    [[ -f /etc/bigbang ]] && emit "Install timestamp" "PASS" "$(cat /etc/bigbang)" || emit "Install timestamp" "FAIL" ""
fi

# Emit distro info for the controller
emit "DISTRO_INFO" "META" "${DISTRO_ID} ${DISTRO_VERSION} (${DISTRO_FAMILY})"
VALIDATION_SCRIPT
}

# ====== VALIDATE A SINGLE VM ======
fn_validate_vm() {
    local vm_name="$1"
    PASS_COUNT=0
    FAIL_COUNT=0
    WARN_COUNT=0

    echo ""
    print_cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_notify "  VM: $vm_name"
    print_cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Check if VM is running (skip for hostnames that might not be virsh-managed)
    local vm_short="${vm_name%.${lab_infra_domain_name}}"
    local vm_state
    vm_state=$(sudo virsh domstate "$vm_name" 2>/dev/null || sudo virsh domstate "$vm_short" 2>/dev/null || echo "unknown")

    if [[ "$vm_state" != "running" ]] && [[ "$vm_state" != "unknown" ]]; then
        print_warning "  VM is not running (state: $vm_state) — skipping"
        TOTAL_SKIPPED_VMS=$((TOTAL_SKIPPED_VMS + 1))
        return
    fi

    # Check SSH reachability
    if ! nc -z -w 3 "$vm_name" 22 &>/dev/null; then
        print_error "  SSH not reachable on port 22 — skipping"
        TOTAL_SKIPPED_VMS=$((TOTAL_SKIPPED_VMS + 1))
        return
    fi

    # Run validation payload remotely — pass infra server hostname as $1
    local raw_output
    raw_output=$(fn_generate_validation_payload | ssh "${ssh_options[@]}" "root@${vm_name}" "bash -s -- ${lab_infra_server_hostname}" 2>/dev/null)

    if [[ $? -ne 0 ]] && [[ -z "$raw_output" ]]; then
        print_error "  SSH connection failed — skipping"
        TOTAL_SKIPPED_VMS=$((TOTAL_SKIPPED_VMS + 1))
        return
    fi

    # Parse structured output
    local distro_info=""
    local current_section=""

    while IFS='|' read -r prefix check status detail; do
        [[ "$prefix" != "RESULT" ]] && continue

        # Group checks into visual sections
        local section=""
        case "$check" in
            FQDN*|DNS*)                    section="Identity" ;;
            eth0*|IPv*|*route*|*DAD*|*Manager*|*networkd*|wicked*|Firewall*) section="Networking" ;;
            Root*|EFI*)                    section="Filesystem" ;;
            SSH\ active|Chrony*|NTP*)   section="Services" ;;
            Mgmt*|Sudo*|SSH\ auth*|SSH\ priv*|Root\ SSH*|SSH\ client*) section="User & Auth" ;;
            CA*)                           section="CA Certificate" ;;
            Timezone*)                     section="Timezone" ;;
            Motd*|HIST*|PS1*)              section="Shell" ;;
            SELinux*|systemd-resolved*|resolv*|dnf*|Lab\ yum*|growpart*) section="RHEL-specific" ;;
            cloud-init*|Netplan*|Package*|lvm2*) section="Distro-specific" ;;
            AppArmor*|Chrony\ tux*|Install\ time*|Service*) section="Distro-specific" ;;
            Post-install*)                 section="Artifacts" ;;
            DISTRO_INFO)                   distro_info="$detail"; continue ;;
            *)                             section="Other" ;;
        esac

        if [[ "$section" != "$current_section" ]]; then
            current_section="$section"
            fn_section "$section"
        fi

        case "$status" in
            PASS) fn_pass "$check${detail:+ ($detail)}" ;;
            FAIL) fn_fail "$check${detail:+ ($detail)}" ;;
            WARN) fn_warn "$check${detail:+ ($detail)}" ;;
        esac
    done <<< "$raw_output"

    # VM summary
    echo ""
    if [[ -n "$distro_info" ]]; then
        echo -e "    ${MAKE_IT_WHITE}Distro: $distro_info${RESET_COLOR}"
    fi
    echo -e "    ${MAKE_IT_GREEN}Passed: $PASS_COUNT${RESET_COLOR}  ${MAKE_IT_RED}Failed: $FAIL_COUNT${RESET_COLOR}  ${MAKE_IT_YELLOW}Warnings: $WARN_COUNT${RESET_COLOR}"

    TOTAL_VMS=$((TOTAL_VMS + 1))
    if [[ $FAIL_COUNT -eq 0 ]]; then
        TOTAL_PASSED_VMS=$((TOTAL_PASSED_VMS + 1))
    else
        TOTAL_FAILED_VMS=$((TOTAL_FAILED_VMS + 1))
    fi
}

# ====== MAIN EXECUTION ======
echo ""
print_cyan "┌──────────────────────────────────────────────────────────────┐"
print_cyan "│          tux2lab VM Post-Install Validation                  │"
print_cyan "└──────────────────────────────────────────────────────────────┘"
print_info "Validating ${#target_vms[@]} VM(s)..."

for vm in "${target_vms[@]}"; do
    fn_validate_vm "$vm"
done

# ====== FINAL SUMMARY ======
echo ""
print_cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_summary "Validated: $TOTAL_VMS  |  Passed: $TOTAL_PASSED_VMS  |  Failed: $TOTAL_FAILED_VMS  |  Skipped: $TOTAL_SKIPPED_VMS"
print_cyan "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $TOTAL_FAILED_VMS -gt 0 ]]; then
    exit 1
elif [[ $TOTAL_VMS -eq 0 ]] && [[ $TOTAL_SKIPPED_VMS -gt 0 ]]; then
    exit 2
else
    exit 0
fi
