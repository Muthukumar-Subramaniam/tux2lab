#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#

source /etc/environment
if [[ -f /tux2lab-data/lab_environment_vars ]]; then
    source /tux2lab-data/lab_environment_vars
fi
# In host mode, mgmt_super_user may come from lab_environment_vars as lab_infra_admin_username
if [[ -z "${mgmt_super_user:-}" && -n "${lab_infra_admin_username:-}" ]]; then
    mgmt_super_user="${lab_infra_admin_username}"
fi
source /tux2lab/common-utils/color-functions.sh
source /tux2lab/ks-manage/distro-versions.conf

if [[ -z "$mgmt_super_user" ]]; then
    print_error "Critical: mgmt_super_user is not defined in /etc/environment."
    print_error "Please ensure the environment is properly configured."
    exit 1
fi

if [[ "$USER" != "$mgmt_super_user" ]]; then
    print_error "Access denied. Only infra management super user '${mgmt_super_user}' is authorized to run this tool."
    print_error "Also if the user itself is ${mgmt_super_user}, Please do not elevate access again with sudo.\n"
    exit 1
fi

if [[ -z "${dnsbinder_server_ipv4_address}" ]]; then
    print_error "Critical: dnsbinder_server_ipv4_address is not defined in /etc/environment."
    print_error "DNS server IP address is required for dig queries."
    exit 1
fi

ipv4_domain="${dnsbinder_domain}"
ipv4_network_cidr="${dnsbinder_network_cidr}"
ipv4_netmask="${dnsbinder_netmask}"
ipv4_prefix="${dnsbinder_cidr_prefix}"
ipv4_gateway="${dnsbinder_gateway}"
ipv4_nameserver="${dnsbinder_server_ipv4_address}"
ipv4_nfsserver="${dnsbinder_server_ipv4_address}"
lab_infra_server_hostname="${dnsbinder_server_fqdn}"

# IPv6 variables (if dual-stack configured)
ipv6_gateway="${dnsbinder_ipv6_gateway}"
ipv6_prefix="${dnsbinder_ipv6_prefix}"
ipv6_ula_subnet="${dnsbinder_ipv6_ula_subnet}"
ipv6_address=""  # Will be queried from DNS
ipv6_nameserver="${dnsbinder_server_ipv6_address}"
##rhel_activation_key=$(cat /tux2lab/rhel-activation-key.base64 | base64 -d)
time_of_last_update=$(date +"%Y-%m-%d_%H-%M-%S_%Z")
dnsbinder_script='/tux2lab/named-manage/dnsbinder.sh'
ksmanager_main_dir='/tux2lab/ks-manage'
ksmanager_hub_dir="/${lab_infra_server_hostname}/ksmanager-hub"
ipxe_web_dir="/${lab_infra_server_hostname}/ipxe"
shadow_password_super_mgmt_user=$(sudo awk -F: -v user="${mgmt_super_user}" '$1 == user {print $2}' /etc/shadow)
if [[ -d "/tux2lab-data" ]]; then
    if [[ -f "/tux2lab-data/lab_environment_vars" ]]; then
        source /tux2lab-data/lab_environment_vars
        shadow_password_super_mgmt_user=$lab_admin_shadow_password
    fi
