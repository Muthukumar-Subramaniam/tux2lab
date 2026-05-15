#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -euo pipefail
# Script Name : kvm-info.sh
# Description : Display detailed information about VM(s) - IP stack, storage, birthdate, uptime, CPU, memory
# Usage       : tux2lab vm info [hostname] or tux2lab vm info -H host1,host2,host3

source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# SSH options for connecting to VMs
ssh_options=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=QUIET
    -o ConnectTimeout=3
    -o PasswordAuthentication=no
    -o PubkeyAuthentication=yes
    -o PreferredAuthentications=publickey
    -o BatchMode=yes
)

# Display usage information
show_usage() {
    print_cyan "Usage: tux2lab vm info [OPTIONS] [hostname]

Display detailed VM information including IP stack, storage, birthdate, uptime, CPU, and memory.

OPTIONS:
    -H, --hosts <hosts>     Comma-separated list of hostnames (e.g., vm1,vm2,vm3)
    -h, --help              Show this help message

ARGUMENTS:
    hostname                Single hostname to query (optional)

BEHAVIOR:
    - Without arguments: Shows info for ALL running VMs accessible via SSH
    - With hostname: Shows info for specified VM
    - With -H flag: Shows info for specified comma-separated VMs

EXAMPLES:
    tux2lab vm info                    # Show info for all running VMs
    tux2lab vm info vm1                # Show info for vm1
    tux2lab vm info -H vm1,vm2,vm3     # Show info for vm1, vm2, and vm3

INFORMATION DISPLAYED:
    - Hostname and VM state
    - CPU cores and memory (allocated/used)
    - Birthdate (system installation time from /etc/bigbang)
    - Uptime
    - IPv4 and IPv6 addresses (all interfaces)
    - Storage devices and sizes
    - OS distribution
"
}

# Parse command-line arguments
hosts_list=""
single_host=""

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
            if [[ -z "$single_host" ]]; then
                single_host="$1"
            else
                print_error "Multiple positional arguments provided. Use -H for multiple hosts."
                exit 1
            fi
            shift
            ;;
    esac
done

# Determine which VMs to query
declare -a target_vms

if [[ -n "$hosts_list" ]]; then
    # Parse comma-separated list and validate hostnames
    IFS=',' read -ra hosts_array <<< "$hosts_list"
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/validate-and-process-hostnames.sh
    if ! validate_and_process_hostnames hosts_array; then
        exit 1
    fi
    target_vms=("${VALIDATED_HOSTS[@]}")
elif [[ -n "$single_host" ]]; then
    # Validate and normalize single hostname
    source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/input-hostname.sh "$single_host" "ALLOW_SELF_REFERENCE"
    target_vms=("$qemu_kvm_hostname")
