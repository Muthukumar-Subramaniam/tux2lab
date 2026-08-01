#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: lbmanager.sh                                                              #
# Description: Manage nginx TCP stream load balancers for the tux2lab infrastructure      #
# If you encounter any issues with this script, or have suggestions or feature requests,  #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues       #
#----------------------------------------------------------------------------------------#

set -euo pipefail

source /tux2lab/common-utils/color-functions.sh

# ====== ROOT GUARD ======
if [[ "${UID}" -ne 0 ]]; then
    print_error "Run with sudo or run from root account!"
    exit 1
fi

# ====== ENVIRONMENT ======
readonly LB_HUB_DIR="/tux2lab-data/lb-hub"
readonly LB_REGISTRY="${LB_HUB_DIR}/lb-registry.json"
readonly STREAM_CONF_DIR="/tux2lab-data/nginx/stream.d"
readonly LOCK_DIR="/tux2lab-data/.lbmanager.lock"
readonly CONTAINER_NAME="tux2lab-engine"
readonly LAB_ENV_JSON="/tux2lab-data/lab-config/lab_environment.json"

# Ensure required directories and registry exist
mkdir -p "$LB_HUB_DIR" "$STREAM_CONF_DIR"
[[ -f "$LB_REGISTRY" ]] || echo '{"load_balancers":[]}' > "$LB_REGISTRY"

# Read config from lab environment
if [[ -f "$LAB_ENV_JSON" ]]; then
    readonly MGMT_INTERFACE=$(jq -r '.network.bridge_interface' "$LAB_ENV_JSON")
    readonly DOMAIN=$(jq -r '.lab.domain' "$LAB_ENV_JSON")
    readonly DNS_SERVER=$(jq -r '.network.ipv4.address' "$LAB_ENV_JSON")
else
    readonly MGMT_INTERFACE="${mgmt_interface_name:-eth0}"
    readonly DOMAIN="${dnsbinder_domain:-}"
    readonly DNS_SERVER="127.0.0.1"
fi

lock_acquired=false

# ====== LOCK MECHANISM ======
fn_acquire_lock() {
    local retries=400
    local existing_pid=""

    while ! mkdir "${LOCK_DIR}" 2>/dev/null; do
        if [[ -f "${LOCK_DIR}/pid" ]]; then
            existing_pid=$(cat "${LOCK_DIR}/pid" 2>/dev/null)
            if [[ -n "${existing_pid}" ]] && ! kill -0 "${existing_pid}" 2>/dev/null; then
                rm -f "${LOCK_DIR}/pid"
                rmdir "${LOCK_DIR}" 2>/dev/null || true
                continue
            fi
        fi

        sleep 0.05
        retries=$((retries - 1))
        if [[ "${retries}" -le 0 ]]; then
            print_error "Unable to acquire lbmanager lock. Another instance may be running. Please retry."
            return 1
        fi
    done

    printf '%s\n' "$$" > "${LOCK_DIR}/pid"
    lock_acquired=true
}

fn_release_lock() {
    local lock_pid=""
    if ! $lock_acquired; then return; fi
    if [[ -f "${LOCK_DIR}/pid" ]]; then
        lock_pid=$(cat "${LOCK_DIR}/pid" 2>/dev/null)
    fi
    if [[ -d "${LOCK_DIR}" ]] && [[ "${lock_pid}" = "$$" ]]; then
        rm -f "${LOCK_DIR}/pid"
        rmdir "${LOCK_DIR}" 2>/dev/null || true
    fi
    lock_acquired=false
}

fn_cleanup() {
    fn_release_lock
}

trap fn_cleanup EXIT
trap 'fn_cleanup; exit 130' INT TERM HUP QUIT

# ====== VALIDATION FUNCTIONS ======

# Strip domain suffix if user provides FQDN (e.g., k8s-cp.lab.internal → k8s-cp)
fn_strip_domain() {
    local input="$1"
    if [[ -n "$DOMAIN" ]] && [[ "$input" == *".${DOMAIN}" ]]; then
        echo "${input%.${DOMAIN}}"
    else
        echo "$input"
    fi
}

