readonly ETC_HOSTS_LOCK_DIR="/tux2lab-data/.etc-hosts.lock"
ETC_HOSTS_LOCK_ACQUIRED=false

fn_acquire_etc_hosts_lock() {
    local retries=200
    local existing_pid=""

    while ! mkdir "${ETC_HOSTS_LOCK_DIR}" 2>/dev/null; do
        if [[ -f "${ETC_HOSTS_LOCK_DIR}/pid" ]]; then
            existing_pid=$(cat "${ETC_HOSTS_LOCK_DIR}/pid" 2>/dev/null)
            if [[ -n "${existing_pid}" ]] && ! kill -0 "${existing_pid}" 2>/dev/null; then
                rm -f "${ETC_HOSTS_LOCK_DIR}/pid"
                rmdir "${ETC_HOSTS_LOCK_DIR}" 2>/dev/null || true
                continue
            fi
        fi

        sleep 0.05
        retries=$((retries - 1))
        if [[ "${retries}" -le 0 ]]; then
            print_error "Unable to acquire /etc/hosts lock. Please retry."
            return 1
        fi
    done

    printf '%s\n' "$$" > "${ETC_HOSTS_LOCK_DIR}/pid"
    ETC_HOSTS_LOCK_ACQUIRED=true
}

fn_release_etc_hosts_lock() {
    if ! $ETC_HOSTS_LOCK_ACQUIRED; then
        return
    fi

    local lock_pid=""
    if [[ -f "${ETC_HOSTS_LOCK_DIR}/pid" ]]; then
        lock_pid=$(cat "${ETC_HOSTS_LOCK_DIR}/pid" 2>/dev/null)
    fi

    if [[ "${lock_pid}" = "$$" ]]; then
        rm -f "${ETC_HOSTS_LOCK_DIR}/pid"
        rmdir "${ETC_HOSTS_LOCK_DIR}" 2>/dev/null || true
    fi

    ETC_HOSTS_LOCK_ACQUIRED=false
}

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

    # Acquire lock to prevent concurrent /etc/hosts modifications
    if ! fn_acquire_etc_hosts_lock; then
        print_task_fail
        return 1
    fi

    # Remove any existing entries for this hostname (escape dots for regex)
    local escaped_hostname="${hostname//./\\.}"
    if grep -q "${hostname}" "$hosts_file"; then
        if ! error_msg=$(sudo sed -i.bak "/[[:space:]]${escaped_hostname}$/d" "$hosts_file" 2>&1); then
            fn_release_etc_hosts_lock
            print_task_fail
            print_error "$error_msg"
            return 1
        fi
    fi

    # Add both IPv4 and IPv6 entries
    if ! error_msg=$(echo -e "${ipv4_address}\t${hostname}\n${ipv6_address}\t${hostname}" | sudo tee -a "$hosts_file" >/dev/null 2>&1); then
        fn_release_etc_hosts_lock
        print_task_fail
        print_error "Failed to add host entries for ${hostname} to ${hosts_file}."
        [[ -n "$error_msg" ]] && print_error "$error_msg"
        return 1
    fi

    fn_release_etc_hosts_lock
    print_task_done
    return 0
}