fi
subnets_to_allow_ssh_pub_access=""
for i in $(seq ${dnsbinder_first24_subnet##*.} ${dnsbinder_last24_subnet##*.}); do
    subnets_to_allow_ssh_pub_access+=" ${dnsbinder_first24_subnet%.*}.$i.*"
done
subnets_to_allow_ssh_pub_access="${subnets_to_allow_ssh_pub_access# }"

mkdir -p "${ksmanager_hub_dir}"
mkdir -p "${ipxe_web_dir}"

mac_cache_file="${ksmanager_hub_dir}/mac-address-cache"
hosts_json_file="${ksmanager_hub_dir}/hosts.json"
mac_cache_lock_dir="${ksmanager_hub_dir}/.mac-address-cache.lock"
host_lock_root_dir="${ksmanager_hub_dir}/.host-locks"
shared_artifacts_lock_dir="${ksmanager_hub_dir}/.shared-artifacts.lock"
current_host_lock_dir=""
current_host_name=""
mac_lock_acquired=false
host_lock_acquired=false
shared_lock_acquired=false

mkdir -p "${host_lock_root_dir}"

fn_acquire_mac_cache_lock() {
    local retries=200
    local existing_pid=""

    while ! mkdir "${mac_cache_lock_dir}" 2>/dev/null; do
        if [[ -f "${mac_cache_lock_dir}/pid" ]]; then
            existing_pid=$(cat "${mac_cache_lock_dir}/pid" 2>/dev/null)
            if [[ -n "${existing_pid}" ]] && ! kill -0 "${existing_pid}" 2>/dev/null; then
                rm -f "${mac_cache_lock_dir}/pid"
                rmdir "${mac_cache_lock_dir}" 2>/dev/null || true
                continue
            fi
        fi

        sleep 0.05
        retries=$((retries - 1))
        if [[ "${retries}" -le 0 ]]; then
            print_error "Unable to acquire mac-address-cache lock. Please retry."
            return 1
        fi
    done

    printf '%s\n' "$$" > "${mac_cache_lock_dir}/pid"
    mac_lock_acquired=true
}

fn_release_mac_cache_lock() {
    local lock_pid=""

    if ! $mac_lock_acquired; then
        return
    fi

    if [[ -f "${mac_cache_lock_dir}/pid" ]]; then
        lock_pid=$(cat "${mac_cache_lock_dir}/pid" 2>/dev/null)
    fi

    if [[ "${lock_pid}" = "$$" ]]; then
        rm -f "${mac_cache_lock_dir}/pid"
        rmdir "${mac_cache_lock_dir}" 2>/dev/null || true
    fi

    mac_lock_acquired=false
}

fn_copy_mac_cache_snapshot_locked() {
    local snapshot_file="$1"
    local snapshot_ok=false

    if ! fn_acquire_mac_cache_lock; then
        return 1
    fi

    if [[ -f "${mac_cache_file}" ]]; then
        if cp "${mac_cache_file}" "${snapshot_file}"; then
            snapshot_ok=true
        fi
    else
        if : > "${snapshot_file}"; then
            snapshot_ok=true
        fi
    fi

    fn_release_mac_cache_lock

    if ! $snapshot_ok; then
        return 1
    fi
}

fn_acquire_host_lock() {
    local host_name="$1"
    local safe_host_name=""
    local retries=400
    local existing_pid=""

    safe_host_name=$(printf '%s' "${host_name}" | tr -c 'a-zA-Z0-9_.-' '_')
    current_host_lock_dir="${host_lock_root_dir}/${safe_host_name}.lock"
    current_host_name="${host_name}"

    while ! mkdir "${current_host_lock_dir}" 2>/dev/null; do
        if [[ -f "${current_host_lock_dir}/pid" ]]; then
            existing_pid=$(cat "${current_host_lock_dir}/pid" 2>/dev/null)
            if [[ -n "${existing_pid}" ]] && ! kill -0 "${existing_pid}" 2>/dev/null; then
                rm -f "${current_host_lock_dir}/pid"
                rmdir "${current_host_lock_dir}" 2>/dev/null || true
                continue
            fi
        fi

        sleep 0.05
        retries=$((retries - 1))
        if [[ "${retries}" -le 0 ]]; then
            print_error "Unable to acquire host lock for '${host_name}'. Please retry."
            current_host_lock_dir=""
            return 1
        fi
    done

    printf '%s\n' "$$" > "${current_host_lock_dir}/pid"
    host_lock_acquired=true
}

fn_release_host_lock() {
    local lock_pid=""

    if ! $host_lock_acquired; then
        return
    fi

    if [[ -f "${current_host_lock_dir}/pid" ]]; then
        lock_pid=$(cat "${current_host_lock_dir}/pid" 2>/dev/null)
    fi

    if [[ -n "${current_host_lock_dir}" ]] && [[ -d "${current_host_lock_dir}" ]] && [[ "${lock_pid}" = "$$" ]]; then
        rm -f "${current_host_lock_dir}/pid"
        rmdir "${current_host_lock_dir}" 2>/dev/null || true
    fi

    current_host_lock_dir=""
    current_host_name=""
    host_lock_acquired=false
}

fn_acquire_shared_artifacts_lock() {
    local retries=400
    local existing_pid=""

    while ! mkdir "${shared_artifacts_lock_dir}" 2>/dev/null; do
        if [[ -f "${shared_artifacts_lock_dir}/pid" ]]; then
            existing_pid=$(cat "${shared_artifacts_lock_dir}/pid" 2>/dev/null)
            if [[ -n "${existing_pid}" ]] && ! kill -0 "${existing_pid}" 2>/dev/null; then
                rm -f "${shared_artifacts_lock_dir}/pid"
                rmdir "${shared_artifacts_lock_dir}" 2>/dev/null || true
                continue
            fi
        fi

        sleep 0.05
        retries=$((retries - 1))
        if [[ "${retries}" -le 0 ]]; then
            print_error "Unable to acquire shared artifact lock. Please retry."
            return 1
        fi
    done

    printf '%s\n' "$$" > "${shared_artifacts_lock_dir}/pid"
    shared_lock_acquired=true
}

fn_release_shared_artifacts_lock() {
    local lock_pid=""

    if ! $shared_lock_acquired; then
        return
    fi

    if [[ -f "${shared_artifacts_lock_dir}/pid" ]]; then
        lock_pid=$(cat "${shared_artifacts_lock_dir}/pid" 2>/dev/null)
    fi

    if [[ -d "${shared_artifacts_lock_dir}" ]] && [[ "${lock_pid}" = "$$" ]]; then
        rm -f "${shared_artifacts_lock_dir}/pid"
        rmdir "${shared_artifacts_lock_dir}" 2>/dev/null || true
    fi

    shared_lock_acquired=false
}

fn_release_all_locks() {
    fn_release_mac_cache_lock
    fn_release_shared_artifacts_lock
    fn_release_host_lock
}

trap 'fn_release_all_locks' EXIT
trap 'fn_release_all_locks; trap - INT; kill -s INT $$' INT
trap 'fn_release_all_locks; trap - TERM; kill -s TERM $$' TERM
trap 'fn_release_all_locks; trap - HUP; kill -s HUP $$' HUP
trap 'fn_release_all_locks; trap - QUIT; kill -s QUIT $$' QUIT

fn_chown_if_exists() {
    local target_path="$1"
    if [[ -e "${target_path}" ]]; then
        chown -R "${mgmt_super_user}:${mgmt_super_user}" "${target_path}"
    fi
}

fn_wait_for_dns_a_record() {
    local hostname="$1"
    local max_retries=10
    local sleep_seconds=0.5
    local retry_count=0

    while [[ ${retry_count} -lt ${max_retries} ]]; do
        if dig @"${dnsbinder_server_ipv4_address}" +short +time=1 +tries=1 A "${hostname}" | grep -q '^[0-9]'; then
            return 0
        fi
        sleep "${sleep_seconds}"
        ((retry_count++))
    done

    return 1
}

fn_check_and_create_host_record() {
    while :
    do
        # shellcheck disable=SC2162
        if [[ -z "${1}" ]]
        then
            print_info "Create kickstart host profiles for PXE boot."
            print_info "Points to keep in mind while entering the hostname:"
            print_info "- Use only lowercase letters, numbers, and hyphens (-)."
            print_info "- Must not start or end with a hyphen."
            read -r -p "Please enter the hostname for which kickstarts are required: " kickstart_hostname
        else
            kickstart_hostname="${1}"
        fi

        # Validate and normalize hostname to FQDN
        if [[ "${kickstart_hostname}" == *.${ipv4_domain} ]]; then
            local stripped_hostname="${kickstart_hostname%.${ipv4_domain}}"
            # Verify the stripped part doesn't contain dots (ensure it's just hostname.domain, not host.something.domain)
            if [[ "${stripped_hostname}" == *.* ]]; then
                print_error "Invalid hostname. Expected format: hostname.${ipv4_domain}"
                exit 1
            fi
            # Validate the hostname part
            if [[ ! "${stripped_hostname}" =~ ^[a-z0-9-]+$ || "${stripped_hostname}" =~ ^- || "${stripped_hostname}" =~ -$ ]]; then
                print_error "Invalid hostname. Use only lowercase letters, numbers, and hyphens."
                print_info "Hostname must not start or end with a hyphen."
                exit 1
            fi
            # Keep as FQDN
        elif [[ "${kickstart_hostname}" == *.* ]]; then
            print_error "Invalid domain. Expected domain: ${ipv4_domain}"
            exit 1
        else
            # Bare hostname provided - validate and convert to FQDN
            if [[ ! "${kickstart_hostname}" =~ ^[a-z0-9-]+$ || "${kickstart_hostname}" =~ ^- || "${kickstart_hostname}" =~ -$ ]]; then
                print_error "Invalid hostname. Use only lowercase letters, numbers, and hyphens."
                print_info "Hostname must not start or end with a hyphen."
                exit 1
            fi
            kickstart_hostname="${kickstart_hostname}.${ipv4_domain}"
        fi

        break
    done

    # Extract short hostname for use with tools that need it
    kickstart_short_hostname="${kickstart_hostname%%.*}"

    if ! fn_wait_for_dns_a_record "${kickstart_hostname}"
    then
        print_info "No DNS record found for \"${kickstart_hostname}\"."
        
        if $invoked_with_qemu_kvm; then
            sudo "${dnsbinder_script}" -c "${kickstart_hostname}"

            if ! fn_wait_for_dns_a_record "${kickstart_hostname}"; then
                print_error "Failed to create DNS record for \"${kickstart_hostname}\"."
                exit 1
            fi
        else
            while :
            do
                read -r -p "Enter (y) to create a DNS record for \"${kickstart_hostname}\" or (n) to exit: " v_confirmation

                if [[ "${v_confirmation}" == "y" ]]
                then
                    sudo "${dnsbinder_script}" -c "${kickstart_hostname}"

                    if ! fn_wait_for_dns_a_record "${kickstart_hostname}"; then
                        print_error "Failed to create DNS record for \"${kickstart_hostname}\"."
                        exit 1
                    fi
                    break

                elif [[ "${v_confirmation}" == "n" ]]
                then
                    print_info "Operation cancelled by user."
                    exit
                else
                    print_warning "Invalid input. Please enter 'y' or 'n'."
                    continue
                fi
            done
        fi
    else
        print_info "DNS record found for \"${kickstart_hostname}\"."
        local ipv4=$(dig @"${dnsbinder_server_ipv4_address}" +short A "${kickstart_hostname}" | head -1)
        local ipv6=$(dig @"${dnsbinder_server_ipv4_address}" +short AAAA "${kickstart_hostname}" | head -1)
        [[ -n "${ipv4}" ]] && print_info "${kickstart_hostname} has address ${ipv4}"
        [[ -n "${ipv6}" ]] && print_info "${kickstart_hostname} has IPv6 address ${ipv6}"
    fi
}

fn_remove_hosts_json_entry() {
    local remove_hostname="$1"
    local temp_hosts_json="${hosts_json_file}.tmp.$$"

    if [[ -f "$hosts_json_file" ]]; then
        jq --arg hostname "$remove_hostname" \
            '[.[] | select(.hostname != $hostname)]' \
            "$hosts_json_file" > "$temp_hosts_json" && \
            mv "$temp_hosts_json" "$hosts_json_file"
        rm -f "$temp_hosts_json"
    fi
}

golden_image_creation_not_requested=true

for input_arguement in "$@"; do
    if [[ "$input_arguement" == "--create-golden-image" ]]; then
    golden_image_creation_not_requested=false
        break
    fi
done

# Check for --remove-host flag
remove_host_requested=false
for input_arguement in "$@"; do
    if [[ "$input_arguement" == "--remove-host" ]]; then
        remove_host_requested=true
        break
    fi
done

# If --remove-host is requested, handle cleanup and exit
if $remove_host_requested; then
    if [[ -z "${1}" ]] || [[ "${1}" == "--remove-host" ]]; then
        print_error "Hostname is required with --remove-host flag."
        print_info "Usage: sudo ksmanager hostname --remove-host"
        exit 1
    fi
    
    # Extract hostname from arguments (skip --remove-host)
    for arg in "$@"; do
        if [[ "$arg" != "--remove-host" ]]; then
            cleanup_hostname="$arg"
            break
        fi
    done
    
    # Validate and normalize hostname to FQDN
    if [[ "${cleanup_hostname}" == *.${ipv4_domain} ]]; then
        stripped_hostname="${cleanup_hostname%.${ipv4_domain}}"
        if [[ "${stripped_hostname}" == *.* ]]; then
            print_error "Invalid hostname. Expected format: hostname.${ipv4_domain}"
            exit 1
        fi
        if [[ ! "${stripped_hostname}" =~ ^[a-z0-9-]+$ || "${stripped_hostname}" =~ ^- || "${stripped_hostname}" =~ -$ ]]; then
            print_error "Invalid hostname. Use only lowercase letters, numbers, and hyphens."
            exit 1
        fi
    elif [[ "${cleanup_hostname}" == *.* ]]; then
        print_error "Invalid domain. Expected domain: ${ipv4_domain}"
        exit 1
    else
        if [[ ! "${cleanup_hostname}" =~ ^[a-z0-9-]+$ || "${cleanup_hostname}" =~ ^- || "${cleanup_hostname}" =~ -$ ]]; then
            print_error "Invalid hostname. Use only lowercase letters, numbers, and hyphens."
            exit 1
        fi
        cleanup_hostname="${cleanup_hostname}.${ipv4_domain}"
    fi
    
    print_info "Removing host '${cleanup_hostname}' from all ksmanager databases..."
    
    if ! fn_acquire_host_lock "${cleanup_hostname}"; then
        exit 1
    fi

    # 1. Snapshot and remove cache row atomically under lock
    if [[ -f "${mac_cache_file}" ]]; then
        if ! fn_acquire_mac_cache_lock; then
            fn_release_host_lock
            exit 1
        fi

        cached_info=$(awk -v host="${cleanup_hostname}" '$1 == host {print $2" "$3" "$4; exit}' "${mac_cache_file}" 2>/dev/null)
        read -r cached_mac cached_ip cached_ipv6 <<< "$cached_info"

        if [[ -n "$cached_mac" ]]; then
            ipxe_cfg_mac="${cached_mac//:/-}"
            ipxe_cfg_mac=$(printf '%s' "${ipxe_cfg_mac}" | tr '[:upper:]' '[:lower:]')
            awk -v host="${cleanup_hostname}" '$1 != host' "${mac_cache_file}" > "${mac_cache_file}.tmp.$$" && \
                mv "${mac_cache_file}.tmp.$$" "${mac_cache_file}"
            rm -f "${mac_cache_file}.tmp.$$"
            print_info "Removed from MAC address cache"
        else
            print_info "No MAC address cache entry found"
        fi

        fn_remove_hosts_json_entry "${cleanup_hostname}"

        fn_release_mac_cache_lock
    else
        print_info "No MAC address cache entry found"
    fi
    
    # 2. Remove kickstart directory
    if [[ -d "${ksmanager_hub_dir}/kickstarts/${cleanup_hostname}" ]]; then
        rm -rf "${ksmanager_hub_dir}/kickstarts/${cleanup_hostname}"
        print_info "Removed kickstart files"
    else
        print_info "No kickstart files found"
    fi
    
    # 3. Remove iPXE config file
    if [[ -n "$ipxe_cfg_mac" ]]; then
        if [[ -f "${ipxe_web_dir}/${ipxe_cfg_mac}.ipxe" ]]; then
            rm -f "${ipxe_web_dir}/${ipxe_cfg_mac}.ipxe"
            print_info "Removed iPXE config file (${ipxe_cfg_mac}.ipxe)"
        else
            print_info "No iPXE config file found"
        fi
    else
        print_info "No iPXE config (no MAC address found)"
    fi
    
    # 4. Remove golden boot network config
    if [[ -n "$ipxe_cfg_mac" ]]; then
        if [[ -f "${ksmanager_hub_dir}/golden-boot-mac-configs/network-config-${ipxe_cfg_mac}" ]]; then
            rm -f "${ksmanager_hub_dir}/golden-boot-mac-configs/network-config-${ipxe_cfg_mac}"
            print_info "Removed golden boot network config"
        else
            print_info "No golden boot network config found"
        fi
    else
        print_info "No golden boot config (no MAC address found)"
    fi
    
    # 5. Remove KEA DHCP reservation
    if systemctl is-active --quiet kea-ctrl-agent && [[ -n "$cached_mac" ]]; then
        kea_api_url="http://127.0.0.1:8000/"
        kea_api_auth="kea-api:kea-api-password"
        
        # Delete DHCPv4 lease by MAC address
        curl -s -X POST -H "Content-Type: application/json" \
            -u "$kea_api_auth" \
            -d "{
                  \"command\": \"lease4-del\",
                  \"service\": [ \"dhcp4\" ],
                  \"arguments\": {
                    \"identifier-type\": \"hw-address\",
                    \"identifier\": \"${cached_mac}\",
                    \"subnet-id\": 1
                  }
                }" \
            "$kea_api_url" &>/dev/null
        
        # Delete DHCPv4 lease by IP address
        if [[ -n "$cached_ip" ]]; then
            curl -s -X POST -H "Content-Type: application/json" \
                -u "$kea_api_auth" \
                -d "{
                      \"command\": \"lease4-del\",
                      \"service\": [ \"dhcp4\" ],
                      \"arguments\": {
                        \"ip-address\": \"${cached_ip}\",
                        \"subnet-id\": 1
                      }
                    }" \
                "$kea_api_url" &>/dev/null
        fi
        
        # Delete DHCPv6 lease by MAC address
        curl -s -X POST -H "Content-Type: application/json" \
            -u "$kea_api_auth" \
            -d "{
                  \"command\": \"lease6-del\",
                  \"service\": [ \"dhcp6\" ],
                  \"arguments\": {
                    \"identifier-type\": \"hw-address\",
                    \"identifier\": \"${cached_mac}\",
                    \"subnet-id\": 1
                  }
                }" \
            "$kea_api_url" &>/dev/null
        
        # Delete DHCPv6 lease by IP address (if IPv6 exists in cache)
        if [[ -n "$cached_ipv6" ]]; then
            curl -s -X POST -H "Content-Type: application/json" \
                -u "$kea_api_auth" \
                -d "{
                      \"command\": \"lease6-del\",
                      \"service\": [ \"dhcp6\" ],
                      \"arguments\": {
                        \"ip-address\": \"${cached_ipv6}\",
                        \"subnet-id\": 1
                      }
                    }" \
                "$kea_api_url" &>/dev/null
        fi
        
        # Rebuild KEA DHCPv4 config without this host
        kea_cache_file="${ksmanager_hub_dir}/mac-address-cache"
        kea_dhcp4_config_file="/etc/kea/kea-dhcp4.conf"
        kea_dhcp6_config_file="/etc/kea/kea-dhcp6.conf"
        kea_temp_config_timestamp=$(date +"%Y%m%d_%H%M%S_%Z")
        kea_config_temp_dir="${ksmanager_hub_dir}/kea_dhcp_temp_configs_with_reservation"
        kea_dhcp4_tmp_config="${kea_config_temp_dir}/kea-dhcp4.conf_${kea_temp_config_timestamp}"
        kea_dhcp6_tmp_config="${kea_config_temp_dir}/kea-dhcp6.conf_${kea_temp_config_timestamp}"
        kea_cache_snapshot="${kea_config_temp_dir}/mac-address-cache.snapshot.$$"
        
        mkdir -p "$kea_config_temp_dir"

        if ! fn_copy_mac_cache_snapshot_locked "${kea_cache_snapshot}"; then
            print_error "Could not snapshot MAC cache for KEA rebuild. Aborting KEA reservation refresh."
            fn_release_host_lock
            exit 1
        fi
        
        # Rebuild DHCPv4 reservations
        if ! kea_dhcp4_existing_config=$(sudo cat "$kea_dhcp4_config_file"); then
            print_error "Failed to read KEA DHCPv4 config: ${kea_dhcp4_config_file}"
            fn_release_host_lock
            exit 1
        fi
        
        kea_dhcp4_reservations_json=""
        while read -r kea_hostname kea_hw_address kea_ip_address kea_ipv6_address; do
            kea_dhcp4_reservations_json+="{
              \"hostname\": \"$kea_hostname\",
              \"hw-address\": \"$kea_hw_address\",
              \"ip-address\": \"$kea_ip_address\"
            },"
        done < "$kea_cache_snapshot"
        
        kea_dhcp4_reservations_json="[${kea_dhcp4_reservations_json%,}]"
        
        kea_dhcp4_new_config=$(echo "$kea_dhcp4_existing_config" | \
            jq --argjson reservations "$kea_dhcp4_reservations_json" \
              '.Dhcp4.subnet4[0].reservations = $reservations')
        
        cat > "$kea_dhcp4_tmp_config" <<EOF
{
  "command": "config-set",
  "service": [ "dhcp4" ],
  "arguments": $kea_dhcp4_new_config
}
EOF
        
        # Rebuild DHCPv6 reservations
        if ! kea_dhcp6_existing_config=$(sudo cat "$kea_dhcp6_config_file"); then
            print_error "Failed to read KEA DHCPv6 config: ${kea_dhcp6_config_file}"
            fn_release_host_lock
            exit 1
        fi
        
        kea_dhcp6_reservations_json=""
        while read -r kea_hostname kea_hw_address kea_ip_address kea_ipv6_address; do
            if [[ -n "$kea_ipv6_address" ]]; then
                kea_dhcp6_reservations_json+="{
                  \"hostname\": \"$kea_hostname\",
                  \"hw-address\": \"$kea_hw_address\",
                  \"ip-addresses\": [ \"${kea_ipv6_address}\" ]
                },"
            fi
        done < "$kea_cache_snapshot"
        
        kea_dhcp6_reservations_json="[${kea_dhcp6_reservations_json%,}]"
        
        kea_dhcp6_new_config=$(echo "$kea_dhcp6_existing_config" | \
            jq --argjson reservations "$kea_dhcp6_reservations_json" \
              '.Dhcp6.subnet6[0].reservations = $reservations')
        
        cat > "$kea_dhcp6_tmp_config" <<EOF
{
  "command": "config-set",
  "service": [ "dhcp6" ],
  "arguments": $kea_dhcp6_new_config
}
EOF
        
        # Push DHCPv4 config
        if ! curl -s -X POST -H "Content-Type: application/json" \
            -u "$kea_api_auth" \
            -d @"$kea_dhcp4_tmp_config" \
            "$kea_api_url" &>/dev/null; then
            print_error "Failed to push KEA DHCPv4 config update"
            rm -f "${kea_cache_snapshot}"
            fn_release_host_lock
            exit 1
        fi
        
        # Push DHCPv6 config
        if ! curl -s -X POST -H "Content-Type: application/json" \
            -u "$kea_api_auth" \
            -d @"$kea_dhcp6_tmp_config" \
            "$kea_api_url" &>/dev/null; then
            print_error "Failed to push KEA DHCPv6 config update"
            rm -f "${kea_cache_snapshot}"
            fn_release_host_lock
            exit 1
        fi

        rm -f "${kea_cache_snapshot}"
        
        print_info "Removed KEA DHCP reservations (IPv4 and IPv6)"
    fi
    
    # 6. Remove DNS record
    if dig @"${dnsbinder_server_ipv4_address}" +short +time=1 +tries=1 A "${cleanup_hostname}" | grep -q '^[0-9]'; then
        sudo "${dnsbinder_script}" -dy "${cleanup_hostname}"
        
        # Verify deletion with retry mechanism (max 1 second)
        retry_count=0
        max_retries=2
        record_deleted=false
        
        while [[ ${retry_count} -lt ${max_retries} ]]; do
            if ! dig @"${dnsbinder_server_ipv4_address}" +short +time=1 +tries=1 A "${cleanup_hostname}" | grep -q '^[0-9]'; then
                record_deleted=true
                break
            fi
            sleep 0.5
            ((retry_count++))
        done
        
        if ${record_deleted}; then
            print_info "Removed DNS record"
        else
            print_warning "DNS record may not have been removed properly"
        fi
    else
        print_info "No DNS record found"
    fi
    
    fn_release_host_lock
    print_success "Host '${cleanup_hostname}' has been removed from all ksmanager databases."
    exit 0