fn_validate_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        print_error "Load balancer name cannot be empty."
        return 1
    fi
    if [[ ! "$name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        print_error "Invalid name '${name}'. Must be lowercase alphanumeric with hyphens, cannot start or end with a hyphen."
        return 1
    fi
    if [[ ${#name} -gt 63 ]]; then
        print_error "Name '${name}' exceeds 63 characters."
        return 1
    fi
}

fn_validate_port() {
    local port="$1"
    local label="${2:-Port}"
    if [[ -z "$port" ]]; then
        print_error "${label} cannot be empty."
        return 1
    fi
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
        print_error "Invalid ${label} '${port}'. Must be an integer between 1 and 65535."
        return 1
    fi
}

fn_validate_algorithm() {
    local algo="$1"
    case "$algo" in
        round-robin|least-conn|ip-hash) ;;
        *)
            print_error "Invalid algorithm '${algo}'. Must be one of: round-robin, least-conn, ip-hash."
            return 1
            ;;
    esac
}

fn_validate_backends() {
    local backends_csv="$1"
    if [[ -z "$backends_csv" ]]; then
        print_error "Backends list cannot be empty."
        return 1
    fi

    IFS=',' read -ra backend_list <<< "$backends_csv"

    if [[ ${#backend_list[@]} -eq 0 ]]; then
        print_error "At least one backend is required."
        return 1
    fi

    for backend in "${backend_list[@]}"; do
        if [[ -z "$backend" ]]; then
            print_error "Empty backend entry found in list."
            return 1
        fi
        if ! dig @"${DNS_SERVER}" +short +time=1 +tries=1 A "${backend}.${DOMAIN}" 2>/dev/null | grep -q '^[0-9]'; then
            print_info "Creating DNS record for backend ${backend}..."
            if ! /tux2lab/named-manage/dnsbinder.sh -c "$backend"; then
                print_error "Failed to create DNS record for backend '${backend}'."
                return 1
            fi
        fi
    done
}

# ====== REGISTRY FUNCTIONS ======
fn_lb_exists() {
    local name="$1"
    jq -e --arg n "$name" '.load_balancers[] | select(.name == $n)' "$LB_REGISTRY" &>/dev/null
}

fn_get_lb() {
    local name="$1"
    jq --arg n "$name" '.load_balancers[] | select(.name == $n)' "$LB_REGISTRY"
}

fn_get_lb_count() {
    jq '.load_balancers | length' "$LB_REGISTRY"
}

fn_add_lb_to_registry() {
    local name="$1" port="$2" target_port="$3" algorithm="$4" ipv4="$5" ipv6="$6" interface="$7" backends_csv="$8"
    local created_at
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Convert comma-separated backends to JSON array
    local backends_json
    backends_json=$(echo "$backends_csv" | tr ',' '\n' | jq -R . | jq -s .)

    local tmp_file
    tmp_file=$(mktemp "${LB_REGISTRY}.XXXXXXXXXX")

    jq --arg name "$name" \
       --argjson port "$port" \
       --argjson target_port "$target_port" \
       --arg algorithm "$algorithm" \
       --arg ipv4 "$ipv4" \
       --arg ipv6 "$ipv6" \
       --arg interface "$interface" \
       --argjson backends "$backends_json" \
       --arg created_at "$created_at" \
       '.load_balancers += [{
           name: $name,
           port: $port,
           target_port: $target_port,
           algorithm: $algorithm,
           ipv4: $ipv4,
           ipv6: $ipv6,
           interface: $interface,
           backends: $backends,
           created_at: $created_at
       }]' "$LB_REGISTRY" > "$tmp_file"

    mv "$tmp_file" "$LB_REGISTRY"
}

fn_remove_lb_from_registry() {
    local name="$1"
    local tmp_file
    tmp_file=$(mktemp "${LB_REGISTRY}.XXXXXXXXXX")

    jq --arg n "$name" '.load_balancers |= map(select(.name != $n))' "$LB_REGISTRY" > "$tmp_file"
    mv "$tmp_file" "$LB_REGISTRY"
}

fn_update_lb_in_registry() {
    local name="$1"
    shift
    local tmp_file
    tmp_file=$(mktemp "${LB_REGISTRY}.XXXXXXXXXX")

    # Build jq update expression from key=value pairs
    local jq_updates="."
    while [[ $# -gt 0 ]]; do
        local key="${1%%=*}"
        local value="${1#*=}"
        case "$key" in
            port|target_port)
                jq_updates="${jq_updates} | (.load_balancers[] | select(.name == \$n)).${key} = ${value}"
                ;;
            algorithm)
                jq_updates="${jq_updates} | (.load_balancers[] | select(.name == \$n)).${key} = \"${value}\""
                ;;
            backends)
                local backends_json
                backends_json=$(echo "$value" | tr ',' '\n' | jq -R . | jq -s .)
                jq_updates="${jq_updates} | (.load_balancers[] | select(.name == \$n)).${key} = ${backends_json}"
                ;;
        esac
        shift
    done

    jq --arg n "$name" "$jq_updates" "$LB_REGISTRY" > "$tmp_file"
    mv "$tmp_file" "$LB_REGISTRY"
}

# ====== DNS FUNCTIONS ======
fn_create_dns_record() {
    local name="$1"

    if dig @"${DNS_SERVER}" +short +time=1 +tries=1 A "${name}.${DOMAIN}" 2>/dev/null | grep -q '^[0-9]'; then
        local resolved_ip
        resolved_ip=$(dig @"${DNS_SERVER}" +short +time=1 +tries=1 A "${name}.${DOMAIN}" 2>/dev/null | head -1)
        local infra_ip
        infra_ip=$(jq -r '.network.ipv4.address' "$LAB_ENV_JSON" 2>/dev/null || echo "")

        if [[ -n "$infra_ip" ]] && [[ "$resolved_ip" == "$infra_ip" ]]; then
            print_warning "Existing record for ${name}.${DOMAIN} points to infra server (${infra_ip})."
            print_info "Removing stale record and creating a dedicated LB record..."
            /tux2lab/named-manage/dnsbinder.sh -dcy "$name" &>/dev/null || true
            /tux2lab/named-manage/dnsbinder.sh -dc "$name" &>/dev/null || true
        else
            print_task "DNS record for ${name}.${DOMAIN}..."
            print_task_skip
            print_info "Already exists with IP ${resolved_ip}"
            return 0
        fi
    fi

    print_info "Creating DNS A/AAAA record for ${name}.${DOMAIN}..."
    if ! /tux2lab/named-manage/dnsbinder.sh -c "$name"; then
        print_error "Failed to create DNS record for ${name}"
        return 1
    fi
}

fn_delete_dns_record() {
    local name="$1"
    print_task "Deleting DNS record for ${name}.${DOMAIN}..."
    if ! dig @"${DNS_SERVER}" +short +time=1 +tries=1 A "${name}.${DOMAIN}" 2>/dev/null | grep -q '^[0-9]'; then
        print_task_skip
        return 0
    fi

    if /tux2lab/named-manage/dnsbinder.sh -dy "$name" &>/dev/null; then
        print_task_done
    else
        print_task_fail
        print_error "Failed to delete DNS record for ${name}"
        return 1
    fi
}

fn_resolve_ip() {
    local name="$1"
    local fqdn="${name}.${DOMAIN}"
    local ipv4="" ipv6=""
    local retries=10

    while [[ $retries -gt 0 ]]; do
        ipv4=$(dig @"${DNS_SERVER}" +short +time=1 +tries=1 A "$fqdn" 2>/dev/null | head -1)
        ipv6=$(dig @"${DNS_SERVER}" +short +time=1 +tries=1 AAAA "$fqdn" 2>/dev/null | head -1)
        [[ -n "$ipv4" ]] && [[ -n "$ipv6" ]] && break
        sleep 0.5
        retries=$((retries - 1))
    done

    if [[ -z "$ipv4" ]]; then
        print_error "Could not resolve IPv4 for ${fqdn}" >&2
        return 1
    fi

    if [[ -z "$ipv6" ]]; then
        print_error "Could not resolve IPv6 for ${fqdn}" >&2
        return 1
    fi

    echo "${ipv4} ${ipv6}"
}

# ====== SECONDARY IP FUNCTIONS ======
fn_check_ip_on_interface() {
    local ip="$1"
    local interface="$2"
    ip addr show dev "$interface" 2>/dev/null | grep -qw "$ip"
}

fn_add_secondary_ip() {
    local ipv4="$1" ipv6="$2" interface="$3"
    local ipv4_prefix ipv6_prefix

    # Determine prefix lengths from existing interface config
    ipv4_prefix=$(ip -4 addr show dev "$interface" | awk '/inet / {print $2; exit}' | cut -d'/' -f2)
    ipv6_prefix=$(ip -6 addr show dev "$interface" scope global | awk '/inet6/ {print $2; exit}' | cut -d'/' -f2)
    ipv4_prefix="${ipv4_prefix:-22}"
    ipv6_prefix="${ipv6_prefix:-64}"

    print_task "Adding secondary IPv4 ${ipv4}/${ipv4_prefix} to ${interface}..."
    if fn_check_ip_on_interface "$ipv4" "$interface"; then
        print_task_skip
    else
        if ip addr add "${ipv4}/${ipv4_prefix}" dev "$interface" 2>/dev/null; then
            print_task_done
        else
            print_task_fail
            print_error "Failed to add IPv4 ${ipv4}/${ipv4_prefix} to ${interface}"
            return 1
        fi
    fi

    print_task "Adding secondary IPv6 ${ipv6}/${ipv6_prefix} to ${interface}..."
    if fn_check_ip_on_interface "$ipv6" "$interface"; then
        print_task_skip
    else
        if ip addr add "${ipv6}/${ipv6_prefix}" dev "$interface" 2>/dev/null; then
            print_task_done
        else
            print_task_fail
            print_error "Failed to add IPv6 ${ipv6}/${ipv6_prefix} to ${interface}"
            return 1
        fi
    fi
}

fn_remove_secondary_ip() {
    local ipv4="$1" ipv6="$2" interface="$3"
    local ipv4_prefix ipv6_prefix

    ipv4_prefix=$(ip -4 addr show dev "$interface" | awk '/inet / {print $2; exit}' | cut -d'/' -f2)
    ipv6_prefix=$(ip -6 addr show dev "$interface" scope global | awk '/inet6/ {print $2; exit}' | cut -d'/' -f2)
    ipv4_prefix="${ipv4_prefix:-22}"
    ipv6_prefix="${ipv6_prefix:-64}"

    print_task "Removing secondary IPv4 ${ipv4}/${ipv4_prefix} from ${interface}..."
    if fn_check_ip_on_interface "$ipv4" "$interface"; then
        if ip addr del "${ipv4}/${ipv4_prefix}" dev "$interface" 2>/dev/null; then
            print_task_done
        else
            print_task_fail
            print_warning "Failed to remove IPv4 ${ipv4} from ${interface}"
        fi
    else
        print_task_skip
    fi

    print_task "Removing secondary IPv6 ${ipv6}/${ipv6_prefix} from ${interface}..."
    if fn_check_ip_on_interface "$ipv6" "$interface"; then
        if ip addr del "${ipv6}/${ipv6_prefix}" dev "$interface" 2>/dev/null; then
            print_task_done
        else
            print_task_fail
            print_warning "Failed to remove IPv6 ${ipv6} from ${interface}"
        fi
    else
        print_task_skip
    fi
}

# ====== NGINX FUNCTIONS ======
fn_check_port_conflict() {
    local ipv4="$1" port="$2"
    if ss -tlnp 2>/dev/null | grep -q "${ipv4}:${port}"; then
        print_error "Port conflict: ${ipv4}:${port} is already in use."
        return 1
    fi
}

fn_generate_nginx_config() {
    local name="$1" port="$2" target_port="$3" algorithm="$4" ipv4="$5" ipv6="$6" backends_csv="$7"
    local config_file="${STREAM_CONF_DIR}/${name}.conf"
    local upstream_name="${name//-/_}_upstream"
    local log_format_name="${name//-/_}_log"

    # Build algorithm directive
    local algo_directive=""
    case "$algorithm" in
        least-conn)  algo_directive="    least_conn;" ;;
        ip-hash)     algo_directive="    hash \$remote_addr consistent;" ;;
        round-robin) algo_directive="" ;;
    esac

    # Build upstream servers
    local upstream_servers=""
    IFS=',' read -ra backend_list <<< "$backends_csv"
    for backend in "${backend_list[@]}"; do
        upstream_servers="${upstream_servers}    server ${backend}.${DOMAIN}:${target_port} max_fails=3 fail_timeout=30s;\n"
    done

    print_task "Generating nginx stream config ${config_file}..."

    cat > "$config_file" <<EOF
