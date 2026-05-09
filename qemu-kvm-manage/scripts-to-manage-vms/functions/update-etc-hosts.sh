update_etc_hosts() {
    local hostname="$1"
    local ipv4_address="$2"
    local ipv6_address="$3"
    local hosts_file="/etc/hosts"
    local error_msg=""

    if [[ -z "$hostname" || -z "$ipv4_address" || -z "$ipv6_address" ]]; then
        print_error "update_etc_hosts requires hostname, IPv4 address, and IPv6 address"
        return 1
    fi

    print_task "Updating ${hosts_file} file for ${hostname} (dual-stack)..."

    # Remove any existing entries for this hostname
    if grep -q "${hostname}" "$hosts_file"; then
        if ! error_msg=$(sudo sed -i.bak "/${hostname}/d" "$hosts_file" 2>&1); then
            print_task_fail
            print_error "$error_msg"
            return 1
        fi
    fi

    # Add both IPv4 and IPv6 entries
    if error_msg=$(echo -e "${ipv4_address}\t${hostname}\n${ipv6_address}\t${hostname}" | sudo tee -a "$hosts_file" >/dev/null 2>&1); then
        print_task_done
        return 0
    else
        print_task_fail
        print_error "$error_msg"
        return 1
    fi
}