fi

if $golden_image_creation_not_requested; then
    fn_check_and_create_host_record "${1}"
    ipv4_address=$(dig @"${dnsbinder_server_ipv4_address}" +short +time=1 +tries=1 A "${kickstart_hostname}" 2>/dev/null | awk 'NR==1 {gsub(/[[:space:]]/, ""); print}' || true)
    
    # Query DNS for IPv6 address (if dual-stack configured)
    if [[ -n "${ipv6_gateway}" ]]; then
        ipv6_address=$(dig @"${dnsbinder_server_ipv4_address}" +short +time=1 +tries=1 AAAA "${kickstart_hostname}" 2>/dev/null | awk 'NR==1 {gsub(/[[:space:]]/, ""); print}' || true)
    fi
fi

# Function to validate MAC address
fn_validate_mac() {
    local mac_address_of_host="${1}"
    
    # Regex for MAC address (allowing both colon and hyphen-separated)
    if [[ "${mac_address_of_host}" =~ ^([a-fA-F0-9]{2}([-:]?)){5}[a-fA-F0-9]{2}$ ]]
    then
        return 0  # Valid MAC address
    else
        return 1  # Invalid MAC address
    fi
}

fn_convert_mac_for_ipxe_cfg() {
    # Convert MAC address to required format to append with ipxe.cfg file
    ipxe_cfg_mac_address="${mac_address_of_host//:/-}"
    ipxe_cfg_mac_address=$(printf '%s' "${ipxe_cfg_mac_address}" | tr '[:upper:]' '[:lower:]')
}