# Managed by tux2lab lbmanager — do not edit manually
# Load balancer: ${name}

log_format ${log_format_name} '\$remote_addr [\$time_local] '
                       '\$protocol \$status \$bytes_sent bytes_sent '
                       'to: \$upstream_addr';

upstream ${upstream_name} {
${algo_directive:+${algo_directive}
}$(echo -e "$upstream_servers")
}

server {
    listen ${ipv4}:${port};
    listen [${ipv6}]:${port};

    proxy_pass ${upstream_name};
    proxy_timeout 10m;
    proxy_connect_timeout 5s;

    access_log /var/log/nginx/${name}_access.log ${log_format_name};
    error_log  /var/log/nginx/${name}_error.log info;
}
EOF

    print_task_done
}

fn_remove_nginx_config() {
    local name="$1"
    local config_file="${STREAM_CONF_DIR}/${name}.conf"

    print_task "Removing nginx config ${config_file}..."
    if [[ -f "$config_file" ]]; then
        rm -f "$config_file"
        print_task_done
    else
        print_task_skip
    fi
}

fn_validate_nginx() {
    print_task "Validating nginx configuration..."
    if podman exec "$CONTAINER_NAME" nginx -t -c /tux2lab-data/nginx/nginx.conf &>/dev/null; then
        print_task_done
    else
        print_task_fail
        print_error "nginx configuration validation failed. Rolling back."
        return 1
    fi
}