else
    # Get all running VMs
    mapfile -t all_vms < <(sudo virsh list --state-running | awk 'NR>2 && $2 != "" {print $2}')
    
    # Filter to only those accessible via SSH
    for vm in "${all_vms[@]}"; do
        if nc -z -w 1 "$vm" 22 &>/dev/null; then
            target_vms+=("$vm")
        fi
    done
    
    if [[ ${#target_vms[@]} -eq 0 ]]; then
        print_warning "No running VMs accessible via SSH found"
        exit 0
    fi
fi

# Function to get VM info from hypervisor
get_vm_hypervisor_info() {
    local vm_name="$1"
    local cpu_count memory_kb mac_addrs nic_info
    
    # Check if VM exists
    if ! sudo virsh dominfo "$vm_name" &>/dev/null; then
        echo "VM_NOT_FOUND"
        return
    fi
    
    cpu_count=$(sudo virsh dominfo "$vm_name" | awk '/^CPU\(s\):/ {print $2}')
    memory_kb=$(sudo virsh dominfo "$vm_name" | awk '/^Max memory:/ {print $3}')
    memory_mb=$((memory_kb / 1024))
    
    echo "${cpu_count}|${memory_mb}"
}

# Function to gather VM information via SSH
get_vm_info() {
    local vm_name="$1"
    
    # Check if VM is running
    local vm_state
    vm_state=$(sudo virsh domstate "$vm_name" 2>/dev/null) || vm_state="unknown"
    
    if [[ "$vm_state" != "running" ]]; then
        print_yellow "$vm_name"
        printf "└── $(print_yellow "State:") %s\n" "$vm_state"
        echo
        return
    fi
    
    # Check SSH availability
    if ! nc -z -w 1 "$vm_name" 22 &>/dev/null; then
        print_yellow "$vm_name"
        printf "└── $(print_yellow "State:") %s\n" "$vm_state (SSH not accessible)"
        echo
        return
    fi
    
    # Get hypervisor info
    local hypervisor_info=$(get_vm_hypervisor_info "$vm_name")
    if [[ "$hypervisor_info" == "VM_NOT_FOUND" ]]; then
        print_red "VM '$vm_name' not found in hypervisor"
        echo
        return
    fi
    
    IFS='|' read -r cpu_cores memory_mb <<< "$hypervisor_info"
    
    # Gather information from VM
    local vm_data=$(ssh "${ssh_options[@]}" "${lab_infra_admin_username}@${vm_name}" bash <<'EOSSH'
# OS Distribution
os_distro="N/A"
if [ -f /etc/os-release ]; then
    source /etc/os-release
    os_distro="$PRETTY_NAME"
fi

# Birthdate from /etc/bigbang
birthdate="N/A"
if [ -f /etc/bigbang ]; then
    birthdate=$(</etc/bigbang)
fi

# Uptime
uptime_info=$(uptime -p 2>/dev/null || uptime | awk -F'up ' '{split($2,a,","); print a[1]}')

# Load average
load_avg=$(awk '{printf "%s, %s, %s", $1, $2, $3}' /proc/loadavg)

# Memory usage (in MB)
mem_total=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
mem_used=$(awk '/MemTotal/ {total=$2} /MemAvailable/ {avail=$2} END {printf "%.0f", (total-avail)/1024}' /proc/meminfo)

# Root filesystem usage
root_fs_info=$(df -h / | awk 'NR==2 {printf "%s|%s|%s|%s", $2, $3, $4, $5}')

# IP addresses with CIDR notation (IPv4 and IPv6)
ipv4_addrs=$(ip -4 addr show | awk '/inet / && !/127.0.0.1/ {printf "%s%s", (n++?",":""), $2}')
ipv6_addrs=$(ip -6 addr show | awk '/inet6 / && !/::1/ && !/fe80:/ {printf "%s%s", (n++?",":""), $2}')

# Default gateways
ipv4_gateway=$(ip -4 route show default | awk '{print $3; exit}')
ipv6_gateway=$(ip -6 route show default | awk '{print $3; exit}')
[[ -z "$ipv4_gateway" ]] && ipv4_gateway="N/A"
[[ -z "$ipv6_gateway" ]] && ipv6_gateway="N/A"

# Storage devices
storage_info=$(lsblk -dno NAME,SIZE,TYPE | awk '/disk/ {printf "%s%s:%s", (n++?",":""), $1, $2}')

# NIC information (interface:mac)
nic_info=$(ip -o link show | awk '!/lo:/ && /link\/ether/ {
    gsub(/:$/,"",$2); 
    for(i=1;i<=NF;i++) {
        if($i=="link/ether") {
            printf "%s:%s,", $2, $(i+1); 
            break
        }
    }
}' | sed 's/,$//')

# Output all info separated by |
echo "${os_distro}|${birthdate}|${uptime_info}|${load_avg}|${mem_total}|${mem_used}|${root_fs_info}|${ipv4_addrs}|${ipv6_addrs}|${ipv4_gateway}|${ipv6_gateway}|${storage_info}|${nic_info}"
EOSSH
)
    
    if [[ -z "$vm_data" ]]; then
        print_yellow "$vm_name"
        printf "└── $(print_yellow "State:") %s\n" "$vm_state (Failed to retrieve information)"
        echo
        return
    fi
    
    # Parse the data
    IFS='|' read -r os_distro birthdate uptime load_avg mem_total mem_used root_fs_total root_fs_used root_fs_avail root_fs_percent ipv4_addrs ipv6_addrs ipv4_gateway ipv6_gateway storage_info nic_info <<< "$vm_data"
    
    # Display information
    print_green "$vm_name"
    
    printf "├── $(print_cyan "OS:") %s\n" "$os_distro"
    printf "├── $(print_cyan "Birthdate:") %s\n" "$birthdate"
    printf "├── $(print_cyan "Uptime:") %s  │  $(print_cyan "Load:") %s\n" "$uptime" "$load_avg"
    printf "├── $(print_cyan "Resources")\n"
    printf "│   ├── CPU: %s cores\n" "$cpu_cores"
    printf "│   ├── Memory: %s MB allocated  │  %s MB used / %s MB total\n" "$memory_mb" "$mem_used" "$mem_total"
    printf "│   └── Root FS: %s total  │  %s used (%s)  │  %s available\n" "$root_fs_total" "$root_fs_used" "$root_fs_percent" "$root_fs_avail"
    
    printf "├── $(print_cyan "Network")\n"
    if [[ -n "$nic_info" ]]; then
        IFS=',' read -ra nic_array <<< "$nic_info"
        printf "│   ├── NICs\n"
        for ((i=0; i<${#nic_array[@]}; i++)); do
            IFS=':' read -r iface mac <<< "${nic_array[i]}"
            if [[ $i -eq $((${#nic_array[@]} - 1)) ]]; then
                printf "│   │   └── %s - %s\n" "$iface" "$mac"
            else
                printf "│   │   ├── %s - %s\n" "$iface" "$mac"
            fi
        done
    fi
    
    if [[ -n "$ipv4_addrs" ]]; then
        IFS=',' read -ra ipv4_array <<< "$ipv4_addrs"
        printf "│   ├── IPv4\n"
        for ((i=0; i<${#ipv4_array[@]}; i++)); do
            printf "│   │   ├── %s\n" "${ipv4_array[i]}"
        done
        if [[ "$ipv4_gateway" != "N/A" ]]; then
            printf "│   │   └── Gateway: %s\n" "$ipv4_gateway"
        fi
    fi
    
    if [[ -n "$ipv6_addrs" ]]; then
        IFS=',' read -ra ipv6_array <<< "$ipv6_addrs"
        printf "│   └── IPv6\n"
        for ((i=0; i<${#ipv6_array[@]}; i++)); do
            if [[ $i -eq $((${#ipv6_array[@]} - 1)) ]] && [[ "$ipv6_gateway" == "N/A" ]]; then
                printf "│       └── %s\n" "${ipv6_array[i]}"
            else
                printf "│       ├── %s\n" "${ipv6_array[i]}"
            fi
        done
        if [[ "$ipv6_gateway" != "N/A" ]]; then
            printf "│       └── Gateway: %s\n" "$ipv6_gateway"
        fi
    elif [[ -n "$ipv4_addrs" ]]; then
        printf "│   └── IPv6: None\n"
    fi
    
    if [[ -z "$ipv4_addrs" && -z "$ipv6_addrs" ]]; then
        printf "│   └── No network addresses\n"
    fi
    
    printf "└── $(print_cyan "Storage")\n"
    if [[ -n "$storage_info" ]]; then
        IFS=',' read -ra storage_array <<< "$storage_info"
        for ((i=0; i<${#storage_array[@]}; i++)); do
            IFS=':' read -r disk_name disk_size <<< "${storage_array[i]}"
            if [[ $i -eq $((${#storage_array[@]} - 1)) ]]; then
                printf "    └── /dev/%-4s %s\n" "${disk_name}" "${disk_size}"
            else
                printf "    ├── /dev/%-4s %s\n" "${disk_name}" "${disk_size}"
            fi
        done
    else
        printf "    └── N/A\n"
    fi
    echo
}

# Main execution
print_task "Gathering VM information..."
echo

for vm in "${target_vms[@]}"; do
    get_vm_info "$vm"
done