fn_cache_the_mac() {
    print_task "Caching MAC address..."
    local temp_cache_file="${mac_cache_file}.tmp.$$"

    if ! fn_acquire_mac_cache_lock; then
        print_task_fail
        exit 1
    fi

    touch "${mac_cache_file}"
    if awk -v host="${kickstart_hostname}" '$1 != host' "${mac_cache_file}" > "${temp_cache_file}" && \
       printf '%s %s %s %s\n' "${kickstart_hostname}" "${mac_address_of_host}" "${ipv4_address}" "${ipv6_address}" >> "${temp_cache_file}" && \
       mv "${temp_cache_file}" "${mac_cache_file}"; then
        fn_release_mac_cache_lock
        print_task_done
    else
        rm -f "${temp_cache_file}"
        fn_release_mac_cache_lock
        print_task_fail
        print_error "Failed to cache MAC address."
        exit 1
    fi
}

# Loop until a valid MAC address is provided

fn_get_mac_address() {
    while :
    do
        echo -n "Enter the MAC address of the VM \"${kickstart_hostname}\": "
        read mac_address_of_host
            # Call the function to validate the MAC address
            if fn_validate_mac "${mac_address_of_host}"
            then
                break
            else
            print_error "Invalid MAC address provided. Please try again."
            fi
    done
}

invoked_with_qemu_kvm=false
for input_arguement in "$@"; do
    if [[ "$input_arguement" == "--qemu-kvm" ]]; then
        invoked_with_qemu_kvm=true
        break
    fi
done

invoked_with_golden_image=false
for input_arguement in "$@"; do
    if [[ "$input_arguement" == "--golden-image" ]]; then
        invoked_with_golden_image=true
        break
    fi
done

# Parse --distro, --version, and --mac flags
distro_from_flag=""
version_from_flag=""
mac_from_flag=""
prev_arg=""
for arg in "$@"; do
    if [[ "$prev_arg" == "--distro" ]]; then
        distro_from_flag="$arg"
    fi
    if [[ "$prev_arg" == "--version" ]]; then
        version_from_flag="$arg"
    fi
    if [[ "$prev_arg" == "--mac" ]]; then
        mac_from_flag="$arg"
    fi
    prev_arg="$arg"
done

# Version will be set after distro selection (from flag or interactive menu)
version="${version_from_flag}"