fn_reload_nginx() {
    print_task "Reloading nginx..."
    if podman exec "$CONTAINER_NAME" nginx -c /tux2lab-data/nginx/nginx.conf -s reload &>/dev/null; then
        print_task_done
    else
        print_task_fail
        print_error "Failed to reload nginx."
        return 1
    fi
}

# ====== SUBCOMMAND: CREATE ======
fn_create() {
    local name="" port="" target_port="" backends="" algorithm="round-robin" yes_flag=false
    local prev_arg=""

    for arg in "$@"; do
        case "$prev_arg" in
            --name)        name="$arg" ;;
            --port)        port="$arg" ;;
            --target-port) target_port="$arg" ;;
            --backends)    backends="$arg" ;;
            --algorithm)   algorithm="$arg" ;;
        esac
        prev_arg="$arg"
        [[ "$arg" == "-y" || "$arg" == "--yes" ]] && yes_flag=true
    done

    # Interactive prompts for missing fields
    if [[ -z "$name" ]]; then
        read -rp "Enter load balancer name: " name
    fi
    if [[ -z "$port" ]]; then
        read -rp "Enter listen port: " port
    fi
    if [[ -z "$target_port" ]]; then
        read -rp "Enter target port (backend port): " target_port
    fi
    if [[ -z "$backends" ]]; then
        read -rp "Enter backend hostnames (comma-separated): " backends
    fi
    if [[ "$algorithm" == "round-robin" ]] && ! $yes_flag; then
        local algo_input
        read -rp "Enter algorithm [round-robin/least-conn/ip-hash] (default: round-robin): " algo_input
        if [[ -n "$algo_input" ]]; then
            algorithm="$algo_input"
        fi
    fi

    # Strip domain suffix if user provides FQDNs
    name=$(fn_strip_domain "$name")

    # Strip domain from each backend
    if [[ -n "$backends" ]]; then
        local stripped_backends=()
        IFS=',' read -ra raw_backends <<< "$backends"
        for b in "${raw_backends[@]}"; do
            stripped_backends+=("$(fn_strip_domain "$b")")
        done
        backends=$(IFS=','; echo "${stripped_backends[*]}")
    fi

    # Validate all inputs
    fn_validate_name "$name"
    fn_validate_port "$port" "Listen port"
    fn_validate_port "$target_port" "Target port"
    fn_validate_algorithm "$algorithm"

    if [[ -z "$DOMAIN" ]]; then
        print_error "DNS domain is not configured. Ensure dnsbinder is set up."
        exit 1
    fi

    fn_validate_backends "$backends"

    # Check if LB already exists
    if fn_lb_exists "$name"; then
        print_error "Load balancer '${name}' already exists."
        exit 1
    fi

    fn_acquire_lock

    print_info "Creating load balancer: ${name}"
    print_notify "  Listen     : ${port}"
    print_notify "  Target     : ${target_port}"
    print_notify "  Backends   : ${backends}"
    print_notify "  Algorithm  : ${algorithm}"
    print_notify "  Interface  : ${MGMT_INTERFACE}"

    # Step 1: Create DNS record
    if ! fn_create_dns_record "$name"; then
        exit 1
    fi

    # Step 2: Resolve IP addresses
    print_task "Resolving IP addresses for ${name}.${DOMAIN}..."
    local ip_pair
    if ! ip_pair=$(fn_resolve_ip "$name"); then
        print_task_fail
        print_error "DNS resolution failed. Cleaning up DNS record..."
        fn_delete_dns_record "$name"
        exit 1
    fi
    local ipv4 ipv6
    ipv4=$(echo "$ip_pair" | awk '{print $1}')
    ipv6=$(echo "$ip_pair" | awk '{print $2}')
    print_task_done
    print_notify "  IPv4: ${ipv4}"
    print_notify "  IPv6: ${ipv6}"

    # Step 3: Check port conflict
    if ! fn_check_port_conflict "$ipv4" "$port"; then
        fn_delete_dns_record "$name"
        exit 1
    fi

    # Step 4: Add secondary IPs
    if ! fn_add_secondary_ip "$ipv4" "$ipv6" "$MGMT_INTERFACE"; then
        fn_delete_dns_record "$name"
        exit 1
    fi

    # Step 5: Generate nginx config
    fn_generate_nginx_config "$name" "$port" "$target_port" "$algorithm" "$ipv4" "$ipv6" "$backends"

    # Step 6: Validate nginx
    if ! fn_validate_nginx; then
        # Rollback: remove config and IPs
        fn_remove_nginx_config "$name"
        fn_remove_secondary_ip "$ipv4" "$ipv6" "$MGMT_INTERFACE"
        fn_delete_dns_record "$name"
        exit 1
    fi

    # Step 7: Register in state
    fn_add_lb_to_registry "$name" "$port" "$target_port" "$algorithm" "$ipv4" "$ipv6" "$MGMT_INTERFACE" "$backends"

    # Step 8: Reload nginx
    fn_reload_nginx

    print_success "Load balancer '${name}' created successfully!"
    print_notify "  Endpoint : ${name}.${DOMAIN}:${port}"
    print_notify "  IPv4     : ${ipv4}:${port}"
    print_notify "  IPv6     : [${ipv6}]:${port}"
}

