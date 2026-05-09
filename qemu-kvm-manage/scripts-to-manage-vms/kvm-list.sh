#!/bin/bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#

source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

if [ "$#" -ne 0 ]; then
    echo -e "\n❌ 'tux2lab vm list' does not take any arguments.\n"
    exit 1
fi

mapfile -t vm_list < <(sudo virsh list --all | awk 'NR>2 && $2 != "" {print $2}')

ssh_options="-o StrictHostKeyChecking=no \
             -o UserKnownHostsFile=/dev/null \
             -o LogLevel=QUIET \
             -o ConnectTimeout=2 \
             -o PasswordAuthentication=no \
             -o PubkeyAuthentication=yes \
             -o PreferredAuthentications=publickey \
             -o BatchMode=yes"

COLOR_GREEN=$'\033[0;32m'
COLOR_YELLOW=$'\033[0;33m'
COLOR_RED=$'\033[0;31m'
COLOR_RESET=$'\033[0m'

declare -a results=()
declare -A vm_states

# Get all VM states in one call instead of multiple domstate calls
while read -r vm_name state _; do
    vm_states["$vm_name"]="$state"
done < <(sudo virsh list --all | awk 'NR>2 && $2 != "" {print $2, $3}')

# ────────────────────────────────────────────────────────────────
# Collect data (parallel)
# ────────────────────────────────────────────────────────────────
tmp_dir=$(mktemp -d)
trap "rm -rf $tmp_dir" EXIT

check_vm() {
    local vm_name=$1
    local tmp_file=$2
    local current_vm_state="${vm_states[$vm_name]:-[ N/A ]}"
    local current_os_state="[ N/A ]"
    local os_distro="[ N/A ]"

    if [[ "$current_vm_state" == "running" ]]; then
        # Test SSH port availability with netcat
        if nc -z -w 1 "$vm_name" 22 &>/dev/null; then
            ssh_output=$(ssh $ssh_options "${lab_infra_admin_username}@${vm_name}" \
                'systemctl is-system-running; \
                 source /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "[ N/A ]"' \
                2>/dev/null </dev/null || true)

            if [[ -n "$ssh_output" ]]; then
                mapfile -t ssh_lines <<< "$ssh_output"
                current_os_state="${ssh_lines[0]}"
                os_distro="${ssh_lines[1]}"
            else
                current_os_state="SSH-Not-Ready"
            fi
        else
            current_os_state="SSH-Not-Ready"
        fi
    fi

    # Color by health
    case "$current_os_state" in
        running) current_os_state="healthy"; color="$COLOR_GREEN" ;;
        "[ N/A ]") color="$COLOR_RED" ;;
        *) color="$COLOR_YELLOW" ;;
    esac

    echo "${color}${vm_name}|${current_vm_state}|${current_os_state}|${os_distro}${COLOR_RESET}" > "$tmp_file"
}

export -f check_vm
export lab_infra_admin_username ssh_options COLOR_GREEN COLOR_YELLOW COLOR_RED COLOR_RESET
export -A vm_states

# Launch parallel checks
for vm_name in "${vm_list[@]}"; do
    check_vm "$vm_name" "$tmp_dir/$vm_name" &
done

# Wait for all to complete
wait

# Collect results in original order
for vm_name in "${vm_list[@]}"; do
    if [[ -f "$tmp_dir/$vm_name" ]]; then
        results+=("$(<"$tmp_dir/$vm_name")")
    fi
done

# ────────────────────────────────────────────────────────────────
# Determine max column widths (strip colors for length)
# ────────────────────────────────────────────────────────────────
max_vm=8; max_vmstate=8; max_osstate=8; max_osdistro=9
declare -a clean_results=()

for entry in "${results[@]}"; do
    clean=$(echo "$entry" | sed 's/\x1b\[[0-9;]*m//g')
    clean_results+=("$clean")
    IFS='|' read -r vm state os distro <<< "$clean"
    (( ${#vm} > max_vm )) && max_vm=${#vm}
    (( ${#state} > max_vmstate )) && max_vmstate=${#state}
    (( ${#os} > max_osstate )) && max_osstate=${#os}
    (( ${#distro} > max_osdistro )) && max_osdistro=${#distro}
done

# ────────────────────────────────────────────────────────────────
# Print header
# ────────────────────────────────────────────────────────────────
printf "%-${max_vm}s %-${max_vmstate}s %-${max_osstate}s %-${max_osdistro}s\n" \
    "VM-Name" "VM-State" "OS-State" "OS-Distro"
printf -- '-%.0s' $(seq 1 $((max_vm + max_vmstate + max_osstate + max_osdistro + 3)))
echo

# ────────────────────────────────────────────────────────────────
# Sort and print with colors
# ────────────────────────────────────────────────────────────────
# Assign sort weight: running = 1, everything else = 2
sorted_indices=($(for i in "${!clean_results[@]}"; do
    IFS='|' read -r vm state _ <<< "${clean_results[$i]}"
    case "$state" in
        running) weight=1 ;;
        *) weight=2 ;;
    esac
    printf "%d %s %s\n" "$weight" "$vm" "$i"
done | sort -k1,1n -k2,2 | awk '{print $3}'))

for idx in "${sorted_indices[@]}"; do
    raw="${results[$idx]}"
    clean="${clean_results[$idx]}"
    IFS='|' read -r vm state os distro <<< "$clean"
    color_line=$(echo "$raw" | grep -oP '^\x1b\[[0-9;]*m')
    reset_line=$COLOR_RESET
    printf "%s%-${max_vm}s %- ${max_vmstate}s %- ${max_osstate}s %- ${max_osdistro}s%s\n" \
        "$color_line" "$vm" "$state" "$os" "$distro" "$reset_line"
done