fn_check_and_create_mac_if_required() {

# If MAC address was provided via --mac flag, use it directly
if [[ -n "${mac_from_flag}" ]]; then
    print_info "Using MAC address provided via --mac flag: ${mac_from_flag}"
    mac_address_of_host="${mac_from_flag}"
    # Validate the provided MAC address
    if ! fn_validate_mac "${mac_address_of_host}"; then
        print_error "Invalid MAC address provided via --mac flag: ${mac_address_of_host}"
        exit 1
    fi
    fn_convert_mac_for_ipxe_cfg
    fn_cache_the_mac
    return
fi

print_info "Looking up MAC address for host \"${kickstart_hostname}\" from cache..."

if [[ ! -f "${mac_cache_file}" ]]; then
    touch  "${mac_cache_file}"
fi

if awk -v host="${kickstart_hostname}" '$1 == host {found=1} END{exit !found}' "${mac_cache_file}"
then
    mac_address_of_host=$(awk -v host="${kickstart_hostname}" '$1 == host {print $2; exit}' "${mac_cache_file}")

    print_info "MAC Address ${mac_address_of_host} found for ${kickstart_hostname} in cache."
    while :
    do
        if $invoked_with_qemu_kvm; then
            fn_convert_mac_for_ipxe_cfg
            break
        fi
        
        read -p "Has the MAC Address ${mac_address_of_host} been changed for ${kickstart_hostname} (y/N)? : " confirmation 

        if [[ "${confirmation}" =~ ^[Nn]$ ]] 
        then
            fn_convert_mac_for_ipxe_cfg
            break

        elif [[ -z "${confirmation}" ]]
        then
            fn_convert_mac_for_ipxe_cfg
            break

        elif [[ "${confirmation}" =~ ^[Yy]$ ]]
        then
            fn_get_mac_address
            fn_convert_mac_for_ipxe_cfg
            fn_cache_the_mac
            break
        else
            print_warning "Invalid input."
        fi
    done
else
    print_info "MAC address for \"${kickstart_hostname}\" not found in cache."
    if $invoked_with_qemu_kvm; then
        print_error "MAC address not found in cache and --mac flag not provided for QEMU/KVM mode."
        print_error "QEMU/KVM scripts must provide MAC address via --mac flag."
        exit 1
    else
        fn_get_mac_address
        fn_convert_mac_for_ipxe_cfg
        fn_cache_the_mac
    fi
fi
}

if $golden_image_creation_not_requested; then
    fn_check_and_create_mac_if_required
fi

fn_check_distro_availability() {
    local os_distribution="${1}"
    local version="${2}"
    local mount_dir="/${lab_infra_server_hostname}/${os_distribution}/${version}"
    
    if mountpoint -q "${mount_dir}"; then
        print_green '[Ready]'
    else
        print_yellow '[not-yet-setup]'
    fi
}

# Status will be computed dynamically in menu based on selected version