# ====== SUBCOMMAND: DELETE ======
fn_delete() {
    local name="" yes_flag=false
    local prev_arg=""

    for arg in "$@"; do
        case "$prev_arg" in
            --name) name="$arg" ;;
        esac
        prev_arg="$arg"
        [[ "$arg" == "-y" || "$arg" == "--yes" ]] && yes_flag=true
    done

    # Strip domain suffix if FQDN provided
    [[ -n "$name" ]] && name=$(fn_strip_domain "$name")

    # Interactive: select from list if no name given
    if [[ -z "$name" ]]; then
        local count
        count=$(fn_get_lb_count)
        if [[ "$count" -eq 0 ]]; then
            print_info "No load balancers configured."
            exit 0
        fi

        print_info "Existing load balancers:"
        local i=1
        local names=()
        while IFS= read -r lb_name; do
            names+=("$lb_name")
            local lb_port lb_ipv4
            lb_port=$(jq -r --arg n "$lb_name" '.load_balancers[] | select(.name == $n) | .port' "$LB_REGISTRY")
            lb_ipv4=$(jq -r --arg n "$lb_name" '.load_balancers[] | select(.name == $n) | .ipv4' "$LB_REGISTRY")
            echo "  ${i}) ${lb_name} (${lb_ipv4}:${lb_port})"
            i=$((i + 1))
        done < <(jq -r '.load_balancers[].name' "$LB_REGISTRY")

        local selection
        read -rp "Select load balancer to delete [1-${#names[@]}]: " selection
        if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -gt ${#names[@]} ]]; then
            print_error "Invalid selection."
            exit 1
        fi
        name="${names[$((selection - 1))]}"
    fi

    # Validate LB exists
    if ! fn_lb_exists "$name"; then
        print_error "Load balancer '${name}' does not exist."
        exit 1
    fi

    # Get LB details
    local lb_json
    lb_json=$(fn_get_lb "$name")
    local ipv4 ipv6 interface port
    ipv4=$(echo "$lb_json" | jq -r '.ipv4')
    ipv6=$(echo "$lb_json" | jq -r '.ipv6')
    interface=$(echo "$lb_json" | jq -r '.interface')
    port=$(echo "$lb_json" | jq -r '.port')

    # Confirmation
    if ! $yes_flag; then
        print_warning "About to delete load balancer '${name}' (${ipv4}:${port})"
        local confirm
        while :; do
            read -rp "Please confirm deletion (y/n): " confirm
            case "$confirm" in
                y|Y) break ;;
                n|N) print_warning "Cancelled without any changes!"; exit 0 ;;
                *) print_error "Select only either (y/n)!" ;;
            esac
        done
    fi

    fn_acquire_lock

    print_info "Deleting load balancer: ${name}"

    # Step 1: Remove nginx config
    fn_remove_nginx_config "$name"

    # Step 2: Validate nginx (ensure remaining config is still valid)
    fn_validate_nginx || true

    # Step 3: Remove secondary IPs
    fn_remove_secondary_ip "$ipv4" "$ipv6" "$interface"

    # Step 4: Delete DNS record
    fn_delete_dns_record "$name"

    # Step 5: Remove from registry
    print_task "Removing from registry..."
    fn_remove_lb_from_registry "$name"
    print_task_done

    # Step 6: Reload nginx
    fn_reload_nginx

    print_success "Load balancer '${name}' deleted successfully!"
}

