# Manages /etc/hosts entries for tux2lab using a state file and marker block.
# State file: /tux2lab-data/lab-config/etc-hosts.state
# All lab entries live between "# BEGIN tux2lab" / "# END tux2lab" markers.

[[ -z "${ETC_HOSTS_STATE:-}" ]] && readonly ETC_HOSTS_STATE="/tux2lab-data/lab-config/etc-hosts.state"
[[ -z "${ETC_HOSTS_MARKER_BEGIN:-}" ]] && readonly ETC_HOSTS_MARKER_BEGIN="# BEGIN tux2lab"
[[ -z "${ETC_HOSTS_MARKER_END:-}" ]] && readonly ETC_HOSTS_MARKER_END="# END tux2lab"

[[ -z "${ETC_HOSTS_LOCK_DIR:-}" ]] && readonly ETC_HOSTS_LOCK_DIR="/tux2lab-data/.etc-hosts.lock"
ETC_HOSTS_LOCK_ACQUIRED=false

_acquire_etc_hosts_lock() {
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
            return 1
        fi
    done

    printf '%s\n' "$$" > "${ETC_HOSTS_LOCK_DIR}/pid"
    ETC_HOSTS_LOCK_ACQUIRED=true
}

_release_etc_hosts_lock() {
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

# Replace the marker block in /etc/hosts with current state file content
sync_etc_hosts() {
    if ! _acquire_etc_hosts_lock; then
        print_error "Unable to acquire /etc/hosts lock."
        return 1
    fi

    # Remove existing marker block
    if grep -q "${ETC_HOSTS_MARKER_BEGIN}" /etc/hosts 2>/dev/null; then
        sudo sed -i "/${ETC_HOSTS_MARKER_BEGIN}/,/${ETC_HOSTS_MARKER_END}/d" /etc/hosts
    fi

    # Append state file content as marker block
    if [[ -s "${ETC_HOSTS_STATE}" ]]; then
        {
            echo "${ETC_HOSTS_MARKER_BEGIN}"
            cat "${ETC_HOSTS_STATE}"
            echo "${ETC_HOSTS_MARKER_END}"
        } | sudo tee -a /etc/hosts >/dev/null
    fi

    _release_etc_hosts_lock
}

# Add or update a host entry in state file, then sync
add_etc_hosts_entry() {
    local hostname="$1"
    local ipv4_address="$2"
    local ipv6_address="$3"

    if [[ -z "$hostname" || -z "$ipv4_address" || -z "$ipv6_address" ]]; then
        print_error "add_etc_hosts_entry requires hostname, IPv4, and IPv6."
        return 1
    fi

    touch "${ETC_HOSTS_STATE}"

    local escaped_hostname="${hostname//./\\.}"
    sed -i "/[[:space:]]${escaped_hostname}$/d" "${ETC_HOSTS_STATE}" 2>/dev/null || true

    printf '%s\t%s\n' "${ipv4_address}" "${hostname}" >> "${ETC_HOSTS_STATE}"
    printf '%s\t%s\n' "${ipv6_address}" "${hostname}" >> "${ETC_HOSTS_STATE}"

    sync_etc_hosts
}

# Remove a host entry from state file, then sync
remove_etc_hosts_entry() {
    local hostname="$1"

    if [[ ! -f "${ETC_HOSTS_STATE}" ]]; then
        return 0
    fi

    local escaped_hostname="${hostname//./\\.}"
    sed -i "/[[:space:]]${escaped_hostname}$/d" "${ETC_HOSTS_STATE}" 2>/dev/null || true

    sync_etc_hosts
}

# Remove the entire marker block from /etc/hosts (used by stop/destroy)
remove_etc_hosts_block() {
    if ! _acquire_etc_hosts_lock; then
        print_error "Unable to acquire /etc/hosts lock."
        return 1
    fi

    if grep -q "${ETC_HOSTS_MARKER_BEGIN}" /etc/hosts 2>/dev/null; then
        sudo sed -i "/${ETC_HOSTS_MARKER_BEGIN}/,/${ETC_HOSTS_MARKER_END}/d" /etc/hosts
    fi

    _release_etc_hosts_lock
}