fn_select_os_distro() {
    # Check if --distro flag was provided
    if [[ -n "${distro_from_flag}" ]]; then
        case "${distro_from_flag}" in
            alma|almalinux) 
                os_distribution="almalinux"
                print_info "OS distribution selected via --distro flag: ${os_distribution}"
                ;;
            rocky) 
                os_distribution="rocky"
                print_info "OS distribution selected via --distro flag: ${os_distribution}"
                ;;
            oracle|oraclelinux) 
                os_distribution="oraclelinux"
                print_info "OS distribution selected via --distro flag: ${os_distribution}"
                ;;
            centos|centos-stream) 
                os_distribution="centos-stream"
                print_info "OS distribution selected via --distro flag: ${os_distribution}"
                ;;
            rhel|redhat) 
                os_distribution="rhel"
                print_info "OS distribution selected via --distro flag: ${os_distribution}"
                ;;
            ubuntu-lts|ubuntu) 
                os_distribution="ubuntu-lts"
                print_info "OS distribution selected via --distro flag: ${os_distribution}"
                ;;
            opensuse-leap|opensuse|suse) 
                os_distribution="opensuse-leap"
                print_info "OS distribution selected via --distro flag: ${os_distribution}"
                ;;
            *)
                print_error "Invalid distro specified with --distro flag: ${distro_from_flag}"
                print_info "Valid options: almalinux, rocky, oraclelinux, centos-stream, rhel, ubuntu-lts, opensuse-leap"
                exit 1
                ;;
        esac
    fi
    
    while true; do
    # If distro not set via flag, show interactive distro selection menu
    if [[ -z "${os_distribution}" ]]; then
        local menu="Please select the OS distribution to install:\n"
        for i in "${!DISTRO_KEYS[@]}"; do
            local key="${DISTRO_KEYS[$i]}"
            local name="${DISTRO_DISPLAY_NAMES[$key]}"
            local versions="${DISTRO_AVAILABLE_VERSIONS[$key]}"
            printf -v line "  %d)  %-32s (versions: %s)\n" $((i+1)) "${name}" "${versions}"
            menu+="${line}"
        done
        menu+="  q)  Quit"
        
        print_notify "$menu"
        echo -n "Enter option number: "
        read distro_choice

        if [[ "${distro_choice}" == "q" || "${distro_choice}" == "Q" ]]; then
            print_info "Operation cancelled by user."; exit 130
        elif [[ "${distro_choice}" =~ ^[0-9]+$ ]] && (( distro_choice >= 1 && distro_choice <= ${#DISTRO_KEYS[@]} )); then
            os_distribution="${DISTRO_KEYS[$((distro_choice-1))]}"
        else
            print_error "Invalid option. Please try again."; continue
        fi
    fi

    # Select version (if not set via --version flag)
    if [[ -z "${version}" ]]; then
        local available_versions=(${DISTRO_AVAILABLE_VERSIONS[$os_distribution]})
        
        local menu="Please select the version for ${DISTRO_DISPLAY_NAMES[$os_distribution]}:\n"
        for i in "${!available_versions[@]}"; do
            local ver="${available_versions[$i]}"
            local status=$(fn_check_distro_availability "$os_distribution" "$ver")
            printf -v line "  %d)  %-12s %s\n" $((i+1)) "${ver}" "${status}"
            menu+="${line}"
        done
        menu+="  q)  Quit"
        
        print_notify "$menu"
        echo -n "Enter option number: "
        read version_choice

        if [[ "${version_choice}" == "q" || "${version_choice}" == "Q" ]]; then
            print_info "Operation cancelled by user."; exit 130
        elif [[ "${version_choice}" =~ ^[0-9]+$ ]] && (( version_choice >= 1 && version_choice <= ${#available_versions[@]} )); then
            version="${available_versions[$((version_choice-1))]}"
        else
            print_error "Invalid option. Please try again."
            version=""
            os_distribution=""
            continue
        fi
    else
        # Validate the version from --version flag
        if ! fn_is_valid_version "$os_distribution" "$version"; then
            print_error "Invalid version '${version}' for ${os_distribution}."
            print_info "Available versions: ${DISTRO_AVAILABLE_VERSIONS[$os_distribution]}"
            exit 1
        fi
    fi
    
    break
    done

    print_info "OS distribution selected: ${os_distribution} ${version}"
}
fn_select_os_distro

# Initialize variables for QEMU/KVM
disk_type_for_the_vm="vda"

fn_create_host_kickstart_dir() {
    host_kickstart_dir="${ksmanager_hub_dir}/kickstarts/${kickstart_hostname}"
    mkdir -p "${host_kickstart_dir}"
    rm -rf "${host_kickstart_dir}"/*
}

if $golden_image_creation_not_requested; then
    :
fi

mount_dir="/${lab_infra_server_hostname}/${os_distribution}/${version}"

while ! mountpoint -q "${mount_dir}"; do
    print_warning "${os_distribution} is not yet prepared for PXE-boot environment."
    print_info "Please use 'prepare-distro-for-ksmanager' tool to prepare ${os_distribution} for PXE-boot."
    if $invoked_with_qemu_kvm; then
        print_error "Cannot proceed with unprepared OS distribution in automation mode."
        exit 1
    fi
    fn_select_os_distro
done

if [[ "${os_distribution}" == "ubuntu-lts" ]]; then
    os_name_and_version=$(awk -F'LTS' '{print $1 "LTS"}' "/${lab_infra_server_hostname}/${os_distribution}/${version}/.disk/info")
elif [[ "${os_distribution}" == "opensuse-leap" ]]; then
    os_name_and_version=$(awk -F ' = ' '/^\[release\]/{f=1; next} /^\[/{f=0} f && /^(name|version)/ {gsub(/^[ \t]+/, "", $2); printf "%s ", $2} END{print ""}' "/${lab_infra_server_hostname}/${os_distribution}/${version}/.treeinfo")
    # Extract just the version number (e.g., "15.6" from "openSUSE Leap 15.6")
    opensuse_version_number=$(printf '%s\n' "$os_name_and_version" | grep -oP '[0-9]+\.[0-9]+' | head -n 1 || true)
else
    redhat_based_distro_name="${os_distribution}"
    if [[ "${os_distribution}" == "centos-stream" ]]; then
        os_name_and_version=$(grep -i "centos" "/${lab_infra_server_hostname}/${os_distribution}/${version}/.discinfo" || true)
    elif [[ "${os_distribution}" == "oraclelinux" ]]; then
        os_name_and_version=$(grep -i "oracle" "/${lab_infra_server_hostname}/${os_distribution}/${version}/.discinfo" || true)
    elif [[ "${os_distribution}" == "rhel" ]]; then
        os_name_and_version=$(grep -i "Red Hat" "/${lab_infra_server_hostname}/${os_distribution}/${version}/.discinfo" || true)
    else
        os_name_and_version=$(grep -i "${os_distribution}" "/${lab_infra_server_hostname}/${os_distribution}/${version}/.discinfo" || true)
    fi
fi

if ! $golden_image_creation_not_requested; then
    fn_check_and_create_host_record "${os_distribution}-${version//\./-}-golden-image"
    ipv4_address=$(dig @"${dnsbinder_server_ipv4_address}" +short +time=1 +tries=1 A "${kickstart_hostname}" 2>/dev/null | awk 'NR==1 {gsub(/[[:space:]]/, ""); print}' || true)
    
    # Query DNS for IPv6 address (if dual-stack configured)
    if [[ -n "${ipv6_gateway}" ]]; then
        ipv6_address=$(dig @"${dnsbinder_server_ipv4_address}" +short +time=1 +tries=1 AAAA "${kickstart_hostname}" 2>/dev/null | awk 'NR==1 {gsub(/[[:space:]]/, ""); print}' || true)
    fi
    
    fn_check_and_create_mac_if_required
fi

if ! fn_acquire_host_lock "${kickstart_hostname}"; then
    exit 1
fi

if ! $golden_image_creation_not_requested || ! $invoked_with_golden_image; then
    fn_create_host_kickstart_dir
fi

if ! $invoked_with_golden_image; then
    if [[ "${os_distribution}" == "opensuse-leap" ]]; then
        if ! rsync -a -q "${ksmanager_main_dir}/ks-templates/${os_distribution}-${version}-autoinst.xml" "${host_kickstart_dir}/${os_distribution}-${version}-autoinst.xml"; then
            print_error "Failed to copy kickstart template for ${os_distribution}-${version}"
            fn_release_host_lock
            exit 1
        fi
    elif [[ "${os_distribution}" == "ubuntu-lts" ]]; then 
        if ! rsync -a -q --delete "${ksmanager_main_dir}/ks-templates/${os_distribution}-${version}-ks" "${host_kickstart_dir}"/; then
            print_error "Failed to copy kickstart template for ${os_distribution}-${version}"
            fn_release_host_lock
            exit 1
        fi
    else
        if ! rsync -a -q "${ksmanager_main_dir}/ks-templates/redhat-based-${version}-ks.cfg" "${host_kickstart_dir}"/; then
            print_error "Failed to copy kickstart template for redhat-based-${version}"
            fn_release_host_lock
            exit 1
        fi
    fi
    if ! $golden_image_creation_not_requested; then
        if ! rsync -a -q "${ksmanager_main_dir}/golden-boot-templates/golden-boot.service" "${host_kickstart_dir}"/ || \
           ! rsync -a -q "${ksmanager_main_dir}/golden-boot-templates/golden-boot.sh" "${host_kickstart_dir}"/; then
            print_error "Failed to copy golden-boot templates"
            fn_release_host_lock
            exit 1
        fi
    fi
fi

if ! $invoked_with_golden_image; then

    print_task "Generating kickstart profile and iPXE configs..."
    if ! fn_acquire_shared_artifacts_lock; then
        fn_release_host_lock
        exit 1
    fi

    if rsync -a -q --delete "${ksmanager_main_dir}"/addons-for-kickstarts/ "${ksmanager_hub_dir}"/addons-for-kickstarts/ && \
        rsync -a -q /home/${mgmt_super_user}/.ssh/{authorized_keys,tux2lab_id_rsa.pub,tux2lab_id_rsa} "${ksmanager_hub_dir}"/addons-for-kickstarts/ && \
        chmod +r "${ksmanager_hub_dir}"/addons-for-kickstarts/{authorized_keys,tux2lab_id_rsa.pub,tux2lab_id_rsa} && \
        mkdir -p "${ksmanager_hub_dir}"/addons-for-kickstarts/ca-certs && \
        if [[ -f /etc/pki/tls/certs/${lab_infra_server_hostname}-nginx-selfsigned.crt ]]; then
            cp -f /etc/pki/tls/certs/${lab_infra_server_hostname}-nginx-selfsigned.crt "${ksmanager_hub_dir}"/addons-for-kickstarts/ca-certs/
        fi && \
        mkdir -p "${ksmanager_hub_dir}"/golden-boot-mac-configs; then
        print_task_done
    else
        fn_release_shared_artifacts_lock
        print_task_fail
        print_error "Failed to generate kickstart profile."
        fn_release_host_lock
        exit 1
    fi
fi

if $invoked_with_golden_image; then

    print_task "Generating golden boot network config..."
    if ! fn_acquire_shared_artifacts_lock; then
        fn_release_host_lock
        exit 1
    fi

    if rsync -a -q "${ksmanager_main_dir}"/golden-boot-templates/network-config-for-mac-address "${ksmanager_hub_dir}"/golden-boot-mac-configs/network-config-"${ipxe_cfg_mac_address}"; then
        print_task_done
    else
        fn_release_shared_artifacts_lock
        print_task_fail
        print_error "Failed to generate network config."
        fn_release_host_lock
        exit 1
    fi
fi

fn_set_environment() {
    local input_dir_or_file="${1}"
    local working_file=

    fn_replace_token_in_file() {
        local target_file="$1"
        local token="$2"
        local replacement="$3"
        local tmp_file="${target_file}.tmp_replace.$$"

        # Use awk-based replacement to avoid sed delimiter/escaping pitfalls
        # with runtime values such as CIDR blocks (e.g., 10.28.28.0/22).
        if awk -v token="${token}" -v replacement="${replacement}" '
            BEGIN {
                gsub(/\\/, "\\\\", replacement)
                gsub(/&/, "\\&", replacement)
            }
            {
                gsub(token, replacement)
                print
            }
        ' "${target_file}" > "${tmp_file}"; then
            mv "${tmp_file}" "${target_file}"
        else
            rm -f "${tmp_file}"
            return 1
        fi
    }

    fn_update_dynamic_parameters() {

        local working_file="${1}"

        fn_replace_token_in_file "${working_file}" "get_ipv4_network_cidr" "${ipv4_network_cidr}"
        fn_replace_token_in_file "${working_file}" "get_ipv4_address" "${ipv4_address}"
        fn_replace_token_in_file "${working_file}" "get_ipv4_netmask" "${ipv4_netmask}"
        fn_replace_token_in_file "${working_file}" "get_ipv4_prefix" "${ipv4_prefix}"
        fn_replace_token_in_file "${working_file}" "get_ipv4_gateway" "${ipv4_gateway}"
        fn_replace_token_in_file "${working_file}" "get_ipv4_nameserver" "${ipv4_nameserver}"
        fn_replace_token_in_file "${working_file}" "get_ipv4_nfsserver" "${ipv4_nfsserver}"
        fn_replace_token_in_file "${working_file}" "get_ipv4_domain" "${ipv4_domain}"
        
        # IPv6 replacements (if configured)
        if [[ -n "${ipv6_address}" ]]; then
            fn_replace_token_in_file "${working_file}" "get_ipv6_address" "${ipv6_address}"
            fn_replace_token_in_file "${working_file}" "get_ipv6_gateway" "${ipv6_gateway}"
            fn_replace_token_in_file "${working_file}" "get_ipv6_prefix" "${ipv6_prefix}"
        fi
        # Always replace IPv6 nameserver if configured
        if [[ -n "${ipv6_nameserver}" ]]; then
            fn_replace_token_in_file "${working_file}" "get_ipv6_nameserver" "${ipv6_nameserver}"
        fi
        fn_replace_token_in_file "${working_file}" "get_hostname" "${kickstart_short_hostname}"
        fn_replace_token_in_file "${working_file}" "get_lab_infra_server_hostname" "${lab_infra_server_hostname}"
        fn_replace_token_in_file "${working_file}" "get_time_of_last_update" "${time_of_last_update}"
        fn_replace_token_in_file "${working_file}" "get_mgmt_super_user" "${mgmt_super_user}"
        fn_replace_token_in_file "${working_file}" "get_os_name_and_version" "${os_name_and_version}"
        fn_replace_token_in_file "${working_file}" "get_disk_type_for_the_vm" "${disk_type_for_the_vm}"
        fn_replace_token_in_file "${working_file}" "get_golden_image_creation_not_requested" "${golden_image_creation_not_requested}"
        fn_replace_token_in_file "${working_file}" "get_redhat_based_distro_name" "${redhat_based_distro_name}"
        fn_replace_token_in_file "${working_file}" "get_version" "${version}"
        fn_replace_token_in_file "${working_file}" "get_opensuse_version_number" "${opensuse_version_number}"
        fn_replace_token_in_file "${working_file}" "get_subnets_to_allow_ssh_pub_access" "${subnets_to_allow_ssh_pub_access}"

        awk -v val="$shadow_password_super_mgmt_user" '
        {
                gsub(/get_shadow_password_super_mgmt_user/, val)
        }
        1
        ' "${working_file}" > "${working_file}"_tmp_ksmanager && mv "${working_file}"_tmp_ksmanager "${working_file}"
    }

    if [[ -d "${input_dir_or_file}" ]]
    then
        while IFS= read -r -d '' working_file; do
            fn_update_dynamic_parameters "${working_file}"
        done < <(find "${input_dir_or_file}" -type f -print0)

    elif [[ -f "${input_dir_or_file}" ]]
    then
        working_file="${input_dir_or_file}"
        fn_update_dynamic_parameters "${working_file}"
    fi
}

if ! $invoked_with_golden_image; then

    fn_set_environment "${host_kickstart_dir}"
    mac_based_ipxe_cfg_file="${ipxe_web_dir}/${ipxe_cfg_mac_address}.ipxe"

    if [[ -z "${redhat_based_distro_name}" ]]; then
        if ! rsync -a -q "${ksmanager_main_dir}/ipxe-templates/ipxe-template-${os_distribution}.ipxe"  "${mac_based_ipxe_cfg_file}"; then
            print_error "Failed to copy iPXE template for ${os_distribution}"
            fn_release_host_lock
            exit 1
        fi
    else
        if ! rsync -a -q "${ksmanager_main_dir}/ipxe-templates/ipxe-template-redhat-based.ipxe"  "${mac_based_ipxe_cfg_file}"; then
            print_error "Failed to copy iPXE template for redhat-based"
            fn_release_host_lock
            exit 1
        fi
    fi

    fn_set_environment "${mac_based_ipxe_cfg_file}"

fi

if $invoked_with_golden_image; then
    fn_set_environment "${ksmanager_hub_dir}"/golden-boot-mac-configs/network-config-"${ipxe_cfg_mac_address}"
fi

fn_chown_if_exists "${mac_cache_file}"
fn_chown_if_exists "${host_kickstart_dir}"
fn_chown_if_exists "${ksmanager_hub_dir}/addons-for-kickstarts"
fn_chown_if_exists "${ksmanager_hub_dir}/golden-boot-mac-configs"
fn_chown_if_exists "${ipxe_web_dir}/${ipxe_cfg_mac_address}.ipxe"

if $shared_lock_acquired; then
    fn_release_shared_artifacts_lock
fi

fn_update_kea_dhcp_reservations() {
  print_task "Updating KEA DHCP reservations..."
  local kea_cache_file="${ksmanager_hub_dir}/mac-address-cache"
  local kea_dhcp4_config_file="/etc/kea/kea-dhcp4.conf"
  local kea_dhcp6_config_file="/etc/kea/kea-dhcp6.conf"
  local kea_api_url="http://127.0.0.1:8000/"
  local kea_api_auth="kea-api:kea-api-password"
  local kea_temp_config_timestamp=$(date +"%Y%m%d_%H%M%S_%Z")
  local kea_config_temp_dir="${ksmanager_hub_dir}/kea_dhcp_temp_configs_with_reservation"
  local kea_dhcp4_tmp_config="${kea_config_temp_dir}/kea-dhcp4.conf_${kea_temp_config_timestamp}"
  local kea_dhcp6_tmp_config="${kea_config_temp_dir}/kea-dhcp6.conf_${kea_temp_config_timestamp}"

  mkdir -p "$kea_config_temp_dir"

    local kea_cache_snapshot="${kea_config_temp_dir}/mac-address-cache.snapshot.$$"

    if ! fn_acquire_mac_cache_lock; then
        print_task_fail
        exit 1
    fi

    current_ip_with_mac=$(awk -v host="${kickstart_hostname}" '$1 == host {print $3; exit}' "${kea_cache_file}")
    if [[ -n "${current_ip_with_mac}" && "${current_ip_with_mac}" != "${ipv4_address}" ]]; then
        awk -v host="${kickstart_hostname}" -v new_ip="${ipv4_address}" '
            $1 == host {$3 = new_ip}
            {print}
        ' "${kea_cache_file}" > "${kea_cache_file}.tmp.$$" && mv "${kea_cache_file}.tmp.$$" "${kea_cache_file}"
        rm -f "${kea_cache_file}.tmp.$$"
    fi

    if [[ -f "${kea_cache_file}" ]]; then
        if ! cp "${kea_cache_file}" "${kea_cache_snapshot}"; then
            fn_release_mac_cache_lock
            print_task_fail
            print_error "Failed to create KEA cache snapshot."
            exit 1
        fi
    else
        if ! : > "${kea_cache_snapshot}"; then
            fn_release_mac_cache_lock
            print_task_fail
            print_error "Failed to create KEA cache snapshot."
            exit 1
        fi
    fi

    fn_release_mac_cache_lock

  # ===== DHCPv4 Reservations =====
  # Read existing Kea DHCPv4 config
  local kea_dhcp4_existing_config
  if ! kea_dhcp4_existing_config=$(sudo cat "$kea_dhcp4_config_file"); then
    print_task_fail
    print_error "Failed to read KEA DHCPv4 config: ${kea_dhcp4_config_file}"
    exit 1
  fi

  # Build JSON array of DHCPv4 reservations from cache file
  local kea_dhcp4_reservations_json=""
  while read -r kea_hostname kea_hw_address kea_ip_address kea_ipv6_address; do
    kea_dhcp4_reservations_json+="{
      \"hostname\": \"$kea_hostname\",
      \"hw-address\": \"$kea_hw_address\",
      \"ip-address\": \"$kea_ip_address\"
    },"
    done < "$kea_cache_snapshot"

  kea_dhcp4_reservations_json="[${kea_dhcp4_reservations_json%,}]"

  # Insert DHCPv4 reservations into config JSON
  local kea_dhcp4_new_config
  kea_dhcp4_new_config=$(echo "$kea_dhcp4_existing_config" | \
    jq --argjson reservations "$kea_dhcp4_reservations_json" \
      '.Dhcp4.subnet4[0].reservations = $reservations')

  # Wrap into config-set command for DHCPv4
  cat > "$kea_dhcp4_tmp_config" <<EOF
{
  "command": "config-set",
  "service": [ "dhcp4" ],
  "arguments": $kea_dhcp4_new_config
}
EOF

  # ===== DHCPv6 Reservations =====
  # Read existing Kea DHCPv6 config
  local kea_dhcp6_existing_config
  if ! kea_dhcp6_existing_config=$(sudo cat "$kea_dhcp6_config_file"); then
    print_task_fail
    print_error "Failed to read KEA DHCPv6 config: ${kea_dhcp6_config_file}"
    exit 1
  fi

  # Build JSON array of DHCPv6 reservations from cache file
  local kea_dhcp6_reservations_json=""
  while read -r kea_hostname kea_hw_address kea_ip_address kea_ipv6_address; do
    kea_dhcp6_reservations_json+="{
      \"hostname\": \"$kea_hostname\",
      \"hw-address\": \"$kea_hw_address\",
      \"ip-addresses\": [ \"${kea_ipv6_address}\" ]
    },"
    done < "$kea_cache_snapshot"

  kea_dhcp6_reservations_json="[${kea_dhcp6_reservations_json%,}]"

  # Insert DHCPv6 reservations into config JSON
  local kea_dhcp6_new_config
  kea_dhcp6_new_config=$(echo "$kea_dhcp6_existing_config" | \
    jq --argjson reservations "$kea_dhcp6_reservations_json" \
      '.Dhcp6.subnet6[0].reservations = $reservations')

  # Wrap into config-set command for DHCPv6
  cat > "$kea_dhcp6_tmp_config" <<EOF
{
  "command": "config-set",
  "service": [ "dhcp6" ],
  "arguments": $kea_dhcp6_new_config
}
EOF

  # ===== Delete old DHCPv4 leases =====
  # Delete old DHCPv4 lease by MAC (safe if none exists)
  curl -s -X POST -H "Content-Type: application/json" \
    -u "$kea_api_auth" \
    -d "{
          \"command\": \"lease4-del\",
          \"service\": [ \"dhcp4\" ],
          \"arguments\": {
            \"identifier-type\": \"hw-address\",
            \"identifier\": \"${mac_address_of_host}\",
            \"subnet-id\": 1
          }
        }" \
  "$kea_api_url" &>/dev/null

  # Delete DHCPv4 lease by IP (safe if none exists)
  curl -s -X POST -H "Content-Type: application/json" \
    -u "$kea_api_auth" \
    -d "{
          \"command\": \"lease4-del\",
          \"service\": [ \"dhcp4\" ],
          \"arguments\": {
            \"ip-address\": \"${ipv4_address}\",
            \"subnet-id\": 1
          }
        }" \
   "$kea_api_url" &>/dev/null

  # ===== Delete old DHCPv6 leases =====
  # Delete old DHCPv6 lease by MAC (safe if none exists)
  curl -s -X POST -H "Content-Type: application/json" \
    -u "$kea_api_auth" \
    -d "{
          \"command\": \"lease6-del\",
          \"service\": [ \"dhcp6\" ],
          \"arguments\": {
            \"identifier-type\": \"hw-address\",
            \"identifier\": \"${mac_address_of_host}\",
            \"subnet-id\": 1
          }
        }" \
  "$kea_api_url" &>/dev/null

  # Delete DHCPv6 lease by IP (safe if none exists)
  curl -s -X POST -H "Content-Type: application/json" \
    -u "$kea_api_auth" \
    -d "{
          \"command\": \"lease6-del\",
          \"service\": [ \"dhcp6\" ],
          \"arguments\": {
            \"ip-address\": \"${ipv6_address}\",
            \"subnet-id\": 1
          }
        }" \
   "$kea_api_url" &>/dev/null

  # ===== Push new configs dynamically =====
  # Push DHCPv4 config
  if ! curl -s -X POST -H "Content-Type: application/json" \
    -u "$kea_api_auth" \
    -d @"$kea_dhcp4_tmp_config" \
    "$kea_api_url" &>/dev/null; then
    print_task_fail
    print_error "Failed to update KEA DHCPv4 reservations."
    exit 1
  fi

  # Push DHCPv6 config
  if curl -s -X POST -H "Content-Type: application/json" \
    -u "$kea_api_auth" \
    -d @"$kea_dhcp6_tmp_config" \
    "$kea_api_url" &>/dev/null; then
        rm -f "${kea_cache_snapshot}"
    print_task_done
  else
        rm -f "${kea_cache_snapshot}"
    print_task_fail
    print_error "Failed to update KEA DHCPv6 reservations."
    exit 1
  fi
}

if systemctl is-active --quiet kea-ctrl-agent; then
    fn_update_kea_dhcp_reservations
fi

config_summary="Configuration Summary:
  ✓ Hostname         : ${kickstart_hostname}
  ✓ MAC Address      : ${mac_address_of_host}
  ✓ IPv4 Address     : ${ipv4_address}
  ✓ IPv4 Netmask     : ${ipv4_netmask}
  ✓ IPv4 Gateway     : ${ipv4_gateway}
  ✓ IPv4 Network     : ${ipv4_network_cidr}
  ✓ IPv4 DNS         : ${ipv4_nameserver}
  ✓ IPv6 Address     : ${ipv6_address}
  ✓ IPv6 Prefix      : ${ipv6_prefix}
  ✓ IPv6 Gateway     : ${ipv6_gateway}
  ✓ Domain           : ${ipv4_domain}
  ✓ Lab Infra Server : ${lab_infra_server_hostname}
  ✓ Requested OS     : ${os_name_and_version}"

print_info "$config_summary"

# Determine provision method from invocation flags
provision_method="pxe"
if ! $golden_image_creation_not_requested; then
    provision_method="create-golden-image"
elif $invoked_with_golden_image; then
    provision_method="golden-image"
fi

# Build JSON record with all 20 fields
provision_json=$(jq -n \
    --arg hostname "$kickstart_hostname" \
    --arg mac_address "$mac_address_of_host" \
    --arg os "${os_name_and_version:-}" \
    --arg os_distribution "${os_distribution:-}" \
    --arg version "${version:-}" \
    --arg provision_method "$provision_method" \
    --arg disk_type "${disk_type_for_the_vm:-}" \
    --arg ipv4_address "$ipv4_address" \
    --arg ipv4_prefix "$ipv4_prefix" \
    --arg ipv4_netmask "$ipv4_netmask" \
    --arg ipv4_gateway "$ipv4_gateway" \
    --arg ipv4_nameserver "$ipv4_nameserver" \
    --arg ipv4_network_cidr "$ipv4_network_cidr" \
    --arg ipv4_domain "$ipv4_domain" \
    --arg ipv6_address "$ipv6_address" \
    --arg ipv6_prefix "$ipv6_prefix" \
    --arg ipv6_gateway "$ipv6_gateway" \
    --arg ipv6_nameserver "$ipv6_nameserver" \
    --arg lab_infra_server "$lab_infra_server_hostname" \
    --arg provisioned_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{
        hostname: $hostname,
        mac_address: $mac_address,
        os: $os,
        os_distribution: $os_distribution,
        version: $version,
        provision_method: $provision_method,
        disk_type: $disk_type,
        ipv4_address: $ipv4_address,
        ipv4_prefix: $ipv4_prefix,
        ipv4_netmask: $ipv4_netmask,
        ipv4_gateway: $ipv4_gateway,
        ipv4_nameserver: $ipv4_nameserver,
        ipv4_network_cidr: $ipv4_network_cidr,
        ipv4_domain: $ipv4_domain,
        ipv6_address: $ipv6_address,
        ipv6_prefix: $ipv6_prefix,
        ipv6_gateway: $ipv6_gateway,
        ipv6_nameserver: $ipv6_nameserver,
        lab_infra_server: $lab_infra_server,
        provisioned_at: $provisioned_at
    }')

# Write per-host provision-result.json sidecar
# Ensure the kickstart directory exists (golden-image path skips fn_create_host_kickstart_dir)
if [[ -z "${host_kickstart_dir:-}" ]]; then
    host_kickstart_dir="${ksmanager_hub_dir}/kickstarts/${kickstart_hostname}"
fi
mkdir -p "${host_kickstart_dir}"

if [[ -d "${host_kickstart_dir}" ]] && [[ -n "$provision_json" ]]; then
    provision_result_tmp="${host_kickstart_dir}/provision-result.json.tmp.$$"
    printf '%s\n' "$provision_json" > "$provision_result_tmp" && \
        mv "$provision_result_tmp" "${host_kickstart_dir}/provision-result.json"
    rm -f "$provision_result_tmp"
    fn_chown_if_exists "${host_kickstart_dir}/provision-result.json"
fi

# Update central hosts.json registry
if [[ -n "$provision_json" ]]; then
    if fn_acquire_mac_cache_lock; then
        hosts_json_tmp="${hosts_json_file}.tmp.$$"
        if [[ -f "$hosts_json_file" ]]; then
            jq --arg hostname "$kickstart_hostname" --argjson new_entry "$provision_json" \
                '[.[] | select(.hostname != $hostname)] + [$new_entry]' \
                "$hosts_json_file" > "$hosts_json_tmp" && \
                mv "$hosts_json_tmp" "$hosts_json_file"
        else
            printf '[%s]\n' "$provision_json" > "$hosts_json_tmp" && \
                mv "$hosts_json_tmp" "$hosts_json_file"
        fi
        rm -f "$hosts_json_tmp"
        fn_chown_if_exists "$hosts_json_file"
        fn_release_mac_cache_lock
    fi
fi

if ! $invoked_with_golden_image; then
    print_info "Kickstart configs ready for '${kickstart_hostname}'."
else
    print_info "Golden boot configs ready for '${kickstart_hostname}'."
fi

fn_release_host_lock

exit