# ====== SUBCOMMAND: UPDATE ======
fn_update() {
    local name="" add_backends="" remove_backends="" new_port="" new_target_port="" new_algorithm=""
    local prev_arg=""

    for arg in "$@"; do
        case "$prev_arg" in
            --name)           name="$arg" ;;
            --add-backend)    add_backends="$arg" ;;
            --remove-backend) remove_backends="$arg" ;;
            --port)           new_port="$arg" ;;
            --target-port)    new_target_port="$arg" ;;
            --algorithm)      new_algorithm="$arg" ;;
        esac
        prev_arg="$arg"
    done

    # Strip domain suffix if FQDN provided
    [[ -n "$name" ]] && name=$(fn_strip_domain "$name")
    [[ -n "$add_backends" ]] && {
        local _stripped=()
        IFS=',' read -ra _raw <<< "$add_backends"
        for _b in "${_raw[@]}"; do _stripped+=("$(fn_strip_domain "$_b")"); done
        add_backends=$(IFS=','; echo "${_stripped[*]}")
    }
    [[ -n "$remove_backends" ]] && {
        local _stripped=()
        IFS=',' read -ra _raw <<< "$remove_backends"
        for _b in "${_raw[@]}"; do _stripped+=("$(fn_strip_domain "$_b")"); done
        remove_backends=$(IFS=','; echo "${_stripped[*]}")
    }

    # Interactive: select from list if no name given
    if [[ -z "$name" ]]; then
        local count
        count=$(fn_get_lb_count)
        if [[ "$count" -eq 0 ]]; then
            print_info "No load balancers configured."
            exit 0
        fi

        print_info "Existing load balancers:"
        local i=1
        local names=()
        while IFS= read -r lb_name; do
            names+=("$lb_name")
            local lb_port lb_ipv4
            lb_port=$(jq -r --arg n "$lb_name" '.load_balancers[] | select(.name == $n) | .port' "$LB_REGISTRY")
            lb_ipv4=$(jq -r --arg n "$lb_name" '.load_balancers[] | select(.name == $n) | .ipv4' "$LB_REGISTRY")
            echo "  ${i}) ${lb_name} (${lb_ipv4}:${lb_port})"
            i=$((i + 1))
        done < <(jq -r '.load_balancers[].name' "$LB_REGISTRY")

        local selection
        read -rp "Select load balancer to update [1-${#names[@]}]: " selection
        if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -gt ${#names[@]} ]]; then
            print_error "Invalid selection."
            exit 1
        fi
        name="${names[$((selection - 1))]}"

        # Interactive update menu
        print_info "What would you like to update?"
        echo "  1) Add backend(s)"
        echo "  2) Remove backend(s)"
        echo "  3) Change listen port"
        echo "  4) Change target port"
        echo "  5) Change algorithm"
        local update_choice
        read -rp "Select [1-5]: " update_choice
        case "$update_choice" in
            1) read -rp "Enter backend(s) to add (comma-separated): " add_backends ;;
            2) read -rp "Enter backend(s) to remove (comma-separated): " remove_backends ;;
            3) read -rp "Enter new listen port: " new_port ;;
            4) read -rp "Enter new target port: " new_target_port ;;
            5) read -rp "Enter new algorithm [round-robin/least-conn/ip-hash]: " new_algorithm ;;
            *) print_error "Invalid selection."; exit 1 ;;
        esac
    fi

    # Validate LB exists
    if ! fn_lb_exists "$name"; then
        print_error "Load balancer '${name}' does not exist."
        exit 1
    fi

    # Get current LB details
    local lb_json
    lb_json=$(fn_get_lb "$name")
    local current_port current_target_port current_algorithm current_ipv4 current_ipv6 current_interface
    current_port=$(echo "$lb_json" | jq -r '.port')
    current_target_port=$(echo "$lb_json" | jq -r '.target_port')
    current_algorithm=$(echo "$lb_json" | jq -r '.algorithm')
    current_ipv4=$(echo "$lb_json" | jq -r '.ipv4')
    current_ipv6=$(echo "$lb_json" | jq -r '.ipv6')
    current_interface=$(echo "$lb_json" | jq -r '.interface')

    # Get current backends as array
    local current_backends
    current_backends=$(echo "$lb_json" | jq -r '.backends | join(",")')

    # Apply updates
    local updated_port="${new_port:-$current_port}"
    local updated_target_port="${new_target_port:-$current_target_port}"
    local updated_algorithm="${new_algorithm:-$current_algorithm}"
    local updated_backends="$current_backends"

    # Validate new values
    [[ -n "$new_port" ]] && fn_validate_port "$new_port" "Listen port"
    [[ -n "$new_target_port" ]] && fn_validate_port "$new_target_port" "Target port"
    [[ -n "$new_algorithm" ]] && fn_validate_algorithm "$new_algorithm"

    # Handle backend additions
    if [[ -n "$add_backends" ]]; then
        fn_validate_backends "$add_backends"
        IFS=',' read -ra add_list <<< "$add_backends"
        IFS=',' read -ra current_list <<< "$current_backends"
        for new_backend in "${add_list[@]}"; do
            local already_exists=false
            for existing in "${current_list[@]}"; do
                if [[ "$new_backend" == "$existing" ]]; then
                    already_exists=true
                    break
                fi
            done
            if $already_exists; then
                print_warning "Backend '${new_backend}' already exists, skipping."
            else
                updated_backends="${updated_backends},${new_backend}"
            fi
        done
    fi

    # Handle backend removals
    if [[ -n "$remove_backends" ]]; then
        IFS=',' read -ra remove_list <<< "$remove_backends"
        IFS=',' read -ra current_list <<< "$updated_backends"
        local remaining=()
        for existing in "${current_list[@]}"; do
            local should_remove=false
            for to_remove in "${remove_list[@]}"; do
                if [[ "$existing" == "$to_remove" ]]; then
                    should_remove=true
                    break
                fi
            done
            if ! $should_remove; then
                remaining+=("$existing")
            fi
        done

        if [[ ${#remaining[@]} -eq 0 ]]; then
            print_error "Cannot remove all backends. At least one backend is required."
            exit 1
        fi

        updated_backends=$(IFS=','; echo "${remaining[*]}")
    fi

    fn_acquire_lock

    print_info "Updating load balancer: ${name}"

    # Regenerate nginx config
    fn_generate_nginx_config "$name" "$updated_port" "$updated_target_port" "$updated_algorithm" \
        "$current_ipv4" "$current_ipv6" "$updated_backends"

    # Validate nginx
    if ! fn_validate_nginx; then
        # Rollback: regenerate original config
        fn_generate_nginx_config "$name" "$current_port" "$current_target_port" "$current_algorithm" \
            "$current_ipv4" "$current_ipv6" "$current_backends"
        exit 1
    fi

    # Update registry
    local registry_updates=()
    [[ -n "$new_port" ]] && registry_updates+=("port=${updated_port}")
    [[ -n "$new_target_port" ]] && registry_updates+=("target_port=${updated_target_port}")
    [[ -n "$new_algorithm" ]] && registry_updates+=("algorithm=${updated_algorithm}")
    [[ -n "$add_backends" || -n "$remove_backends" ]] && registry_updates+=("backends=${updated_backends}")

    if [[ ${#registry_updates[@]} -gt 0 ]]; then
        print_task "Updating registry..."
        fn_update_lb_in_registry "$name" "${registry_updates[@]}"
        print_task_done
    fi

    # Reload nginx
    fn_reload_nginx

    print_success "Load balancer '${name}' updated successfully!"
}

# ====== SUBCOMMAND: LIST ======
fn_list() {
    local count
    count=$(fn_get_lb_count)

    if [[ "$count" -eq 0 ]]; then
        print_info "No load balancers configured."
        return 0
    fi

    printf "${MAKE_IT_CYAN}%-20s %-16s %-25s %-8s %-12s %-12s %s${RESET_COLOR}\n" \
        "NAME" "IPv4" "IPv6" "PORT" "TARGET PORT" "ALGORITHM" "BACKENDS"
    printf "%-20s %-16s %-25s %-8s %-12s %-12s %s\n" \
        "----" "----" "----" "----" "-----------" "---------" "--------"

    while IFS= read -r lb_name; do
        local lb_json
        lb_json=$(fn_get_lb "$lb_name")
        local ipv4 ipv6 port target_port algorithm backends_count
        ipv4=$(echo "$lb_json" | jq -r '.ipv4')
        ipv6=$(echo "$lb_json" | jq -r '.ipv6')
        port=$(echo "$lb_json" | jq -r '.port')
        target_port=$(echo "$lb_json" | jq -r '.target_port')
        algorithm=$(echo "$lb_json" | jq -r '.algorithm')
        backends_count=$(echo "$lb_json" | jq '.backends | length')

        printf "%-20s %-16s %-25s %-8s %-12s %-12s %s\n" \
            "$lb_name" "$ipv4" "$ipv6" "$port" "$target_port" "$algorithm" "${backends_count} backend(s)"
    done < <(jq -r '.load_balancers[].name' "$LB_REGISTRY")

}

# ====== SUBCOMMAND: STATUS ======
fn_status() {
    local name=""
    local prev_arg=""

    for arg in "$@"; do
        case "$prev_arg" in
            --name) name="$arg" ;;
        esac
        prev_arg="$arg"
    done

    # Strip domain suffix if FQDN provided
    [[ -n "$name" ]] && name=$(fn_strip_domain "$name")

    local count
    count=$(fn_get_lb_count)

    if [[ "$count" -eq 0 ]]; then
        print_info "No load balancers configured."
        return 0
    fi

    # Build list of LBs to check
    local lb_names=()
    if [[ -n "$name" ]]; then
        if ! fn_lb_exists "$name"; then
            print_error "Load balancer '${name}' does not exist."
            exit 1
        fi
        lb_names+=("$name")
    else
        while IFS= read -r lb_name; do
            lb_names+=("$lb_name")
        done < <(jq -r '.load_balancers[].name' "$LB_REGISTRY")
    fi

    local total_pass=0 total_fail=0

    for lb_name in "${lb_names[@]}"; do
        local lb_json
        lb_json=$(fn_get_lb "$lb_name")
        local ipv4 ipv6 port interface
        ipv4=$(echo "$lb_json" | jq -r '.ipv4')
        ipv6=$(echo "$lb_json" | jq -r '.ipv6')
        port=$(echo "$lb_json" | jq -r '.port')
        interface=$(echo "$lb_json" | jq -r '.interface')

        print_info "Load Balancer: ${lb_name} (${ipv4}:${port})"

        # Check 1: DNS record
        print_task "DNS record (${lb_name}.${DOMAIN})..."
        if dig @"${DNS_SERVER}" +short +time=1 +tries=1 A "${lb_name}.${DOMAIN}" 2>/dev/null | grep -q '^[0-9]'; then
            print_task_done
            total_pass=$((total_pass + 1))
        else
            print_task_fail
            total_fail=$((total_fail + 1))
        fi

        # Check 2: IPv4 on interface
        print_task "IPv4 ${ipv4} on ${interface}..."
        if fn_check_ip_on_interface "$ipv4" "$interface"; then
            print_task_done
            total_pass=$((total_pass + 1))
        else
            print_task_fail
            total_fail=$((total_fail + 1))
        fi

        # Check 3: IPv6 on interface
        print_task "IPv6 ${ipv6} on ${interface}..."
        if fn_check_ip_on_interface "$ipv6" "$interface"; then
            print_task_done
            total_pass=$((total_pass + 1))
        else
            print_task_fail
            total_fail=$((total_fail + 1))
        fi

        # Check 4: nginx config exists
        print_task "Nginx config (${STREAM_CONF_DIR}/${lb_name}.conf)..."
        if [[ -f "${STREAM_CONF_DIR}/${lb_name}.conf" ]]; then
            print_task_done
            total_pass=$((total_pass + 1))
        else
            print_task_fail
            total_fail=$((total_fail + 1))
        fi

        # Check 5: Port reachable (IPv4)
        if command -v nc &>/dev/null; then
            print_task "Port reachable (${ipv4}:${port})..."
            if nc -z -w 2 "$ipv4" "$port" &>/dev/null; then
                print_task_done
                total_pass=$((total_pass + 1))
            else
                print_task_fail
                total_fail=$((total_fail + 1))
            fi

            # Check 6: Port reachable (IPv6)
            print_task "Port reachable ([${ipv6}]:${port})..."
            if nc -z -w 2 "$ipv6" "$port" &>/dev/null; then
                print_task_done
                total_pass=$((total_pass + 1))
            else
                print_task_fail
                total_fail=$((total_fail + 1))
            fi
        fi

        # Check 7: Backend reachability
        local backends
        backends=$(echo "$lb_json" | jq -r '.backends[]')
        local target_port
        target_port=$(echo "$lb_json" | jq -r '.target_port')

        while IFS= read -r backend; do
            if command -v nc &>/dev/null; then
                print_task "Backend ${backend}.${DOMAIN}:${target_port}..."
                if nc -z -w 2 "${backend}.${DOMAIN}" "$target_port" &>/dev/null; then
                    print_task_done
                    total_pass=$((total_pass + 1))
                else
                    print_task_fail
                    total_fail=$((total_fail + 1))
                fi
            fi
        done <<< "$backends"
    done

    if [[ "$total_fail" -eq 0 ]]; then
        print_success "All checks passed (${total_pass}/${total_pass})"
    else
        print_warning "Checks: ${total_pass} passed, ${total_fail} failed"
    fi
}

# ====== SUBCOMMAND: RESTORE ======
fn_restore() {
    local count
    count=$(fn_get_lb_count)

    if [[ "$count" -eq 0 ]]; then
        return 0
    fi

    print_info "Restoring ${count} load balancer(s)..."

    local needs_reload=false

    while IFS= read -r lb_name; do
        local lb_json
        lb_json=$(fn_get_lb "$lb_name")
        local ipv4 ipv6 port target_port algorithm interface backends
        ipv4=$(echo "$lb_json" | jq -r '.ipv4')
        ipv6=$(echo "$lb_json" | jq -r '.ipv6')
        port=$(echo "$lb_json" | jq -r '.port')
        target_port=$(echo "$lb_json" | jq -r '.target_port')
        algorithm=$(echo "$lb_json" | jq -r '.algorithm')
        interface=$(echo "$lb_json" | jq -r '.interface')
        backends=$(echo "$lb_json" | jq -r '.backends | join(",")')

        # Restore secondary IPs (idempotent)
        fn_add_secondary_ip "$ipv4" "$ipv6" "$interface"

        # Ensure nginx config exists
        if [[ ! -f "${STREAM_CONF_DIR}/${lb_name}.conf" ]]; then
            fn_generate_nginx_config "$lb_name" "$port" "$target_port" "$algorithm" "$ipv4" "$ipv6" "$backends"
            needs_reload=true
        fi
    done < <(jq -r '.load_balancers[].name' "$LB_REGISTRY")

    # Reload nginx once if any configs were regenerated
    if $needs_reload; then
        fn_validate_nginx
        fn_reload_nginx
    fi

    print_success "All load balancers restored."
}

# ====== INTERACTIVE MENU ======
fn_interactive_menu() {
    while true; do
        print_cyan "=== tux2lab Load Balancer Manager ==="
        echo "  1) Create a new load balancer"
        echo "  2) Delete a load balancer"
        echo "  3) Update a load balancer"
        echo "  4) List all load balancers"
        echo "  5) Show load balancer status"
        echo "  6) Restore load balancer IPs"
        echo "  q) Quit"
        local choice
        read -rp "Select [1-6/q]: " choice
        case "$choice" in
            1) fn_create ;;
            2) fn_delete ;;
            3) fn_update ;;
            4) fn_list ;;
            5) fn_status ;;
            6) fn_restore ;;
            q|Q) exit 0 ;;
            *) print_error "Invalid selection." ;;
        esac
    done
}

# ====== HELP ======
fn_show_help() {
    print_cyan "tux2lab Load Balancer Manager

USAGE:
    lbmanager.sh <command> [options]

COMMANDS:
    create      Create a new TCP load balancer
    delete      Delete an existing load balancer
    update      Update backends, ports, or algorithm
    list        List all configured load balancers
    status      Check health of load balancers
    restore     Re-apply secondary IPs from registry

OPTIONS (create):
    --name           Load balancer name (DNS hostname)
    --port           Listen port (frontend)
    --target-port    Backend server port
    --backends       Comma-separated backend hostnames
    --algorithm      Load balancing algorithm: round-robin (default), least-conn, ip-hash
    -y, --yes        Skip interactive prompts

OPTIONS (delete):
    --name           Load balancer name
    -y, --yes        Skip confirmation prompt

OPTIONS (update):
    --name           Load balancer name
    --add-backend    Add backend(s), comma-separated
    --remove-backend Remove backend(s), comma-separated
    --port           Change listen port
    --target-port    Change target port
    --algorithm      Change algorithm

OPTIONS (status):
    --name           Check specific load balancer (default: all)

EXAMPLES:
    lbmanager.sh create --name k8s-api --port 6443 --target-port 6443 \\
        --backends k8s-cp1,k8s-cp2,k8s-cp3 --algorithm least-conn

    lbmanager.sh update --name k8s-api --add-backend k8s-cp4

    lbmanager.sh delete --name k8s-api -y

    lbmanager.sh list

    lbmanager.sh status --name k8s-api

Run without arguments for an interactive menu."
}

# ====== MAIN DISPATCH ======
case "${1:-}" in
    create)  shift; fn_create "$@" ;;
    delete)  shift; fn_delete "$@" ;;
    update)  shift; fn_update "$@" ;;
    list)    shift; fn_list "$@" ;;
    status)  shift; fn_status "$@" ;;
    restore) shift; fn_restore "$@" ;;
    -h|--help) fn_show_help ;;
    "")      fn_interactive_menu ;;
    *)       print_error "Unknown command: $1"; fn_show_help; exit 1 ;;
esac
