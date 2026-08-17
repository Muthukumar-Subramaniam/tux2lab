#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#

source /tux2lab/common-utils/color-functions.sh

# Read lab environment from JSON (v2.0.0)
readonly LAB_ENV_JSON="/tux2lab-data/lab-config/lab_environment.json"
if [[ -f "${LAB_ENV_JSON}" ]]; then
    dnsbinder_domain=$(jq -r '.lab.domain' "${LAB_ENV_JSON}")
    dnsbinder_server_ipv4_address=$(jq -r '.network.ipv4.address' "${LAB_ENV_JSON}")
    dnsbinder_server_ipv6_address=$(jq -r '.network.ipv6.address' "${LAB_ENV_JSON}")
    dnsbinder_server_fqdn=$(jq -r '.lab.engine_fqdn' "${LAB_ENV_JSON}")
    dnsbinder_server_short_name=$(jq -r '.lab.engine_hostname' "${LAB_ENV_JSON}")
    dnsbinder_gateway=$(jq -r '.network.ipv4.gateway' "${LAB_ENV_JSON}")
    dnsbinder_network_cidr=$(jq -r '.network.ipv4.cidr' "${LAB_ENV_JSON}")
    dnsbinder_cidr_prefix=$(jq -r '.network.ipv4.prefix' "${LAB_ENV_JSON}")
    dnsbinder_netmask=$(jq -r '.network.ipv4.netmask' "${LAB_ENV_JSON}")
    dnsbinder_broadcast=$(jq -r '.network.ipv4.broadcast' "${LAB_ENV_JSON}")
    dnsbinder_first24_subnet=$(jq -r '.network.ipv4.first24_subnet' "${LAB_ENV_JSON}")
    dnsbinder_last24_subnet=$(jq -r '.network.ipv4.last24_subnet' "${LAB_ENV_JSON}")
    dnsbinder_ipv6_gateway=$(jq -r '.network.ipv6.gateway' "${LAB_ENV_JSON}")
    dnsbinder_ipv6_prefix=$(jq -r '.network.ipv6.prefix' "${LAB_ENV_JSON}")
    dnsbinder_ipv6_ula_subnet=$(jq -r '.network.ipv6.ula_subnet' "${LAB_ENV_JSON}")
fi

if [[ "${UID}" -ne 0 ]]
then
    print_error "Run with sudo or run from root account ! "
    exit 1
fi


v_tmp_file_dnsbinder="$(mktemp /tmp/dnsbinder.XXXXXXXXXX)"

v_domain_name=$(if [[ -f /tux2lab-data/named/named.conf ]];then awk '/zones-are-managed-by-dnsbinder/ {print $2}' /tux2lab-data/named/named.conf;fi)
dnsbinder_network=$(if [[ -f /tux2lab-data/named/named.conf ]];then awk '/dnsbinder-network/ {print $3}' /tux2lab-data/named/named.conf;fi)
var_zone_dir='/tux2lab-data/named/dnsbinder-managed-zone-files'
v_fw_zone="${var_zone_dir}/${v_domain_name}-forward.db"

#--- File Locking Mechanism (mkdir-based spinlock with PID tracking) ---#

dnsbinder_lock_dir="/tux2lab-data/.dnsbinder-zone.lock"
zone_lock_acquired=false

fn_acquire_zone_lock() {
    local retries=400
    local existing_pid=""

    while ! mkdir "${dnsbinder_lock_dir}" 2>/dev/null; do
        if [[ -f "${dnsbinder_lock_dir}/pid" ]]; then
            existing_pid=$(cat "${dnsbinder_lock_dir}/pid" 2>/dev/null)
            if [[ -n "${existing_pid}" ]] && ! kill -0 "${existing_pid}" 2>/dev/null; then
                rm -f "${dnsbinder_lock_dir}/pid"
                rmdir "${dnsbinder_lock_dir}" 2>/dev/null || true
                continue
            fi
        fi

        sleep 0.05
        retries=$((retries - 1))
        if [[ "${retries}" -le 0 ]]; then
            print_error "Unable to acquire dnsbinder zone lock. Another instance may be running. Please retry."
            return 1
        fi
    done

    printf '%s\n' "$$" > "${dnsbinder_lock_dir}/pid"
    zone_lock_acquired=true
}

fn_release_zone_lock() {
    local lock_pid=""
    if ! $zone_lock_acquired; then return; fi
    if [[ -f "${dnsbinder_lock_dir}/pid" ]]; then
        lock_pid=$(cat "${dnsbinder_lock_dir}/pid" 2>/dev/null)
    fi
    if [[ -d "${dnsbinder_lock_dir}" ]] && [[ "${lock_pid}" = "$$" ]]; then
        rm -f "${dnsbinder_lock_dir}/pid"
        rmdir "${dnsbinder_lock_dir}" 2>/dev/null || true
    fi
    zone_lock_acquired=false
}

fn_release_all_locks() {
    fn_release_zone_lock
}

trap 'fn_release_all_locks' EXIT
trap 'fn_release_all_locks; trap - INT; kill -s INT $$' INT
trap 'fn_release_all_locks; trap - TERM; kill -s TERM $$' TERM
trap 'fn_release_all_locks; trap - HUP; kill -s HUP $$' HUP
trap 'fn_release_all_locks; trap - QUIT; kill -s QUIT $$' QUIT

#--- End of File Locking Mechanism ---#

#--- IPv6 Helper Functions (pure bash, no python) ---#

# Expand an IPv6 address to full 8-group colon-hex form
fn_expand_ipv6() {
    local addr="$1"
    local left="" right="" zeros="" i
    if [[ "$addr" == *"::"* ]]; then
        left="${addr%%::*}"; right="${addr#*::}"
        local lc=0 rc=0
        [[ -n "$left" ]] && lc=$(( $(echo "$left" | tr -cd ':' | wc -c) + 1 ))
        [[ -n "$right" ]] && rc=$(( $(echo "$right" | tr -cd ':' | wc -c) + 1 ))
        local missing=$(( 8 - lc - rc ))
        for ((i=0; i<missing; i++)); do
            [[ -n "$zeros" ]] && zeros="${zeros}:"
            zeros="${zeros}0000"
        done
        [[ -n "$left" && -n "$zeros" ]] && addr="${left}:${zeros}" || addr="${left}${zeros}"
        [[ -n "$right" ]] && addr="${addr}:${right}"
    fi
    local result=""
    IFS=':' read -ra groups <<< "$addr"
    for g in "${groups[@]}"; do
        [[ -n "$result" ]] && result="${result}:"
        result="${result}$(printf "%04x" "0x${g}")"
    done
    echo "$result"
}

# Extract /64 prefix (first 4 groups) from an IPv6 address
fn_ipv6_prefix() {
    local expanded
    expanded=$(fn_expand_ipv6 "$1")
    IFS=':' read -ra g <<< "$expanded"
    echo "${g[0]}:${g[1]}:${g[2]}:${g[3]}"
}

# Get the host-part offset (last 64 bits) as a decimal integer
fn_ipv6_host_offset() {
    local expanded
    expanded=$(fn_expand_ipv6 "$1")
    IFS=':' read -ra g <<< "$expanded"
    printf "%d" "0x${g[4]}${g[5]}${g[6]}${g[7]}"
}

# Convert IPv6 address to nibble-reversed PTR format (host part only, for /64 zones)
fn_ipv6_to_nibbles() {
    local expanded
    expanded=$(fn_expand_ipv6 "$1")
    IFS=':' read -ra g <<< "$expanded"
    local host_hex="${g[4]}${g[5]}${g[6]}${g[7]}"
    echo "$host_hex" | rev | sed 's/./&./g; s/\.$//'
}

# Find AAAA sorted insertion point by IPv6 offset (single awk pass, no subshells)
fn_find_aaaa_insert_after() {
    local new_offset="$1" zone_file="$2"
    awk -v new_off="$new_offset" '
        function hex2dec(h,    i,c,d) {
            d=0; h=tolower(h)
            for (i=1; i<=length(h); i++) { c=substr(h,i,1); d=d*16+index("0123456789abcdef",c)-1 }
            return d
        }
        BEGIN { result=";AAAA-Records (IPv6)"; in_section=0 }
        /;AAAA-Records \(IPv6\)/ { in_section=1; next }
        /;CNAME-Records/ { in_section=0 }
        in_section && /IN AAAA/ {
            addr=$NF
            # Extract host offset from address
            if (index(addr,"::")) {
                split(addr, ab, "::")
                hex_part=ab[2]; gsub(/:/, "", hex_part)
            } else {
                n=split(addr, g, ":"); hex_part=g[5] g[6] g[7] g[8]
            }
            offset=hex2dec(hex_part)
            if (offset < new_off) result=$1
        }
        END { print result }
    ' "$zone_file"
}

# Find IPv6 PTR sorted insertion point by nibble string comparison (single awk pass)
fn_find_ptr_insert_after() {
    local new_ptr="$1" zone_file="$2"
    if [[ ! -f "$zone_file" ]]; then echo ";IPv6 PTR-Records"; return; fi
    awk -v new_ptr="$new_ptr" '
        BEGIN { result=";IPv6 PTR-Records"; in_section=0 }
        /;IPv6 PTR-Records/ { in_section=1; next }
        in_section && /IN PTR/ {
            if ($1 < new_ptr) result=$1
        }
        END { print result }
    ' "$zone_file"
}

# Check if IPv4 address belongs to a CIDR network
fn_ipv4_in_network() {
    local ip="$1" cidr="$2"
    local network_base="${cidr%/*}" mask="${cidr#*/}"
    IFS=. read -r a1 a2 a3 a4 <<< "$ip"
    IFS=. read -r n1 n2 n3 n4 <<< "$network_base"
    local ip_dec=$(( (a1 << 24) + (a2 << 16) + (a3 << 8) + a4 ))
    local net_dec=$(( (n1 << 24) + (n2 << 16) + (n3 << 8) + n4 ))
    local range_size=$(( 32 - mask ))
    local net_start=$(( net_dec & (0xFFFFFFFF << range_size) ))
    local net_end=$(( net_start | ((1 << range_size) - 1) ))
    if (( ip_dec >= net_start && ip_dec <= net_end )); then echo "True"; else echo "False"; fi
}

# Check if IPv6 address belongs to a network (works for /16-aligned prefix lengths)
fn_ipv6_in_network() {
    local ip="$1" cidr="$2"
    local network_base="${cidr%/*}" mask="${cidr#*/}"
    local ip_exp net_exp
    ip_exp=$(fn_expand_ipv6 "$ip")
    net_exp=$(fn_expand_ipv6 "$network_base")
    local groups_to_compare=$(( mask / 16 ))
    IFS=':' read -ra ig <<< "$ip_exp"
    IFS=':' read -ra ng <<< "$net_exp"
    for ((i=0; i<groups_to_compare; i++)); do
        [[ "${ig[$i]}" != "${ng[$i]}" ]] && { echo "False"; return; }
    done
    echo "True"
}

#--- End of IPv6 Helper Functions ---#

fn_check_existence_of_domain() {
    if [[ -z "${v_domain_name}" ]]
    then
        print_error "> Seems like bind dns service is not being handled by dnsbinder! "
        print_info "> Please check and setup the same using dnsbinder utility itself! "
        exit 1
    fi
}

fn_calculate_network_cidr() {
    local ipv4_address="${1}"
    local subnet_mask="${2}"

    IFS=. read -r ipv4_octet1 ipv4_octet2 ipv4_octet3 ipv4_octet4 <<< "${ipv4_address}"
    IFS=. read -r mask_octet1 mask_octet2 mask_octet3 mask_octet4 <<< "${subnet_mask}"

    # Perform bitwise AND operation using arithmetic expansion
    local network_octet1=$((ipv4_octet1 & mask_octet1))
    local network_octet2=$((ipv4_octet2 & mask_octet2))
    local network_octet3=$((ipv4_octet3 & mask_octet3))
    local network_octet4=$((ipv4_octet4 & mask_octet4))

    local network_cidr=0
    for octet in ${mask_octet1} ${mask_octet2} ${mask_octet3} ${mask_octet4}; do
        for bit in {7..0}; do
            if (( (octet >> bit) & 1 )); then
                ((network_cidr++))
            fi
        done
    done

    echo "${network_octet1}.${network_octet2}.${network_octet3}.${network_octet4}/${network_cidr}"
}

fn_cidr_prefix_to_netmask() {
    local cidr_prefix=$1
    
    local binary_mask=$(printf '%*s' "$cidr_prefix" '' | tr ' ' '1')
    binary_mask=$(printf '%-32s' "$binary_mask" | tr ' ' '0')

    dnsbinder_netmask=""
    for i in {0..3}; do
        local octet_decimal=$((2#${binary_mask:$((i * 8)):8}))
        dnsbinder_netmask+=$octet_decimal
        [[ $i -lt 3 ]] && dnsbinder_netmask+=.
    done
}

fn_calculate_ipv6_network() {
    local ipv6_address="${1}"
    local prefix_length="${2}"
    
    # Expand IPv6 address to full form (handle :: compression)
    local addr="${ipv6_address}"
    
    # Count existing colons
    local colon_count=$(echo "${addr}" | tr -cd ':' | wc -c)
    
    # Handle :: expansion
    if [[ "${addr}" == *"::"* ]]; then
        local missing_groups=$((7 - colon_count + 1))
        local replacement=":"
        for ((i=0; i<missing_groups; i++)); do
            replacement+=":0"
        done
        addr="${addr/::/${replacement}:}"
    fi
    
    # Handle leading/trailing colons after expansion
    addr="${addr#:}"
    addr="${addr%:}"
    
    # Split into groups and pad with zeros
    IFS=':' read -ra groups <<< "${addr}"
    local expanded=""
    for group in "${groups[@]}"; do
        expanded+=$(printf "%04x" $((16#${group:-0})))
    done
    
    # Calculate how many hex digits to keep (4 bits per hex digit)
    local hex_digits_to_keep=$((prefix_length / 4))
    local remaining_bits=$((prefix_length % 4))
    
    # Extract network portion
    local network_hex="${expanded:0:$hex_digits_to_keep}"
    
    # Handle remaining bits if prefix is not a multiple of 4
    if [[ $remaining_bits -gt 0 ]]; then
        local next_hex_char="${expanded:$hex_digits_to_keep:1}"
        local next_value=$((16#${next_hex_char:-0}))
        # Create mask for remaining bits (e.g., 3 bits = 1110 = 0xe)
        local mask=$(( (0xf << (4 - remaining_bits)) & 0xf ))
        local masked_value=$((next_value & mask))
        network_hex+=$(printf "%x" $masked_value)
    fi
    
    # Pad with zeros to get full 32 hex digits
    network_hex=$(printf "%-32s" "$network_hex" | tr ' ' '0')
    
    # Format as IPv6 (insert colons every 4 chars)
    local formatted=""
    for ((i=0; i<32; i+=4)); do
        formatted+="${network_hex:$i:4}"
        [[ $i -lt 28 ]] && formatted+=":"
    done
    
    # Compress consecutive zeros (find longest run of :0000: groups)
    local compressed="${formatted}"
    # Replace leading zeros in each group
    compressed=$(echo "${compressed}" | sed 's/:0\{1,3\}\([0-9a-f]\)/:\1/g; s/^0\{1,3\}\([0-9a-f]\)/\1/')
    # Replace longest sequence of :0: with ::
    compressed=$(echo "${compressed}" | sed 's/\(:\(0:\)\{2,\}\)/::/' | sed 's/^0::/::/' | sed 's/::0$/::/')
    
    echo "${compressed}"
}

fn_split_network_into_cidr24subnets() {

    v_network_and_cidr="${1}"

    # Function to convert an IP address to a number
    fn_ip_to_int() {
        local ipv4_address=${1}
        local ipv4_octet1 ipv4_octet2 ipv4_octet3 ipv4_octet4
        IFS=. read -r ipv4_octet1 ipv4_octet2 ipv4_octet3 ipv4_octet4 <<< "${ipv4_address}"
        echo "$((ipv4_octet1 * 256 ** 3 + ipv4_octet2 * 256 ** 2 + ipv4_octet3 * 256 + ipv4_octet4))"
    }
    
    # Function to convert a number back to an IP address
    fn_int_to_ip() {
        local int=${1}
        echo "$((int >> 24 & 255)).$((int >> 16 & 255)).$((int >> 8 & 255)).$((int & 255))"
    }
    
    # Function to generate /24 subnets within a given network
    fn_generate_subnets() {
        local v_network=${1}
        local v_cidr=${2}
    
        # Convert network address to an integer
        local v_network_int
        v_network_int=$(fn_ip_to_int "${v_network}")
    
        # Calculate the number of subnets to generate
        local v_subnet_count
        v_subnet_count=$(( 2 ** (32 - v_cidr) / 256 ))
    
        # Generate subnets
        for ((i = 0; i < v_subnet_count; i++)); do
            local v_subnet_int=$(( v_network_int + i * 256 ))
            local v_subnet
            v_subnet=$(fn_int_to_ip "${v_subnet_int}")
            echo "${v_subnet}/24"
        done
    }

    if [[ -z "${v_network_and_cidr}" ]];
    then
        v_network_and_cidr=$(ip r | awk -v iface="${v_primary_interface}" '!/default/ && $0 ~ iface {print $1; exit}')
    fi

    # Extract network and CIDR from input
    v_network="${v_network_and_cidr%/*}"
    v_cidr="${v_network_and_cidr#*/}"

    fn_cidr_prefix_to_netmask "${v_cidr}"
    
    # Check if CIDR is valid
    if ! [[ "${v_cidr}" =~ ^[0-9]+$ ]] || [[ "${v_cidr}" -lt 16 ]] || [[ "${v_cidr}" -gt 24 ]]; then
        print_error "Invalid CIDR. Only Networks with CIDR between 16 and 24 is allowed ! "
        exit 1
    fi
    
    # Generate and display the subnets
    v_splited_subnets=$(fn_generate_subnets "${v_network}" "${v_cidr}" |  sed "s/\.0\/24//")
}

if [[ -n "${dnsbinder_network}" ]]; then
    v_splited_subnets=$(ls "${var_zone_dir}"/*-reverse.db 2>/dev/null | awk -F'/' '!/ipv6-reverse\.db$/ {split($NF,a,"."); print a[1]"."a[2]"."a[3]}' | sort -n)
    v_total_ptr_zones=$(ls "${var_zone_dir}"/*-reverse.db 2>/dev/null | grep -vc "ipv6-reverse.db" || true)
    v_total_ptr_zones=${v_total_ptr_zones:-0}

    v_zone_number=1
    for v_subnet_part in ${v_splited_subnets}
    do
        eval "v_ptr_zone${v_zone_number}=\"${var_zone_dir}/${v_subnet_part}.${v_domain_name}-reverse.db\""
        eval "v_subnet${v_zone_number}=\"${v_subnet_part}\""
        ((v_zone_number++))
    done
fi

fn_instruct_on_valid_domain_name() {
print_warning "
Domain Name Rules:
─────────────────────────────
    Only allowed TLD:          internal
    Max subdomains allowed:    2
    Allowed characters:        Letters (a-z), digits (0-9), and hyphens (-)
    Hyphens:                   Cannot be at the start or end of subdomains
    Total length:              Must be between 1 and 63 characters

Examples of valid domain names:
    test.internal
    test.example.internal
    123-example.internal
    test-lab1.internal
"
}

fn_reconfigure_named() {
    local named_conf="/tux2lab-data/named/named.conf"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local template_file="${script_dir}/named.conf.template"

    if [[ ! -f "$named_conf" ]]; then
        print_error "No existing named.conf found. Run 'dnsbinder --setup' first."
        exit 1
    fi

    if [[ ! -f "$template_file" ]]; then
        print_error "Template file not found: ${template_file}"
        exit 1
    fi

    # Extract the zone block from existing named.conf
    local zone_block
    zone_block=$(sed -n '/^# BEGIN zones-of-/,/^# END zones-of-/p' "$named_conf")
    if [[ -z "$zone_block" ]]; then
        print_error "Could not find zone block in existing named.conf."
        exit 1
    fi

    local listen_ipv4="${dnsbinder_server_ipv4_address}"
    local listen_ipv6="${dnsbinder_server_ipv6_address:-none}"
    local allow_networks="localhost; ${dnsbinder_network_cidr}"
    if [[ -n "${dnsbinder_ipv6_ula_subnet:-}" ]]; then
        allow_networks="${allow_networks}; ${dnsbinder_ipv6_ula_subnet}"
    fi

    print_task "Regenerating named.conf from template..."
    if [[ "$listen_ipv6" != "none" ]]; then
        sed -e "s|LISTEN_IPV4_ADDRESSES|${listen_ipv4}|g" \
            -e "s|LISTEN_IPV6_ADDRESSES|${listen_ipv6}|g" \
            -e "s|ALLOW_QUERY_NETWORKS|${allow_networks}|g" \
            -e "s|ALLOW_RECURSION_NETWORKS|${allow_networks}|g" \
            "$template_file" > "$named_conf"
    else
        sed -e "s|LISTEN_IPV4_ADDRESSES|${listen_ipv4}|g" \
            -e "/listen-on-v6 port 53/d" \
            -e "s|ALLOW_QUERY_NETWORKS|${allow_networks}|g" \
            -e "s|ALLOW_RECURSION_NETWORKS|${allow_networks}|g" \
            "$template_file" > "$named_conf"
    fi

    # Re-append zone block
    echo "$zone_block" >> "$named_conf"
    print_task_done

    print_success "named.conf regenerated from template. Zone files untouched."
}

fn_update_record_ttl() {
    local hostname="${1:-}"
    local new_ttl="${2:-}"
    v_if_autorun_false=true

    if [[ -z "$hostname" ]]; then
        read -rp "Enter hostname to update TTL for: " hostname
    fi
    if [[ -z "$new_ttl" ]]; then
        read -rp "Enter new TTL value (seconds): " new_ttl
    fi

    # Validate TTL is numeric
    if ! [[ "$new_ttl" =~ ^[0-9]+$ ]]; then
        print_error "TTL must be a positive integer (seconds)."
        return 1
    fi

    # Strip domain if FQDN provided
    hostname="${hostname%.${v_domain_name}}"

    # Check record exists
    if ! grep -q "^${hostname} " "${v_fw_zone}"; then
        print_error "No record found for '${hostname}.${v_domain_name}'."
        return 1
    fi

    local escaped_host=$(printf '%s' "$hostname" | sed 's/[.[\*^$/]/\\&/g')

    # Update A record TTL
    if grep -q "^${hostname} .*IN A " "${v_fw_zone}"; then
        sed -i "s/^\(${escaped_host}\s\+\)\([0-9]\+\s\+\)\?IN A /\1${new_ttl} IN A /" "${v_fw_zone}"
        print_task "Updated TTL for A record of ${hostname}.${v_domain_name}..."
        print_task_done
    fi

    # Update AAAA record TTL
    if grep -q "^${hostname} .*IN AAAA" "${v_fw_zone}"; then
        sed -i "s/^\(${escaped_host}\s\+\)\([0-9]\+\s\+\)\?IN AAAA /\1${new_ttl} IN AAAA /" "${v_fw_zone}"
        print_task "Updated TTL for AAAA record of ${hostname}.${v_domain_name}..."
        print_task_done
    fi

    # Update CNAME record TTL
    if grep -q "^${hostname} .*IN CNAME" "${v_fw_zone}"; then
        sed -i "s/^\(${escaped_host}\s\+\)\([0-9]\+\s\+\)\?IN CNAME /\1${new_ttl} IN CNAME /" "${v_fw_zone}"
        print_task "Updated TTL for CNAME record of ${hostname}.${v_domain_name}..."
        print_task_done
    fi

    # Update PTR records
    local ipv4
    ipv4=$(awk -v host="^${hostname} " '$0 ~ host && /IN A / {print $NF}' "${v_fw_zone}")
    if [[ -n "$ipv4" ]]; then
        local host_octet="${ipv4##*.}"
        local ptr_zone
        ptr_zone=$(find "${var_zone_dir}" -name "*-reverse.db" ! -name "*ipv6*" -exec grep -l "^${host_octet} .*IN PTR.*${hostname}" {} \; 2>/dev/null | head -1)
        if [[ -n "$ptr_zone" ]]; then
            sed -i "s/^\(${host_octet}\s\+\)\([0-9]\+\s\+\)\?IN PTR /\1${new_ttl} IN PTR /" "$ptr_zone"
            print_task "Updated TTL for PTR record..."
            print_task_done
        fi
    fi

    # Update IPv6 PTR record
    local ipv6
    ipv6=$(awk -v host="^${hostname} " '$0 ~ host && /IN AAAA/ {print $NF}' "${v_fw_zone}")
    if [[ -n "$ipv6" ]]; then
        local ipv6_zone="${var_zone_dir}/${v_domain_name}-ipv6-reverse.db"
        if [[ -f "$ipv6_zone" ]]; then
            local nibbles
            nibbles=$(fn_ipv6_to_nibbles "$ipv6")
            if grep -q "^${nibbles} " "$ipv6_zone"; then
                local escaped_nib=$(printf '%s' "$nibbles" | sed 's/[.[\*^$/]/\\&/g')
                sed -i "s/^\(${escaped_nib}\s\+\)\([0-9]\+\s\+\)\?IN PTR /\1${new_ttl} IN PTR /" "$ipv6_zone"
                print_task "Updated TTL for IPv6 PTR record..."
                print_task_done
            fi
        fi
    fi

    # Set v_ptr_zone for serial update (needed by fn_update_serial_number_of_zones)
    if [[ -n "$ipv4" ]]; then
        IFS=. read -r _o1 _o2 _o3 _o4 <<< "$ipv4"
        v_ptr_zone="${var_zone_dir}/${_o1}.${_o2}.${_o3}.${v_domain_name}-reverse.db"
        fn_update_serial_number_of_zones
    else
        fn_update_serial_number_of_zones
    fi

    print_task "Reloading DNS..."
    sudo podman exec tux2lab-engine rndc reload &>/dev/null && print_task_done || print_task_fail

    print_success "TTL updated to ${new_ttl} seconds for ${hostname}.${v_domain_name}"
}

fn_create_ipv6_only_record() {
    local hostname="${1:-}"
    local auto_mode="${2:-}"

    if [[ -z "$hostname" && "$auto_mode" != "Automated-Execution" ]]; then
        read -rp "Enter hostname for IPv6-only record: " hostname
    fi

    if [[ -z "$hostname" ]]; then
        print_error "Hostname is required."
        return 1
    fi

    # Strip domain if FQDN provided
    hostname="${hostname%.${v_domain_name}}"

    if [[ "$auto_mode" != "Automated-Execution" ]]; then
        if ! fn_acquire_zone_lock; then return 1; fi
    fi

    # Check if record already exists
    if grep -q "^${hostname} " "${v_fw_zone}"; then
        if [[ "$auto_mode" != "Automated-Execution" ]]; then
            print_error "Record '${hostname}.${v_domain_name}' already exists."
            fn_release_zone_lock
        fi
        return 8
    fi

    # Find next available IPv6 offset >= 1023 (0x3ff)
    local ipv6_prefix_base
    ipv6_prefix_base=$(fn_ipv6_prefix "${dnsbinder_ipv6_gateway}")

    local next_offset=1023
    local existing_offsets
    existing_offsets=$(awk '
        function hex2dec(h,    i,c,d) {
            d=0; h=tolower(h)
            for (i=1; i<=length(h); i++) { c=substr(h,i,1); d=d*16+index("0123456789abcdef",c)-1 }
            return d
        }
        /IN AAAA/ {
            addr=$NF
            if (index(addr,"::")) { split(addr,ab,"::"); hex_part=ab[2]; gsub(/:/,"",hex_part) }
            else { n=split(addr,g,":"); hex_part=g[5] g[6] g[7] g[8] }
            offset=hex2dec(hex_part)
            if (offset >= 1023) print offset
        }
    ' "${v_fw_zone}" | sort -n)

    if [[ -n "$existing_offsets" ]]; then
        local max_offset
        max_offset=$(echo "$existing_offsets" | tail -1)
        next_offset=$((max_offset + 1))
        # Guard against bash 63-bit integer overflow
        if [[ $next_offset -lt 0 ]]; then
            if [[ "$auto_mode" != "Automated-Execution" ]]; then
                print_error "IPv6-only address space exhausted!"
                fn_release_zone_lock
            fi
            return 255
        fi
        [[ $next_offset -lt 1023 ]] && next_offset=1023
    fi

    local offset_hex=$(printf "%x" $next_offset)
    local v_ipv6_address="${ipv6_prefix_base}::${offset_hex}"

    if [[ "$auto_mode" != "Automated-Execution" ]]; then
        print_task "Creating IPv6-only host record ${hostname}.${v_domain_name}..."
    fi

    # AAAA record
    local v_host_record_adjusted_space=$(printf "%-*s" 63 "${hostname}")
    local ttl_field=""
    [[ -n "${record_ttl}" ]] && ttl_field="${record_ttl} "
    local v_add_ipv6_record="${v_host_record_adjusted_space} ${ttl_field}IN AAAA ${v_ipv6_address}"

    # Find insertion point
    local v_insert_after
    v_insert_after=$(fn_find_aaaa_insert_after "$next_offset" "${v_fw_zone}")

    if [[ "${v_insert_after}" == ";AAAA-Records (IPv6)" ]]; then
        sed -i "/^;AAAA-Records (IPv6)/a \\${v_add_ipv6_record}" "${v_fw_zone}"
    else
        sed -i "/^${v_insert_after} .*IN AAAA/a \\${v_add_ipv6_record}" "${v_fw_zone}"
    fi

    # IPv6 PTR record
    local v_ipv6_zone_file="${var_zone_dir}/${v_domain_name}-ipv6-reverse.db"
    local v_ipv6_ptr
    v_ipv6_ptr=$(fn_ipv6_to_nibbles "${v_ipv6_address}")

    if [[ -n "${v_ipv6_ptr}" ]] && [[ -f "${v_ipv6_zone_file}" ]]; then
        local v_add_ipv6_ptr="${v_ipv6_ptr} ${ttl_field}IN PTR ${hostname}.${v_domain_name}."

        local v_ptr_insert_after
        v_ptr_insert_after=$(fn_find_ptr_insert_after "${v_ipv6_ptr}" "${v_ipv6_zone_file}")

        if [[ "${v_ptr_insert_after}" == ";IPv6 PTR-Records" ]]; then
            sed -i "/^;IPv6 PTR-Records/a \\${v_add_ipv6_ptr}" "${v_ipv6_zone_file}"
        else
            local escaped_ptr=$(printf '%s' "$v_ptr_insert_after" | sed 's/[.[\*^$/]/\\&/g')
            sed -i "/^${escaped_ptr} .*IN PTR/a \\${v_add_ipv6_ptr}" "${v_ipv6_zone_file}"
        fi
    fi

    if [[ "$auto_mode" != "Automated-Execution" ]]; then
        print_task_done
        fn_update_serial_number_of_zones
        # Reload and validate
        print_task "Reloading DNS..."
        sudo podman exec tux2lab-engine rndc reload &>/dev/null && print_task_done || print_task_fail

        # Validate forward lookup
        print_task "Validating forward look up..."
        local retry_count=0 query_success=false
        while [[ ${retry_count} -lt 10 ]]; do
            if dig @"${dnsbinder_server_ipv4_address}" +short +time=1 +tries=1 AAAA ${hostname}.${v_domain_name} | grep -q ':'; then
                query_success=true
                break
            fi
            sleep 0.5
            ((retry_count++))
        done
        ${query_success} && print_task_done || print_task_fail

        # Validate reverse lookup
        print_task "Validating reverse look up..."
        if dig @"${dnsbinder_server_ipv4_address}" +short +time=1 +tries=1 -x "${v_ipv6_address}" | grep -q '.'; then
            print_task_done
        else
            print_task_fail
        fi

        # FYI output
        local display_ttl="${record_ttl:-3600 (default)}"
        print_info "FYI : ${hostname}.${v_domain_name}\n             ├── IPv6: ${v_ipv6_address}\n             └── TTL : ${display_ttl} seconds"
        print_success "Created IPv6-only host record ${hostname}.${v_domain_name}"

        fn_release_zone_lock
    fi

    return 0
}

fn_delete_ipv6_only_record() {
    local hostname="${1}"
    local auto_flag="${2:-}"

    hostname="${hostname%.${v_domain_name}}"

    local is_automated=false
    [[ "${auto_flag}" == "Automated-Execution" ]] && is_automated=true

    if ! $is_automated; then
        if ! fn_acquire_zone_lock; then return 1; fi
    fi

    if ! grep -q "^${hostname} .*IN AAAA" "${v_fw_zone}"; then
        $is_automated || print_error "No AAAA record found for '${hostname}.${v_domain_name}'."
        $is_automated || fn_release_zone_lock
        return 8
    fi

    local ipv6_addr
    ipv6_addr=$(awk -v host="^${hostname} " '$0 ~ host && /IN AAAA/ {print $NF}' "${v_fw_zone}")

    if ! $is_automated; then
        print_info "Match found for host record ${hostname}.${v_domain_name}\n             └── IPv6: ${ipv6_addr}"

        if [[ "$auto_flag" != "-y" ]]; then
            local confirm
            read -rp "Please confirm deletion of records (y/n) : " confirm
            if [[ "$confirm" != "y" ]]; then
                print_warning "Cancelled without any changes!"
                fn_release_zone_lock
                return 0
            fi
        fi

        print_task "Deleting IPv6-only host record ${hostname}.${v_domain_name}..."
    fi

    sed -i "/^${hostname} .*IN AAAA/d" "${v_fw_zone}"

    local v_ipv6_zone_file="${var_zone_dir}/${v_domain_name}-ipv6-reverse.db"
    if [[ -f "${v_ipv6_zone_file}" ]]; then
        sed -i "/IN PTR ${hostname}\.${v_domain_name}\./d" "${v_ipv6_zone_file}"
    fi

    if ! $is_automated; then
        print_task_done
        fn_update_serial_number_of_zones
        print_task "Reloading DNS..."
        sudo podman exec tux2lab-engine rndc reload &>/dev/null && print_task_done || print_task_fail
        print_success "Deleted IPv6-only host record ${hostname}.${v_domain_name}"
        fn_release_zone_lock
    fi
}

fn_configure_named_dns_server() {

    # Get the directory where dnsbinder script is located (resolve symlinks)
    v_script_path="${BASH_SOURCE[0]}"
    while [ -L "${v_script_path}" ]; do
        v_script_path="$(readlink -f "${v_script_path}")"
    done
    v_script_dir="$(cd "$(dirname "${v_script_path}")" && pwd)"

    if [[ -n "${v_domain_name}" ]]
    then
        print_error "> Seems like bind dns server and domain is already setup and managed by dnsbinder! "
        print_success "> Domain '${v_domain_name}' is already being managed by dnsbinder! "
        print_warning "> Nothing to do!  "
        exit
    fi

    if [[ -n "${1}" ]]; then
        v_given_domain="${1}"
    else
        fn_instruct_on_valid_domain_name
    fi

    while :
    do
        if [[ -z "${v_given_domain}" ]]; then
            read -p "Provide the preferred local domain : " v_given_domain 
        fi
            
        if [[ "${#v_given_domain}" -le 63 ]] && [[ "${v_given_domain}" =~ ^[[:alnum:]]+([-.][[:alnum:]]+)*(\.[[:alnum:]]+){0,2}\.internal$ ]]
        then
            break
        else
            v_given_domain=""
            fn_instruct_on_valid_domain_name
            continue
        fi
    done

    print_task "Fetching network information from the system..."

    # v2.0.0: Always read from lab_environment.json (no VM/host mode distinction)
    v_dns_host_short_name="${dnsbinder_server_short_name}"
    v_primary_interface='labbr0'
    v_primary_ip="${dnsbinder_server_ipv4_address}"

    if [[ -z "${v_primary_ip}" ]]; then
        print_error "Critical: IPv4 address not found in lab_environment.json."
        print_error "DNS server IP address is required."
        exit 1
    fi

    v_network_gateway="${dnsbinder_gateway}"
    v_ipv6_address="${dnsbinder_server_ipv6_address:-}"
    v_ipv6_gateway="${dnsbinder_ipv6_gateway:-}"
    v_ipv6_prefix="${dnsbinder_ipv6_prefix:-}"
    v_ipv6_ula_subnet="${dnsbinder_ipv6_ula_subnet:-}"

    # Verify dual-stack configuration is present
    if [[ -z "${v_ipv6_ula_subnet}" ]]; then
        print_error "IPv6 configuration not found. Dual-stack (IPv4+IPv6) is required."
        print_error "Please configure IPv6 on ${v_primary_interface} before running this script."
        exit 1
    fi

    fn_split_network_into_cidr24subnets

    print_task_done

    print_task "Configuring named.conf from template..."

    v_template_file="${v_script_dir}/named.conf.template"
    
    if [[ ! -f "${v_template_file}" ]]; then
        print_error "Template file not found: ${v_template_file}"
        exit 1
    fi

    # Prepare listen addresses (v2.0.0: bridge IP only — rndc uses port 953, not 53)
    v_listen_ipv4="${v_primary_ip}"

    if [[ -n "${v_ipv6_address}" ]]; then
        v_listen_ipv6="${v_ipv6_address}"
    else
        v_listen_ipv6="none"
    fi

    # Prepare allow-query and allow-recursion networks
    if [[ -n "${v_ipv6_address}" ]]; then
        v_allow_networks="localhost; ${v_network}/${v_cidr}; ${v_ipv6_ula_subnet}"
    else
        v_allow_networks="localhost; ${v_network}/${v_cidr}"
    fi

    # Generate named.conf from template
    if [[ -n "${v_ipv6_address}" ]]; then
        # IPv6 is available - configure it normally
        sed -e "s|LISTEN_IPV4_ADDRESSES|${v_listen_ipv4}|g" \
            -e "s|LISTEN_IPV6_ADDRESSES|${v_listen_ipv6}|g" \
            -e "s|ALLOW_QUERY_NETWORKS|${v_allow_networks}|g" \
            -e "s|ALLOW_RECURSION_NETWORKS|${v_allow_networks}|g" \
            "${v_template_file}" > /tux2lab-data/named/named.conf
    else
        # IPv6 not available - remove listen-on-v6 line entirely
        sed -e "s|LISTEN_IPV4_ADDRESSES|${v_listen_ipv4}|g" \
            -e "/listen-on-v6 port 53/d" \
            -e "s|ALLOW_QUERY_NETWORKS|${v_allow_networks}|g" \
            -e "s|ALLOW_RECURSION_NETWORKS|${v_allow_networks}|g" \
            "${v_template_file}" > /tux2lab-data/named/named.conf
    fi

    print_task_done

    print_task "Installing root hints file (named.root)..."
    cp "${v_script_dir}/named.root" /tux2lab-data/named/named.root
    chmod 644 /tux2lab-data/named/named.root
    print_task_done

    print_task "Adding DNS zones to named.conf..."


    tee -a /tux2lab-data/named/named.conf > /dev/null << EOF
# BEGIN zones-of-${v_given_domain}-domain
# dnsbinder-network ${v_network}/${v_cidr}$([[ -n "${v_ipv6_ula_subnet}" ]] && echo " ${v_ipv6_ula_subnet}")
# ${v_given_domain} zones-are-managed-by-dnsbinder
//Forward Zone for ${v_given_domain}
zone "${v_given_domain}" IN {
    type master;
    file "/tux2lab-data/named/dnsbinder-managed-zone-files/${v_given_domain}-forward.db";
    allow-update { none; };
};
//Reverse Zones
EOF
    
    for v_subnet_part in ${v_splited_subnets}
    do
        if [[ -z "${v_first_subnet_part}" ]]; then
            v_first_subnet_part="${v_subnet_part}"
        fi

        v_reverse_subnet_part=$(echo "${v_subnet_part}" | awk -F. '{print $3"."$2"."$1}')
        tee -a /tux2lab-data/named/named.conf > /dev/null << EOF
zone "${v_reverse_subnet_part}.in-addr.arpa" IN {
    type master;
    file "/tux2lab-data/named/dnsbinder-managed-zone-files/${v_subnet_part}.${v_given_domain}-reverse.db";
    allow-update { none; };
};
EOF
        v_last_subnet_part="${v_subnet_part}"
    done

    # Add IPv6 reverse zone if IPv6 is configured
    if [[ -n "${v_ipv6_ula_subnet}" ]]; then
        # Extract IPv6 prefix for reverse zone (e.g., fd28:2808:2020:3000::/64)
        # Convert to reverse DNS format
        v_ipv6_base=$(echo "${v_ipv6_ula_subnet}" | cut -d'/' -f1 | sed 's/::$//')
        # For fd28:2808:2020:3000::, reverse is 0.0.0.3.0.2.0.2.8.0.8.2.8.2.d.f.ip6.arpa
        v_ipv6_reverse_zone=$(echo "${v_ipv6_base}" | awk -F':' '{
            for(i=NF; i>=1; i--) {
                if($i != "") {
                    len=length($i)
                    for(j=len; j>=1; j--) {
                        printf "%s.", substr($i,j,1)
                    }
                }
            }
        }' | sed 's/\.$//')
        
        tee -a /tux2lab-data/named/named.conf > /dev/null << EOF
//IPv6 Reverse Zone
zone "${v_ipv6_reverse_zone}.ip6.arpa" IN {
    type master;
    file "/tux2lab-data/named/dnsbinder-managed-zone-files/${v_given_domain}-ipv6-reverse.db";
    allow-update { none; };
};
EOF
    fi

    echo -e "# END zones-of-${v_given_domain}-domain" | tee -a /tux2lab-data/named/named.conf > /dev/null

    print_task_done

    print_task "Creating and configuring zone files..."

    mkdir -p "${var_zone_dir}"

    fn_update_dns_server_data_to_zone_file() {
        v_file_name="${1}"
        local serial_number=$(date +%s)
        sed "s/DNS_HOST_SHORT_NAME/${v_dns_host_short_name}/g; s/DNS_DOMAIN/${v_given_domain}/g; s/0000000000/${serial_number}/g" \
            "${v_script_dir}/zone-header.template" >> "${v_file_name}"
    }

    v_zone_file_name="${var_zone_dir}/${v_given_domain}-forward.db"

    fn_update_dns_server_data_to_zone_file "${v_zone_file_name}"
    echo -e "\n;A-Records" | tee -a "${v_zone_file_name}" > /dev/null

    v_network_adjusted_space=$(printf "%-*s" 63 "network")

    echo -e "${v_network_adjusted_space} 86400 IN A ${v_first_subnet_part}.0" | tee -a  "${v_zone_file_name}" > /dev/null

    v_dns_host_short_name_adjusted_space=$(printf "%-*s" 63 "${v_dns_host_short_name}")
    
    echo -e "${v_dns_host_short_name_adjusted_space} 86400 IN A ${v_primary_ip}" | tee -a "${v_zone_file_name}" > /dev/null

    v_broadcast_adjusted_space=$(printf "%-*s" 63 "broadcast")

    echo -e "${v_broadcast_adjusted_space} 86400 IN A ${v_last_subnet_part}.255" | tee -a  "${v_zone_file_name}" > /dev/null

    # Add AAAA records for IPv6 (dual-stack)
    if [[ -n "${v_ipv6_address}" ]]; then
        echo -e "\n;AAAA-Records (IPv6)" | tee -a "${v_zone_file_name}" > /dev/null
        
        v_dns_host_short_name_adjusted_space=$(printf "%-*s" 63 "${v_dns_host_short_name}")
        echo -e "${v_dns_host_short_name_adjusted_space} 86400 IN AAAA ${v_ipv6_address}" | tee -a "${v_zone_file_name}" > /dev/null
    fi

    # Add CNAME aliases
    echo -e "\n;CNAME-Records" | tee -a "${v_zone_file_name}" > /dev/null
    v_gateway_cname_space=$(printf "%-*s" 63 "gateway")
    echo -e "${v_gateway_cname_space} 86400 IN CNAME ${v_dns_host_short_name}.${v_given_domain}." | tee -a "${v_zone_file_name}" > /dev/null

    for v_subnet_part in ${v_splited_subnets}
    do
        v_zone_file_name="${var_zone_dir}/${v_subnet_part}.${v_given_domain}-reverse.db"
        fn_update_dns_server_data_to_zone_file "${v_zone_file_name}"
        echo -e "\n;PTR-Records" | tee -a "${v_zone_file_name}" > /dev/null
        if [[ "${v_subnet_part}" == "${v_first_subnet_part}" ]]
        then
            echo -e "0   86400 IN PTR network.${v_given_domain}." | tee -a "${v_zone_file_name}" > /dev/null
            v_get_ip_part_primary_ip=$(echo "${v_primary_ip}" | awk -F. '{print $4}')
            v_ip_part_primary_ip_adjusted_space=$(printf "%-*s" 3 "${v_get_ip_part_primary_ip}")
            echo -e "${v_ip_part_primary_ip_adjusted_space} 86400 IN PTR ${v_dns_host_short_name}.${v_given_domain}." | tee -a "${v_zone_file_name}" > /dev/null
        elif [[ "${v_subnet_part}" == "${v_last_subnet_part}" ]]
        then
            echo -e "255 86400 IN PTR broadcast.${v_given_domain}." | tee -a "${v_zone_file_name}" > /dev/null
        fi
    done

    # Create IPv6 reverse zone file if IPv6 is configured
    if [[ -n "${v_ipv6_address}" && ! -z "${v_ipv6_ula_subnet}" ]]; then
        v_ipv6_zone_file="${var_zone_dir}/${v_given_domain}-ipv6-reverse.db"
        fn_update_dns_server_data_to_zone_file "${v_ipv6_zone_file}"
        echo -e "\n;IPv6 PTR-Records" | tee -a "${v_ipv6_zone_file}" > /dev/null
        
        v_ipv6_ptr=$(fn_ipv6_to_nibbles "${v_ipv6_address}")
        
        if [[ -n "${v_ipv6_ptr}" ]]; then
            echo -e "${v_ipv6_ptr} 86400 IN PTR ${v_dns_host_short_name}.${v_given_domain}." | tee -a "${v_ipv6_zone_file}" > /dev/null
        fi
    fi

    print_task_done

    chmod -R o+r "${var_zone_dir}"
    find "${var_zone_dir}" -type d -exec chmod o+x {} \;

    # Reload named only if container is running (not during initial deploy)
    if sudo podman ps --filter "name=tux2lab-engine" --format "{{.Names}}" 2>/dev/null | grep -q "tux2lab-engine"; then
        print_task "Reloading named DNS service in container..."
        sudo podman exec tux2lab-engine rndc reload &>/dev/null
        print_task_done
    fi

    # v2.0.0: No /etc/environment writes needed — lab_environment.json is source of truth
    # DNS resolution for the host is configured by deploy-lab.sh (resolvectl)

    # Display success message
    if [[ -n "${v_ipv6_address}" ]]; then
        print_success "DNS domain \"${v_given_domain}\" configured successfully.
  Server : ${v_dns_host_short_name}.${v_given_domain}
  IPv4   : ${v_primary_ip}
  IPv6   : ${v_ipv6_address}"
    else
        print_success "DNS domain \"${v_given_domain}\" configured successfully.
  Server : ${v_dns_host_short_name}.${v_given_domain}
  IPv4   : ${v_primary_ip}"
    fi
}

fn_instruct_on_valid_host_record() {
    print_error "> Only letters, numbers, and hyphens are allowed.
    > Hyphens cannot appear at the start or end.
    > The total length must be between 1 and 63 characters.
    > The domain name '${v_domain_name}' will be appended if not present.
    > Follows the format defined in RFC 1035."
    exit 1
}

fn_get_host_record() {
    v_input_host="${1}"
    v_action_requested="${2}"
    v_rename_record="${3}"

    fn_get_host_record_from_user() {

        while :
        do
            echo

            if [[ "${v_action_requested}" != "rename" ]]
            then
                read -p "Please Enter the name of host record to ${v_action_requested} : " v_input_host_record
            else
                if [[ -z "${v_host_record}" ]]
                then
                    read -p "Please Enter the name of host record to ${v_action_requested} : " v_input_host_record
                else
                    read -p "Please Enter the name of host record to ${v_action_requested} ${v_host_record}.${v_domain_name} : " v_input_host_record
                fi
            fi
                
            v_input_host_record="${v_input_host_record%.${v_domain_name}.}"  
            v_input_host_record="${v_input_host_record%.${v_domain_name}}"

            if [[ "${#v_input_host_record}" -le 63 ]] && [[ "${v_input_host_record}" =~ ^[[:alnum:]]([[:alnum:]-]*[[:alnum:]])?$ ]]
                then
                if [[ "${v_action_requested}" != "rename" ]]
                then
                    v_host_record="${v_input_host_record}"
                else
                    if [[ -z "${v_host_record}" ]]
                    then
                        v_host_record="${v_input_host_record}"
                    else
                        v_rename_record="${v_input_host_record}"
                    fi
                fi

                break
        else
                fn_instruct_on_valid_host_record
            fi
        done
    }

    if [[ -n ${v_input_host} ]]
    then
        v_host_record=${1}
        v_host_record="${v_host_record%.${v_domain_name}.}"  
        v_host_record="${v_host_record%.${v_domain_name}}"

        if [[ ! "${v_host_record}" =~ ^[[:alnum:]]([[:alnum:]-]*[[:alnum:]])?$ ]] || [[ ! "${#v_host_record}" -le 63 ]]
        then
            if ${v_if_autorun_false}
            then
                fn_instruct_on_valid_host_record
            else
                return 9
            fi
        fi

    else
        fn_get_host_record_from_user
    fi

    if grep "^${v_host_record} "  "${v_fw_zone}" &>/dev/null
    then 
        if [[ "${v_action_requested}" == "create" ]]
        then
            ${v_if_autorun_false} && print_error "Host record for ${v_host_record}.${v_domain_name} already exists ! "
            ${v_if_autorun_false} && print_error "Nothing to do ! Exiting !  "
            return 8

        elif [[ "${v_action_requested}" == "rename" ]]
        then
            if [[ -n ${v_rename_record} ]]
            then
                v_rename_record="${v_rename_record%.${v_domain_name}.}"  
                v_rename_record="${v_rename_record%.${v_domain_name}}"

                if [[ ! "${v_rename_record}" =~ ^[[:alnum:]]([[:alnum:]-]*[[:alnum:]])?$ ]] || [[ ! "${#v_rename_record}" -le 63 ]]
                then
                    fn_instruct_on_valid_host_record
                fi
            else
                fn_get_host_record_from_user
            fi

            if grep "^${v_rename_record} "  "${v_fw_zone}" &>/dev/null
            then 
                print_error "Conflict ! Existing host record found for ${v_rename_record}.${v_domain_name} ! "
                print_error "Nothing to do ! Exiting !  "
                exit 1
            fi
        fi

    elif [[ "${v_action_requested}" != "create" ]]
    then
        if ${v_if_autorun_false}
        then
            print_error "Host record for ${v_host_record}.${v_domain_name} doesn't exist ! "
            print_error "Nothing to do ! Exiting ! "
            exit 1
        else
            return 8
        fi
        
    fi
}


fn_update_serial_number_of_zones() {

    ${v_if_autorun_false} && print_task "Updating serial numbers of zone files..."

    # Generate new serial using Unix timestamp
    local new_serial=$(date +%s)
    
    # Forward zone
    v_current_serial_fw_zone=$(awk -F';' '/;Serial/{gsub(/[[:space:]]/,"",$1); print $1}' "${v_fw_zone}")
    # Ensure new serial is greater than current (handles same-second updates)
    if [[ $new_serial -le $v_current_serial_fw_zone ]]; then
        new_serial=$(( v_current_serial_fw_zone + 1 ))
    fi
    sed -i "/;Serial/s/${v_current_serial_fw_zone}/${new_serial}/g" "${v_fw_zone}"

    if [[ "${1}" != "forward-zone-only" ]]
    then
        # PTR zone (skip if not set — e.g., IPv6-only records)
        if [[ -n "${v_ptr_zone:-}" ]] && [[ -f "${v_ptr_zone}" ]]; then
            v_current_serial_ptr_zone=$(awk -F';' '/;Serial/{gsub(/[[:space:]]/,"",$1); print $1}' "${v_ptr_zone}")
            local new_serial_ptr=$(date +%s)
            if [[ $new_serial_ptr -le $v_current_serial_ptr_zone ]]; then
                new_serial_ptr=$(( v_current_serial_ptr_zone + 1 ))
            fi
            sed -i "/;Serial/s/${v_current_serial_ptr_zone}/${new_serial_ptr}/g" "${v_ptr_zone}"
        fi
        
        # Update IPv6 reverse zone if it exists
        if [[ -n "${dnsbinder_ipv6_ula_subnet}" ]]; then
            v_ipv6_zone_file="${var_zone_dir}/${v_domain_name}-ipv6-reverse.db"
            if [[ -f "${v_ipv6_zone_file}" ]]; then
                v_current_serial_ipv6_zone=$(awk -F';' '/;Serial/{gsub(/[[:space:]]/,"",$1); print $1}' "${v_ipv6_zone_file}")
                local new_serial_ipv6=$(date +%s)
                if [[ $new_serial_ipv6 -le $v_current_serial_ipv6_zone ]]; then
                    new_serial_ipv6=$(( v_current_serial_ipv6_zone + 1 ))
                fi
                sed -i "/;Serial/s/${v_current_serial_ipv6_zone}/${new_serial_ipv6}/g" "${v_ipv6_zone_file}"
            fi
        fi
    fi

    ${v_if_autorun_false} && print_task_done
}


fn_reload_named_dns_service() {

    cname_record_true="${1}"

    if [[ "${cname_record_true}" != "true" ]]; then
        cname_record_true="false"
    fi

    print_task "Reloading DNS..."

    sudo podman exec tux2lab-engine rndc reload &>/dev/null

    if sudo podman exec tux2lab-engine rndc status &>/dev/null;
    then 
        print_task_done
    else
        print_task_fail
    fi

    local max_retries=10
    local sleep_seconds=0.5
    sleep "${sleep_seconds}"

    # For delete operations (no validation needed), show success after reload
    if [[ "${v_action_requested}" == "delete" ]]
    then
        if "${cname_record_true}"
        then
            print_success "Successfully deleted cname record ${v_input_cname}.${v_domain_name}"
        else
            print_success "Successfully deleted host record ${v_host_record}.${v_domain_name}"
        fi
    fi

    if "${cname_record_true}" && [[ "${v_action_requested}" == "create" ]]
    then
        print_task "Validating CNAME record..."
        
        # Retry mechanism: wait up to 5 seconds for DNS to propagate
        local retry_count=0
        local query_success=false
        
        while [[ ${retry_count} -lt ${max_retries} ]]; do
            if dig @"${dnsbinder_server_ipv4_address}" +short +time=1 +tries=1 CNAME ${v_input_cname}.${v_domain_name} | grep -q '.'; then
                query_success=true
                break
            fi
            sleep "${sleep_seconds}"
            ((retry_count++))
        done
        
        if ${query_success}; then
            print_task_done
            local display_cname_ttl="${record_ttl:-3600 (default)}"
            print_info "FYI : ${v_input_cname}.${v_domain_name}\n             ├── CNAME for: $(dig @"${dnsbinder_server_ipv4_address}" +short CNAME ${v_input_cname}.${v_domain_name} 2>/dev/null | sed 's/\.$//' || true)\n             └── TTL      : ${display_cname_ttl} seconds"
            print_success "Created CNAME record ${v_input_cname}.${v_domain_name}"
        else
            print_task_fail
        fi

        return
    fi

    if [[ "${v_action_requested}" != "delete" ]]
    then

        print_task "Validating forward look up..."

        # Retry mechanism: wait up to 5 seconds for DNS to propagate
        local retry_count=0
        local query_success=false
        
        if  [[ "${v_action_requested}" == "rename" ]]
        then
            while [[ ${retry_count} -lt ${max_retries} ]]; do
                if dig @"${dnsbinder_server_ipv4_address}" +short +time=1 +tries=1 A ${v_rename_record}.${v_domain_name} | grep -q '^[0-9]'; then
                    query_success=true
                    break
                fi
                sleep "${sleep_seconds}"
                ((retry_count++))
            done
            
            # Also validate AAAA record if IPv6 is configured
            if ${query_success} && [[ "${record_stack}" != "ipv4" ]] && [[ -n "${dnsbinder_ipv6_ula_subnet}" ]]; then
                retry_count=0
                query_success=false
                while [[ ${retry_count} -lt ${max_retries} ]]; do
                    if dig @"${dnsbinder_server_ipv4_address}" +short +time=1 +tries=1 AAAA ${v_rename_record}.${v_domain_name} | grep -q ':'; then
                        query_success=true
                        break
                    fi
                    sleep "${sleep_seconds}"
                    ((retry_count++))
                done
            fi
        else
            while [[ ${retry_count} -lt ${max_retries} ]]; do
                if dig @"${dnsbinder_server_ipv4_address}" +short +time=1 +tries=1 A ${v_host_record}.${v_domain_name} | grep -q '^[0-9]'; then
                    query_success=true
                    break
                fi
                sleep "${sleep_seconds}"
                ((retry_count++))
            done
            
            # Also validate AAAA record if IPv6 is configured
            if ${query_success} && [[ "${record_stack}" != "ipv4" ]] && [[ -n "${dnsbinder_ipv6_ula_subnet}" ]]; then
                retry_count=0
                query_success=false
                while [[ ${retry_count} -lt ${max_retries} ]]; do
                    if dig @"${dnsbinder_server_ipv4_address}" +short +time=1 +tries=1 AAAA ${v_host_record}.${v_domain_name} | grep -q ':'; then
                        query_success=true
                        break
                    fi
                    sleep "${sleep_seconds}"
                    ((retry_count++))
                done
            fi
        fi
        
        if ${query_success}; then
            print_task_done
        else
            print_task_fail
        fi

        print_task "Validating reverse look up..."

        # Retry mechanism for reverse lookup (max 5 seconds)
        local retry_count=0
        local query_success=false
        
        while [[ ${retry_count} -lt ${max_retries} ]]; do
            if dig @"${dnsbinder_server_ipv4_address}" +short +time=1 +tries=1 -x ${v_current_ip_of_host_record} | grep -q '.'; then
                query_success=true
                break
            fi
            sleep "${sleep_seconds}"
            ((retry_count++))
        done
        
        if ${query_success}; then
            print_task_done
        else
            print_task_fail
        fi

        # Print success messages after validation
        if  [[ "${v_action_requested}" == "rename" ]]
        then
            if [[ -n "${dnsbinder_ipv6_ula_subnet}" ]]; then
                print_info "FYI : ${v_rename_record}.${v_domain_name}\n             ├── IPv4: $(dig @"${dnsbinder_server_ipv4_address}" +short A ${v_rename_record}.${v_domain_name} | head -1)\n             └── IPv6: $(dig @"${dnsbinder_server_ipv4_address}" +short AAAA ${v_rename_record}.${v_domain_name} | head -1 || true)"
            else
                print_info "FYI : ${v_rename_record}.${v_domain_name}\n             └── IPv4: $(dig @"${dnsbinder_server_ipv4_address}" +short A ${v_rename_record}.${v_domain_name} | head -1 || true)"
            fi
        else
            local display_ttl="${record_ttl:-3600 (default)}"
            local _ipv4_val=$(dig @"${dnsbinder_server_ipv4_address}" +short A ${v_host_record}.${v_domain_name} | head -1)
            local _ipv6_val=$(dig @"${dnsbinder_server_ipv4_address}" +short AAAA ${v_host_record}.${v_domain_name} | head -1 || true)
            local _fyi="FYI : ${v_host_record}.${v_domain_name}"
            if [[ -n "$_ipv4_val" ]] && [[ -n "$_ipv6_val" ]]; then
                _fyi+="\n             ├── IPv4: ${_ipv4_val}\n             ├── IPv6: ${_ipv6_val}"
            elif [[ -n "$_ipv4_val" ]]; then
                _fyi+="\n             ├── IPv4: ${_ipv4_val}"
            elif [[ -n "$_ipv6_val" ]]; then
                _fyi+="\n             ├── IPv6: ${_ipv6_val}"
            fi
            _fyi+="\n             └── TTL : ${display_ttl} seconds"
            print_info "$_fyi"
        fi

        if [[  "${v_action_requested}" == "create" ]]
        then
            local _success_label="host"
            [[ "${record_stack}" == "ipv4" ]] && _success_label="IPv4-only host"
            print_success "Created ${_success_label} record ${v_host_record}.${v_domain_name}"
        elif [[ "${v_action_requested}" == "delete" ]]
        then
            print_success "Deleted host record ${v_host_record}.${v_domain_name}"
        elif [[ "${v_action_requested}" == "rename" ]]
        then
            print_success "Renamed host ${v_host_record}.${v_domain_name} to ${v_rename_record}.${v_domain_name}"
        fi
    fi
}

fn_query_record() {
    local query_input="${1:-}"
    local found=false

    if [[ -z "${query_input}" ]]; then
        read -p "Enter hostname or IP address to look up: " query_input
        if [[ -z "${query_input}" ]]; then
            print_error "No input provided."
            return 1
        fi
    fi

    # Validate input: only allow characters valid in hostnames and IP addresses
    if [[ ! "${query_input}" =~ ^[a-zA-Z0-9.:/-]+$ ]]; then
        print_error "Invalid input: contains characters not allowed in hostnames or IP addresses."
        return 1
    fi

    # Strip domain suffix if provided
    query_input="${query_input%.${v_domain_name}.}"
    query_input="${query_input%.${v_domain_name}}"

    # Determine input type: IPv4, IPv6, or hostname
    if [[ "${query_input}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        # IPv4 address — reverse lookup in PTR zone files
        local ipv4="${query_input}"

        # Validate each octet is in range 0-255 and has no leading zeros
        local o1 o2 o3 o4
        IFS='.' read -r o1 o2 o3 o4 <<< "${ipv4}"
        # Reject leading zeros (ambiguous: could be interpreted as octal)
        if [[ "${o1}" =~ ^0[0-9] || "${o2}" =~ ^0[0-9] || "${o3}" =~ ^0[0-9] || "${o4}" =~ ^0[0-9] ]]; then
            print_error "Invalid IPv4 address: ${ipv4} (leading zeros not allowed)"
            return 1
        fi
        if (( o1 > 255 || o2 > 255 || o3 > 255 || o4 > 255 )); then
            print_error "Invalid IPv4 address: ${ipv4}"
            return 1
        fi

        local host_octet="${o4}"
        local subnet_prefix="${o1}.${o2}.${o3}"

        # Verify the address belongs to the configured IPv4 network
        local in_network
        in_network=$(fn_ipv4_in_network "${ipv4}" "${dnsbinder_network_cidr}")
        if [[ "${in_network}" != "True" ]]; then
            print_error "IPv4 address ${ipv4} is not in the configured network ${dnsbinder_network_cidr}"
            return 1
        fi

        local ptr_zone_file="${var_zone_dir}/${subnet_prefix}.${v_domain_name}-reverse.db"

        if [[ ! -f "${ptr_zone_file}" ]]; then
            print_error "No reverse zone file found for subnet ${subnet_prefix}.0/24"
            return 1
        fi

        local ptr_result
        ptr_result=$(awk -v octet="^${host_octet} " '$0 ~ octet && /IN PTR/ {gsub(/[[:space:]]/,"",$NF); print $NF}' "${ptr_zone_file}")

        if [[ -n "${ptr_result}" ]]; then
            found=true
            echo ""
            print_info "Query: ${ipv4} (PTR lookup)"
            echo "  PTR   : ${ptr_result}"

            # Also show forward records for the resolved hostname
            local resolved_host="${ptr_result%.${v_domain_name}.}"
            resolved_host="${resolved_host%.}"
            local a_record
            a_record=$(awk -v host="^${resolved_host} " '$0 ~ host && /IN A / {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")
            local aaaa_record
            aaaa_record=$(awk -v host="^${resolved_host} " '$0 ~ host && /IN AAAA/ {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")

            if [[ -n "${a_record}" ]]; then
                echo "  A     : ${a_record}"
            fi
            if [[ -n "${aaaa_record}" ]]; then
                echo "  AAAA  : ${aaaa_record}"
            fi
            local cname_aliases
            cname_aliases=$(awk -v target="${resolved_host}.${v_domain_name}." '$0 ~ /IN CNAME/ && $NF == target {gsub(/[[:space:]].*/,"",$1); print $1}' "${v_fw_zone}")
            if [[ -n "${cname_aliases}" ]]; then
                while IFS= read -r alias; do
                    echo "  CNAME : ${alias}.${v_domain_name}"
                done <<< "${cname_aliases}"
            fi
            local ptr_ttl
            ptr_ttl=$(awk -v host="^${resolved_host} " '$0 ~ host && /IN (A |AAAA )/ {
                for (i=1; i<=NF; i++) { if ($i == "IN") { if ($(i-1) ~ /^[0-9]+$/ && i > 2) print $(i-1); else print "3600 (default)"; break } }
                exit
            }' "${v_fw_zone}")
            echo "  TTL   : ${ptr_ttl} seconds"
            echo ""
        fi

    elif [[ "${query_input}" =~ : ]]; then
        # IPv6 address — reverse lookup in IPv6 PTR zone file
        local ipv6="${query_input}"
        local ipv6_zone_file="${var_zone_dir}/${v_domain_name}-ipv6-reverse.db"

        if [[ ! -f "${ipv6_zone_file}" ]]; then
            print_error "No IPv6 reverse zone file found."
            return 1
        fi

        # Expand IPv6 to full form and convert to nibble format for zone lookup
        local expanded_ipv6
        expanded_ipv6=$(fn_expand_ipv6 "${ipv6}")

        if [[ -z "${expanded_ipv6}" ]]; then
            print_error "Invalid IPv6 address: ${ipv6}"
            return 1
        fi

        # Verify the address belongs to our configured IPv6 network
        local in_network
        in_network=$(fn_ipv6_in_network "${ipv6}" "${dnsbinder_ipv6_ula_subnet}")

        if [[ "${in_network}" != "True" ]]; then
            print_error "IPv6 address ${ipv6} is not in the configured network ${dnsbinder_ipv6_ula_subnet}"
            return 1
        fi

        # Convert to full nibble-reversed format
        # e.g., fd28:2808:2020:3000:0000:0000:0000:0002 →
        # 2.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.3.0.2.0.2.8.0.8.2.8.2.d.f
        local nibbles
        nibbles=$(echo "${expanded_ipv6}" | tr -d ':' | rev | sed 's/./&./g' | sed 's/\.$//')

        # Zone file stores host portion only (last 64 bits = first 16 nibbles
        # of the reversed string for a /64 zone). Extract host nibbles.
        local host_nibbles
        host_nibbles=$(echo "${nibbles}" | cut -c1-31)

        # Look up the exact host nibble entry in the zone file
        local ptr_match
        ptr_match=$(awk -v nib="${host_nibbles}" '$1 == nib && /IN PTR/ {print}' "${ipv6_zone_file}" 2>/dev/null | head -1 || true)

        if [[ -n "${ptr_match}" ]]; then
            found=true
            local ptr_hostname
            ptr_hostname=$(awk '{gsub(/[[:space:]]/,"",$NF); print $NF}' <<< "${ptr_match}")
            echo ""
            print_info "Query: ${ipv6} (IPv6 PTR lookup)"
            echo "  PTR   : ${ptr_hostname}"

            # Also show forward records for the resolved hostname
            local resolved_host="${ptr_hostname%.${v_domain_name}.}"
            resolved_host="${resolved_host%.}"
            local a_record
            a_record=$(awk -v host="^${resolved_host} " '$0 ~ host && /IN A / {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")
            local aaaa_record
            aaaa_record=$(awk -v host="^${resolved_host} " '$0 ~ host && /IN AAAA/ {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")

            if [[ -n "${a_record}" ]]; then
                echo "  A     : ${a_record}"
            fi
            if [[ -n "${aaaa_record}" ]]; then
                echo "  AAAA  : ${aaaa_record}"
            fi
            local cname_aliases
            cname_aliases=$(awk -v target="${resolved_host}.${v_domain_name}." '$0 ~ /IN CNAME/ && $NF == target {gsub(/[[:space:]].*/,"",$1); print $1}' "${v_fw_zone}")
            if [[ -n "${cname_aliases}" ]]; then
                while IFS= read -r alias; do
                    echo "  CNAME : ${alias}.${v_domain_name}"
                done <<< "${cname_aliases}"
            fi
            local ptr_ttl
            ptr_ttl=$(awk -v host="^${resolved_host} " '$0 ~ host && /IN (A |AAAA )/ {
                for (i=1; i<=NF; i++) { if ($i == "IN") { if ($(i-1) ~ /^[0-9]+$/ && i > 2) print $(i-1); else print "3600 (default)"; break } }
                exit
            }' "${v_fw_zone}")
            echo "  TTL   : ${ptr_ttl} seconds"
            echo ""
        fi

    else
        # Hostname — forward lookup in zone file
        local hostname="${query_input}"

        # Check A record
        local a_record
        a_record=$(awk -v host="^${hostname} " '$0 ~ host && /IN A / {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")

        # Check AAAA record
        local aaaa_record
        aaaa_record=$(awk -v host="^${hostname} " '$0 ~ host && /IN AAAA/ {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")

        # Check CNAME record (as source — this name IS a cname)
        local cname_target
        cname_target=$(awk -v host="^${hostname} " '$0 ~ host && /IN CNAME/ {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")

        # Check if any CNAME points TO this hostname
        local cname_aliases
        cname_aliases=$(awk -v target="${hostname}.${v_domain_name}." '$0 ~ /IN CNAME/ && $NF == target {gsub(/[[:space:]].*/,"",$1); print $1}' "${v_fw_zone}")

        if [[ -n "${a_record}" || -n "${aaaa_record}" || -n "${cname_target}" ]]; then
            found=true
            echo ""
            print_info "Query: ${hostname}.${v_domain_name}"

            # Extract TTL (field before IN; if absent, use zone default)
            local record_ttl_display
            record_ttl_display=$(awk -v host="^${hostname} " '$0 ~ host && /IN (A |AAAA |CNAME )/ {
                for (i=1; i<=NF; i++) { if ($i == "IN") { if ($(i-1) ~ /^[0-9]+$/ && i > 2) print $(i-1); else print "3600 (default)"; break } }
                exit
            }' "${v_fw_zone}")

            if [[ -n "${cname_target}" ]]; then
                echo "  CNAME of : ${cname_target}"
                local resolved_host="${cname_target%.${v_domain_name}.}"
                resolved_host="${resolved_host%.}"
                local target_a
                target_a=$(awk -v host="^${resolved_host} " '$0 ~ host && /IN A / {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")
                local target_aaaa
                target_aaaa=$(awk -v host="^${resolved_host} " '$0 ~ host && /IN AAAA/ {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")
                if [[ -n "${target_a}" ]]; then
                    echo "  A     : ${target_a}"
                fi
                if [[ -n "${target_aaaa}" ]]; then
                    echo "  AAAA  : ${target_aaaa}"
                fi
            else
                if [[ -n "${a_record}" ]]; then
                    echo "  A     : ${a_record}"
                fi
                if [[ -n "${aaaa_record}" ]]; then
                    echo "  AAAA  : ${aaaa_record}"
                fi
                if [[ -n "${cname_aliases}" ]]; then
                    while IFS= read -r alias; do
                        echo "  CNAME : ${alias}.${v_domain_name}"
                    done <<< "${cname_aliases}"
                fi
            fi
            echo "  TTL   : ${record_ttl_display} seconds"
            echo ""
        fi
    fi

    if ! $found; then
        print_error "No records found for \"${query_input}\" in zone database."
        return 1
    fi
}

fn_set_ptr_zone() {

    arr_subnets=()
    arr_ptr_zones=()

    for ((v_zone_number=1; v_zone_number<=v_total_ptr_zones; v_zone_number++))
    do
        arr_subnet_var="v_subnet${v_zone_number}"
        arr_ptr_zone_var="v_ptr_zone${v_zone_number}"
        arr_subnets+=( "$(eval echo \${${arr_subnet_var}})" )
        arr_ptr_zones+=( "$(eval echo \${${arr_ptr_zone_var}})" )
    done

    for i in "${!arr_subnets[@]}"
    do
        if [[ "${v_current_ip_of_host_record}" == ${arr_subnets[i]}.* ]]
        then
            if ${v_if_autorun_false}; then
                if [[ -n "${dnsbinder_ipv6_ula_subnet}" ]] && [[ -n "${v_current_ipv6_of_host_record}" ]]; then
                    print_info "Match found for host record ${v_host_record}.${v_domain_name}\n             ├── IPv4: ${v_current_ip_of_host_record}\n             └── IPv6: ${v_current_ipv6_of_host_record}"
                else
                    print_info "Match found with IP ${v_current_ip_of_host_record} for host record ${v_host_record}.${v_domain_name}"
                fi
            fi
            v_ptr_zone="${arr_ptr_zones[i]}"
            break
        fi
    done
}

fn_get_ipv4_address() {

    ipv4_provided="${1}"

    fn_validate_ipv4_address() {
        local ipv4_provided="$1"
        local octet

        # Use a regex pattern for IPv4 validation
        if [[ "$ipv4_provided" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
            # Check if each octet is in the range 0-255
            for octet in ${BASH_REMATCH[@]:1}; do
                if (( octet < 0 || octet > 255 )); then
                    return 1
                fi
            done
            return 0
        else
            return 1
        fi
    }

    # Convert IP to decimal
    fn_convert_ip_to_decimal() {
        IFS=. read -r ipv4_octet1 ipv4_octet2 ipv4_octet3 ipv4_octet4 <<< "${1}"
        echo $(( (ipv4_octet1 << 24) + (ipv4_octet2 << 16) + (ipv4_octet3 << 8) + ipv4_octet4 ))
    }

    # Function to check if an IP is within a CIDR range
    fn_check_whether_ip_in_range() {
        local ipv4_provided="${1}"
        local dnsbinder_network="${2}"

        # Split network into base IP and prefix length
        IFS='/' read -r network_base network_mask <<< "${dnsbinder_network}"

        # Convert IPs to decimal
        decimal_value_of_ipv4=$(fn_convert_ip_to_decimal "${ipv4_provided}")
        decimal_value_of_network=$(fn_convert_ip_to_decimal "${network_base}")

        # Calculate network range
        range_size=$(( 32 - network_mask ))
        net_start=$(( decimal_value_of_network & (0xFFFFFFFF << range_size) ))
        net_end=$(( net_start | ((1 << range_size) - 1) ))

        # Check if IP falls within range
        if (( decimal_value_of_ipv4 >= net_start && decimal_value_of_ipv4 <= net_end )); then
            return 0  # IP is in range
        else
            return 1  # IP is NOT in range
        fi
    }

    while :
    do
        if [[ -z "${ipv4_provided}" ]]; then
            if ! ${v_if_autorun_false:-true}; then
                return 7
            fi
            read -rp "Provide the required IPv4 Address ( within ${dnsbinder_network} ) : " ipv4_provided
            if [[ -z "${ipv4_provided}" ]]; then
                print_error "IPv4 address is required."
                return 7
            fi
        fi

        if ! fn_validate_ipv4_address "${ipv4_provided}"; then
            ${v_if_autorun_false:-true} && print_error "Invalid input provided for IPv4 Address ! "
            return 7
        fi

        if fn_check_whether_ip_in_range "${ipv4_provided}" "${dnsbinder_network}"; then
            break
        else
            ${v_if_autorun_false:-true} && print_error "Provided IPv4 address doesn't reside within the network ${dnsbinder_network} ! "
            return 7
        fi
    done
}

fn_create_host_record() {

    if [[ "${2}" != "Automated-Execution" && "${3:-}" != "Automated-Execution" ]]
    then
        v_if_autorun_false=true 
    else
        v_if_autorun_false=false    
    fi

    if ${v_if_autorun_false}; then
        if ! fn_acquire_zone_lock; then return 1; fi
    fi

    fn_get_host_record "${1}" "create"

    v_exit_status_fn_get_host_record=${?}

    if [[ ${v_exit_status_fn_get_host_record} -ne 0 ]]
    then
        ${v_if_autorun_false} && fn_release_zone_lock
        return ${v_exit_status_fn_get_host_record}
    fi

    if [[ -n "${specific_ipv4_requested}" ]] ; then
        fn_get_ipv4_address "${2}"
        local v_ipv4_status=$?
        if [[ ${v_ipv4_status} -ne 0 ]]; then
            ${v_if_autorun_false} && fn_release_zone_lock
            return ${v_ipv4_status}
        fi
    fi

    fn_check_free_ip() {

        local v_file_ptr_zone="${1}"
        local v_start_ip="${2}"
        local v_max_ip="${3}"
        local v_subnet="${4}"
        local v_capture_list_of_ips=$(sed -n 's/^\([0-9]\+\).*/\1/p' "${v_file_ptr_zone}")
        declare -A v_existing_ips

        if [[ -z "${v_capture_list_of_ips}" ]]
        then
            v_host_part_of_current_ip="${v_start_ip}"
            v_current_ip_of_host_record="${v_subnet}.${v_host_part_of_current_ip}"
            v_previous_ip=';PTR-Records'
            v_ptr_zone="${v_file_ptr_zone}"
            return 0
        fi


        while IFS= read -r ip
        do
            v_existing_ips["$ip"]=1
        done <<< "${v_capture_list_of_ips}"

        if [[ "${#v_existing_ips[@]}" -eq 1 ]]
        then
            if grep -q "broadcast.${v_domain_name}." "${v_file_ptr_zone}" 
            then
                v_host_part_of_current_ip="${v_start_ip}"
                v_current_ip_of_host_record="${v_subnet}.${v_host_part_of_current_ip}"
                v_previous_ip=';PTR-Records'
                v_ptr_zone="${v_file_ptr_zone}"
                return 0
            fi
        fi

        for ((v_num_ptr = ${v_start_ip}; v_num_ptr <= ${v_max_ip}; v_num_ptr++))
        do
            if [[ -z "${v_existing_ips[$v_num_ptr]+isset}" ]]
            then
                v_host_part_of_current_ip="${v_num_ptr}"
                v_current_ip_of_host_record="${v_subnet}.${v_host_part_of_current_ip}"
                v_ptr_zone="${v_file_ptr_zone}"
                
                if [[ ${v_num_ptr} -eq 0 ]]
                then
                    v_previous_ip=';PTR-Records'
                else
                    v_host_part_of_previous_ip=$((v_num_ptr - 1))
                    v_previous_ip="${v_subnet}.${v_host_part_of_previous_ip}"
                fi
                return 0
            fi
        done
        
        # No free IP found in this zone
        return 1
    }   
    
    
    count_houseful_ptr_zones=0
    for ((v_zone_number=1; v_zone_number<=v_total_ptr_zones; v_zone_number++))
    do
        v_current_ptr_zone_file="v_ptr_zone${v_zone_number}"

        v_current_ptr_zone_file="${!v_current_ptr_zone_file}"

        v_total_ips_in_current_zone=$(sed -n 's/^\([0-9]\+\).*/\1/p' "${v_current_ptr_zone_file}" | wc -l)

        v_current_subnet="v_subnet${v_zone_number}"

        v_current_subnet="${!v_current_subnet}"

        if [[ -n "${ipv4_provided}" ]]
        then
            IFS='.' read -r ipv4_octet1 ipv4_octet2 ipv4_octet3 ipv4_octet4 <<< "${ipv4_provided}"
            subnet_part_of_ipv4_provided="${ipv4_octet1}.${ipv4_octet2}.${ipv4_octet3}"
            host_part_of_ipv4_provided="${ipv4_octet4}"
            
            if [[ "${v_current_subnet}" == "${subnet_part_of_ipv4_provided}" ]]
            then
                if grep "^${host_part_of_ipv4_provided} " "${v_current_ptr_zone_file}" &>/dev/null      
                then
                    print_error "Record already exists for provided IPv4 address ${ipv4_provided} !"
                    dig @"${dnsbinder_server_ipv4_address}" +short -x ${ipv4_provided} 2>/dev/null | sed 's/\.$//' || true
                    print_warning "Please try again with another IPv4 address ! "
                    if ${v_if_autorun_false}; then
                        exit 1
                    else
                        return 7
                    fi
                else
                    mapfile -t v_list_of_ips_in_zone < <(sed -n 's/^\([0-9]\+\).*/\1/p' "${v_current_ptr_zone_file}" | sort -n)
                    v_host_part_of_current_ip="${host_part_of_ipv4_provided}"
                    v_current_ip_of_host_record="${subnet_part_of_ipv4_provided}.${v_host_part_of_current_ip}"
                    v_ptr_zone="${v_current_ptr_zone_file}"
                    if [[ ${#v_list_of_ips_in_zone[@]} -gt 0 ]]
                    then
                        v_count_less=0
                        for ptr_ip in "${v_list_of_ips_in_zone[@]}"
                        do
                            if [[ "${ptr_ip}" -lt "${v_host_part_of_current_ip}" ]]
                            then
                                v_host_part_of_previous_ip="${ptr_ip}"
                                ((v_count_less++))
                                continue
                            else
                                break
                            fi
                        done

                        if [[ "${v_count_less}" -eq 0 ]]
                        then
                            v_previous_ip=';PTR-Records'
                        else    
                            v_previous_ip="${subnet_part_of_ipv4_provided}.${v_host_part_of_previous_ip}"
                        fi
                    else
                        v_previous_ip=';PTR-Records'
                    fi
                fi
            else
                continue
            fi

        else

            if [[ ${v_total_ips_in_current_zone} -ne 256 ]]
            then
                if fn_check_free_ip "${v_current_ptr_zone_file}" "0" "255" "${v_current_subnet}"
                then
                    # Found a free IP in this zone
                    break
                else
                    # This zone is exhausted even though it has < 256 records (sparse allocation)
                    ((count_houseful_ptr_zones++))
                    if [[ "${count_houseful_ptr_zones}" -eq "${v_total_ptr_zones}" ]]
                    then
                        ${v_if_autorun_false} && print_error "No more IP addresses are available in the ${dnsbinder_network} network of ${v_domain_name} domain ! "
                        ${v_if_autorun_false} && fn_release_zone_lock
                        return 255
                    else
                        continue
                    fi
                fi
            else
                ((count_houseful_ptr_zones++))
                if [[ "${count_houseful_ptr_zones}" -eq "${v_total_ptr_zones}" ]]
                then
                    ${v_if_autorun_false} && print_error "No more IP addresses are available in the ${dnsbinder_network} network of ${v_domain_name} domain ! "
                    ${v_if_autorun_false} && fn_release_zone_lock
                    return 255
                else
                    continue
                fi
            fi
        fi
    done


    local _create_label="host"
    [[ "${record_stack}" == "ipv4" ]] && _create_label="IPv4-only host"
    ${v_if_autorun_false} && print_task "Creating ${_create_label} record ${v_host_record}.${v_domain_name}..."

    ############### A Record Creation Section ############################

    v_host_record_adjusted_space=$(printf "%-*s" 63 "${v_host_record}")

    local ttl_field=""
    [[ -n "${record_ttl}" ]] && ttl_field="${record_ttl} "
    v_add_host_record=$(echo "${v_host_record_adjusted_space} ${ttl_field}IN A ${v_current_ip_of_host_record}")

    if [[ "${v_previous_ip}" == ';PTR-Records' ]]
    then
        sed -i "/^broadcast /i \\${v_add_host_record}" "${v_fw_zone}"
    else
        # Find the actual last A record in the forward zone for proper insertion
        # v_previous_ip might not exist in forward zone if there are gaps
        IFS=. read -r s1 s2 s3 last_octet <<< "${v_previous_ip}"
        local found_insertion_point=false
        
        # Try to find v_previous_ip first
        local v_previous_ip_escaped="${v_previous_ip//./\\.}"
        if grep -q "${v_previous_ip_escaped}$" "${v_fw_zone}"; then
            sed -i "/${v_previous_ip_escaped}$/a \\${v_add_host_record}" "${v_fw_zone}"
            found_insertion_point=true
        else
            # Search backwards for an existing A record in the same /24 subnet
            for ((search_octet=last_octet-1; search_octet>=0; search_octet--)); do
                search_ip="${s1}.${s2}.${s3}.${search_octet}"
                local search_ip_escaped="${search_ip//./\\.}"
                if grep -q "${search_ip_escaped}$" "${v_fw_zone}"; then
                    sed -i "/${search_ip_escaped}$/a \\${v_add_host_record}" "${v_fw_zone}"
                    found_insertion_point=true
                    break
                fi
            done
        fi
        
        # Fallback: insert before broadcast if no insertion point found
        if ! ${found_insertion_point}; then
            sed -i "/^broadcast /i \\${v_add_host_record}" "${v_fw_zone}"
        fi
    fi

    ##################  End of  A Record Create Section ############################

    ############### AAAA Record Creation Section (IPv6 dual-stack) ############################

    # Add AAAA record if IPv6 is configured (skip for IPv4-only)
    if [[ "${record_stack}" != "ipv4" ]] && [[ -n "${dnsbinder_ipv6_ula_subnet}" && ! -z "${dnsbinder_ipv6_gateway}" ]]; then
        # Calculate offset from network base, derive IPv6 as prefix::offset
        local network_base="${dnsbinder_network_cidr%/*}"
        IFS=. read -r oct1 oct2 oct3 oct4 <<< "$v_current_ip_of_host_record"
        IFS=. read -r net1 net2 net3 net4 <<< "$network_base"
        local offset=$(( (oct1-net1)*16777216 + (oct2-net2)*65536 + (oct3-net3)*256 + (oct4-net4) ))
        local offset_hex=$(printf "%x" $offset)
        
        # Expand gateway to full form and extract the /64 prefix
        ipv6_prefix_base=$(fn_ipv6_prefix "${dnsbinder_ipv6_gateway}")
        
        v_ipv6_address_for_host="${ipv6_prefix_base}::${offset_hex}"
        
        v_add_ipv6_host_record=$(echo "${v_host_record_adjusted_space} ${ttl_field}IN AAAA ${v_ipv6_address_for_host}")
        
        v_insert_after=$(fn_find_aaaa_insert_after "$offset" "${v_fw_zone}")
        
        # Insert at the correct position
        if [[ "${v_insert_after}" == ";AAAA-Records (IPv6)" ]]; then
            sed -i "/^;AAAA-Records (IPv6)/a \\${v_add_ipv6_host_record}" "${v_fw_zone}"
        else
            sed -i "/^${v_insert_after} .*IN AAAA/a \\${v_add_ipv6_host_record}" "${v_fw_zone}"
        fi
    fi

    ##################  End of  AAAA Record Create Section ############################



    ################## PTR Record Create  Section ###################################

    v_space_adjusted_host_part_of_current_ip=$(printf "%-*s" 3 "${v_host_part_of_current_ip}")

    v_add_ptr_record=$(echo "${v_space_adjusted_host_part_of_current_ip} ${ttl_field}IN PTR ${v_host_record}.${v_domain_name}.")

    if [[ "${v_previous_ip}" == ';PTR-Records' ]]
    then
        sed -i "/^;PTR-Records/a\\${v_add_ptr_record}" "${v_ptr_zone}"
    else
        sed -i "/^${v_host_part_of_previous_ip} /a\\${v_add_ptr_record}" "${v_ptr_zone}"
    fi

    ############# End of PTR Record Create Section #######################

    ################## IPv6 PTR Record Create Section ###################################

    # Add IPv6 PTR record (skip for IPv4-only)
    if [[ "${record_stack}" != "ipv4" ]] && [[ -n "${dnsbinder_ipv6_ula_subnet}" && ! -z "${v_ipv6_address_for_host}" ]]; then
        v_ipv6_zone_file="${var_zone_dir}/${v_domain_name}-ipv6-reverse.db"
        
        # Convert IPv6 address to PTR format (16 nibbles reversed)
        v_ipv6_ptr=$(fn_ipv6_to_nibbles "${v_ipv6_address_for_host}")
        
        if [[ -n "${v_ipv6_ptr}" ]]; then
            v_add_ipv6_ptr_record="${v_ipv6_ptr} ${ttl_field}IN PTR ${v_host_record}.${v_domain_name}."
            
            # Find correct insertion point based on lexicographic nibble order
            v_insert_after=$(fn_find_ptr_insert_after "${v_ipv6_ptr}" "${v_ipv6_zone_file}")
            
            # Insert at the correct position
            if [[ "${v_insert_after}" == ";IPv6 PTR-Records" ]]; then
                if grep -q "^;IPv6 PTR-Records" "${v_ipv6_zone_file}" 2>/dev/null; then
                    sed -i "/^;IPv6 PTR-Records/a\\${v_add_ipv6_ptr_record}" "${v_ipv6_zone_file}"
                fi
            else
                sed -i "/^${v_insert_after} /a\\${v_add_ipv6_ptr_record}" "${v_ipv6_zone_file}"
            fi
        fi
    fi

    ############# End of IPv6 PTR Record Create Section #######################


    ${v_if_autorun_false} && print_task_done

    if ${v_if_autorun_false}; then
        fn_update_serial_number_of_zones
        fn_reload_named_dns_service
        fn_release_zone_lock
    fi
}


fn_delete_host_record() {

    if [[ "${3}" != "Automated-Execution" ]]
    then
        v_if_autorun_false=true 
    else
        v_if_autorun_false=false    
    fi

    if ${v_if_autorun_false}; then
        if ! fn_acquire_zone_lock; then return 1; fi
    fi

    fn_get_host_record "${1}" "delete"

    v_exit_status_fn_get_host_record=${?}

    if [[ ${v_exit_status_fn_get_host_record} -ne 0 ]]
    then
        ${v_if_autorun_false} && fn_release_zone_lock
        return ${v_exit_status_fn_get_host_record}
    fi

    v_capture_host_record=$(grep "^${v_host_record} .*IN A " "${v_fw_zone}" ) 
    v_current_ip_of_host_record=$(awk -v host="^${v_host_record} " '$0 ~ host && /IN A / {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")
    v_current_ipv6_of_host_record=$(awk -v host="^${v_host_record} " '$0 ~ host && /IN AAAA/ {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")
    v_capture_ptr_prefix=$(awk -F. '{ print $4 }' <<< "${v_current_ip_of_host_record}")

    fn_set_ptr_zone
    v_input_delete_confirmation="${2}"

    while :
    do
        if [[ ! ${v_input_delete_confirmation} == "-y" ]]
        then
            read -p "Please confirm deletion of records (y/n) : " v_confirmation
        else
            v_confirmation='y'
        fi

        if [[ ${v_confirmation} == "y" ]]
        then
            ${v_if_autorun_false} && print_task "Deleting host record ${v_host_record}.${v_domain_name}..."

            sed -i "/^${v_capture_ptr_prefix} /d" "${v_ptr_zone}"
            sed -i "/^$(printf '%s' "${v_capture_host_record}" | sed 's/[.[\*^$()+?{|\\]/\\&/g')/d" "${v_fw_zone}"
            
            # Also delete AAAA record if it exists (IPv6 dual-stack)
            sed -i "/^${v_host_record} .*IN AAAA/d" "${v_fw_zone}"
            # Also delete IPv6 PTR record
            v_ipv6_zone_file="${var_zone_dir}/${v_domain_name}-ipv6-reverse.db"
            if [[ -f "${v_ipv6_zone_file}" ]]; then
                # Delete any PTR record pointing to this host
                sed -i "/IN PTR ${v_host_record}\.${v_domain_name}\./d" "${v_ipv6_zone_file}"
            fi

            ${v_if_autorun_false} && print_task_done

            if ${v_if_autorun_false}
            then
                fn_update_serial_number_of_zones
                fn_reload_named_dns_service
                fn_release_zone_lock
            fi
            break

        elif [[ ${v_confirmation} == "n" ]]
        then
            print_warning "Cancelled without any changes ! "
            ${v_if_autorun_false} && fn_release_zone_lock
            break

        else
            print_error "Select only either (y/n) ! "
            continue

        fi
    done
}

fn_rename_host_record() {

    if [[ "${3}" != "Automated-Execution" ]]
    then
        v_if_autorun_false=true 
    else
        v_if_autorun_false=false    
    fi

    if ! fn_acquire_zone_lock; then return 1; fi

    fn_get_host_record "${1}" "rename" "${2}"

    v_exit_status_fn_get_host_record=${?}

    if [[ ${v_exit_status_fn_get_host_record} -ne 0 ]]
    then
        fn_release_zone_lock
        return ${v_exit_status_fn_get_host_record}
    fi

    # Detect record type
    local _is_cname=false _is_ipv6_only=false
    if grep -q "^${v_host_record} .*IN CNAME" "${v_fw_zone}" 2>/dev/null; then
        _is_cname=true
    elif ! grep -q "^${v_host_record} .*IN A " "${v_fw_zone}" 2>/dev/null && grep -q "^${v_host_record} .*IN AAAA" "${v_fw_zone}" 2>/dev/null; then
        _is_ipv6_only=true
    fi

    if $_is_cname; then
        local _cname_target
        _cname_target=$(awk -v h="^${v_host_record} " '$0 ~ h && /IN CNAME/ {print $NF}' "${v_fw_zone}")
        print_info "Match found: ${v_host_record}.${v_domain_name} is a CNAME for ${_cname_target}"
    elif $_is_ipv6_only; then
        local _v6_addr
        _v6_addr=$(awk -v h="^${v_host_record} " '$0 ~ h && /IN AAAA/ {print $NF}' "${v_fw_zone}")
        print_info "Match found for IPv6-only record ${v_host_record}.${v_domain_name}\n             └── IPv6: ${_v6_addr}"
    else
        v_current_ip_of_host_record=$(awk -v host="^${v_host_record} " '$0 ~ host && /IN A / {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")
        local _v6_show
        _v6_show=$(awk -v host="^${v_host_record} " '$0 ~ host && /IN AAAA/ {print $NF}' "${v_fw_zone}")
        if [[ -n "${_v6_show}" ]]; then
            print_info "Match found for host record ${v_host_record}.${v_domain_name}\n             ├── IPv4: ${v_current_ip_of_host_record}\n             └── IPv6: ${_v6_show}"
        else
            print_info "Match found with IP ${v_current_ip_of_host_record} for host record ${v_host_record}.${v_domain_name}"
        fi
    fi

    v_input_rename_confirmation="${3}"
    
    while :
    do
        if [[ ! ${v_input_rename_confirmation} == "-y" ]]
        then
            read -p "Please confirm to rename the record ${v_host_record}.${v_domain_name} to ${v_rename_record}.${v_domain_name} (y/n) : " v_confirmation
        else
            v_confirmation='y'
        fi

        if [[ $v_confirmation == "y" ]]
        then
            print_task "Renaming host record ${v_host_record}.${v_domain_name} to ${v_rename_record}.${v_domain_name}..."

            local v_rename_adjusted
            v_rename_adjusted=$(printf "%-*s" 63 "${v_rename_record}")

            if $_is_cname; then
                local _cname_target _cname_ttl _cname_ttl_field=""
                _cname_target=$(awk -v h="^${v_host_record} " '$0 ~ h && /IN CNAME/ {print $NF}' "${v_fw_zone}")
                _cname_ttl=$(awk -v h="^${v_host_record} " '$0 ~ h && /IN CNAME/ {
                    for (i=1; i<=NF; i++) if ($i == "IN") { if ($(i-1) ~ /^[0-9]+$/ && i > 2) print $(i-1) }
                }' "${v_fw_zone}")
                [[ -n "${_cname_ttl}" ]] && _cname_ttl_field="${_cname_ttl} "
                sed -i "/^${v_host_record} .*IN CNAME/c\\${v_rename_adjusted} ${_cname_ttl_field}IN CNAME ${_cname_target}" "${v_fw_zone}"

            elif $_is_ipv6_only; then
                local _v6_addr _v6_ttl _v6_ttl_field=""
                _v6_addr=$(awk -v h="^${v_host_record} " '$0 ~ h && /IN AAAA/ {print $NF}' "${v_fw_zone}")
                _v6_ttl=$(awk -v h="^${v_host_record} " '$0 ~ h && /IN AAAA/ {
                    for (i=1; i<=NF; i++) if ($i == "IN") { if ($(i-1) ~ /^[0-9]+$/ && i > 2) print $(i-1) }
                }' "${v_fw_zone}")
                [[ -n "${_v6_ttl}" ]] && _v6_ttl_field="${_v6_ttl} "
                sed -i "/^${v_host_record} .*IN AAAA/c\\${v_rename_adjusted} ${_v6_ttl_field}IN AAAA ${_v6_addr}" "${v_fw_zone}"
                v_ipv6_zone_file="${var_zone_dir}/${v_domain_name}-ipv6-reverse.db"
                if [[ -f "${v_ipv6_zone_file}" ]]; then
                    sed -i "s/IN PTR ${v_host_record}\.${v_domain_name}\./IN PTR ${v_rename_record}.${v_domain_name}./g" "${v_ipv6_zone_file}"
                fi

            else
                # Dual-stack or IPv4-only
                local v_existing_ttl ttl_field=""
                v_existing_ttl=$(awk -v h="^${v_host_record} " '$0 ~ h && /IN A / {
                    for (i=1; i<=NF; i++) if ($i == "IN") { if ($(i-1) ~ /^[0-9]+$/ && i > 2) print $(i-1) }
                }' "${v_fw_zone}")
                [[ -n "${v_existing_ttl}" ]] && ttl_field="${v_existing_ttl} "

                # Rename A record
                local v_old_a_line v_new_a_line
                v_old_a_line=$(grep "^${v_host_record} .*IN A " "${v_fw_zone}")
                v_new_a_line="${v_rename_adjusted} ${ttl_field}IN A ${v_current_ip_of_host_record}"
                local old_esc new_esc
                old_esc=$(printf '%s' "${v_old_a_line}" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
                new_esc=$(printf '%s' "${v_new_a_line}" | sed 's/[&/\\]/\\&/g')
                sed -i "s/${old_esc}/${new_esc}/g" "${v_fw_zone}"

                # Rename IPv4 PTR
                IFS=. read -r _o1 _o2 _o3 _o4 <<< "$v_current_ip_of_host_record"
                v_ptr_zone="${var_zone_dir}/${_o1}.${_o2}.${_o3}.${v_domain_name}-reverse.db"
                if [[ -f "${v_ptr_zone}" ]]; then
                    sed -i "s/${v_host_record}\.${v_domain_name}\./${v_rename_record}.${v_domain_name}./g" "${v_ptr_zone}"
                fi

                # Rename AAAA record if it exists
                local v_cur_aaaa_addr
                v_cur_aaaa_addr=$(awk -v h="^${v_host_record} " '$0 ~ h && /IN AAAA/ {print $NF}' "${v_fw_zone}")
                if [[ -n "${v_cur_aaaa_addr}" ]]; then
                    local v_aaaa_ttl aaaa_ttl_field=""
                    v_aaaa_ttl=$(awk -v h="^${v_host_record} " '$0 ~ h && /IN AAAA/ {
                        for (i=1; i<=NF; i++) if ($i == "IN") { if ($(i-1) ~ /^[0-9]+$/ && i > 2) print $(i-1) }
                    }' "${v_fw_zone}")
                    [[ -n "${v_aaaa_ttl}" ]] && aaaa_ttl_field="${v_aaaa_ttl} "
                    sed -i "/^${v_host_record} .*IN AAAA/c\\${v_rename_adjusted} ${aaaa_ttl_field}IN AAAA ${v_cur_aaaa_addr}" "${v_fw_zone}"
                fi

                # Rename IPv6 PTR if it exists
                v_ipv6_zone_file="${var_zone_dir}/${v_domain_name}-ipv6-reverse.db"
                if [[ -f "${v_ipv6_zone_file}" ]]; then
                    sed -i "s/IN PTR ${v_host_record}\.${v_domain_name}\./IN PTR ${v_rename_record}.${v_domain_name}./g" "${v_ipv6_zone_file}"
                fi
            fi

            print_task_done
            
            fn_update_serial_number_of_zones

            print_task "Reloading DNS..."
            sudo podman exec tux2lab-engine rndc reload &>/dev/null && print_task_done || print_task_fail

            # Validate and show FYI
            if $_is_cname; then
                print_info "FYI : ${v_rename_record}.${v_domain_name}\n             └── CNAME for: ${_cname_target}"
                print_success "Renamed CNAME ${v_host_record}.${v_domain_name} to ${v_rename_record}.${v_domain_name}"
            elif $_is_ipv6_only; then
                print_info "FYI : ${v_rename_record}.${v_domain_name}\n             └── IPv6: ${_v6_addr}"
                print_success "Renamed IPv6-only host ${v_host_record}.${v_domain_name} to ${v_rename_record}.${v_domain_name}"
            else
                local _fyi_v6=""
                [[ -n "${v_cur_aaaa_addr}" ]] && _fyi_v6="\n             ├── IPv6: ${v_cur_aaaa_addr}"
                if [[ -n "${_fyi_v6}" ]]; then
                    print_info "FYI : ${v_rename_record}.${v_domain_name}\n             ├── IPv4: ${v_current_ip_of_host_record}${_fyi_v6}"
                else
                    print_info "FYI : ${v_rename_record}.${v_domain_name}\n             └── IPv4: ${v_current_ip_of_host_record}"
                fi
                print_success "Renamed host ${v_host_record}.${v_domain_name} to ${v_rename_record}.${v_domain_name}"
            fi

            fn_release_zone_lock
            break

        elif [[ $v_confirmation == "n" ]]
        then
            print_warning "Cancelled without any changes ! "
            fn_release_zone_lock
            break

        else
            print_error "Select only either (y/n) ! "
            continue

        fi
    done
}

fn_handle_multiple_host_record_with_ip() {

    if ! fn_acquire_zone_lock; then return 1; fi

    local v_host_list_file="${1}"
    local v_auto_confirm="${2:-}"

    if ! $inline_mode; then
        clear
        print_cyan "######################(DNS-Bulk-Records-Maker-with-IP)#############################"
    fi

    if [[ -z "${v_host_list_file}" ]]; then
        echo
        print_notify "Name of the file containing the list of 'hostname ipv4' records to create : "
        read -e v_host_list_file
    fi

    if [[ ! -f "${v_host_list_file}" ]]; then print_error "File \"${v_host_list_file}\" doesn't exist!\n"; fn_release_zone_lock; exit; fi

    if [[ ! -s "${v_host_list_file}" ]]; then print_error "File \"${v_host_list_file}\" is empty!\n"; fn_release_zone_lock; exit; fi

    # Work on a copy to avoid modifying the user's original file
    local v_work_file
    v_work_file="$(mktemp /tmp/dnsbinder-bulk-ip.XXXXXXXXXX)"
    cp "${v_host_list_file}" "${v_work_file}"

    sed -i '/^[[:space:]]*$/d' "${v_work_file}"
    sed -i 's/,/ /g' "${v_work_file}"
    sed -i "s/\.${v_domain_name}\.//g" "${v_work_file}"
    sed -i "s/\.${v_domain_name}//g" "${v_work_file}"

    # Validate file format: each line must have exactly 2 fields (hostname ipv4)
    local v_line_num=0
    while read -r v_line_hostname v_line_ipv4 v_line_extra; do
        ((v_line_num++))
        if [[ -z "${v_line_hostname}" || -z "${v_line_ipv4}" ]]; then
            print_error "Line ${v_line_num}: Missing hostname or IPv4 address."
            print_info "Expected format: hostname ipv4_address"
            rm -f "${v_work_file}"
            fn_release_zone_lock
            exit 1
        fi
        if [[ -n "${v_line_extra}" ]]; then
            print_error "Line ${v_line_num}: Too many fields. Expected: hostname ipv4_address"
            rm -f "${v_work_file}"
            fn_release_zone_lock
            exit 1
        fi
    done < "${v_work_file}"

    local v_total_host_records
    v_total_host_records=$(wc -l < "${v_work_file}")

    if [[ "${v_auto_confirm}" == "-y" ]]; then
        print_info "Auto-confirmed: Creating ${v_total_host_records} host records..."
    else
        while :; do
            print_info "Records to be Created : "
            cat "${v_work_file}"
            echo
            print_notify "Provide your confirmation to create the above host records (y/n) : " "nskip"
            read v_confirmation
            if [[ ${v_confirmation} == "y" ]]; then
                break
            elif [[ ${v_confirmation} == "n" ]]; then
                print_error "Cancelled without any changes !!"
                rm -f "${v_work_file}"
                fn_release_zone_lock
                exit
            else
                print_error "Select either (y/n) only !"
                continue
            fi
        done
    fi

    > "${v_tmp_file_dnsbinder}"

    local v_count_successfull=0
    local v_count_failed=0
    local v_count_invalid_host=0
    local v_count_invalid_ipv4=0
    local v_count_already_exists=0
    local v_count_ip_exhausted=0
    local v_count_other_failures=0

    local v_host_count=0

    # Show initial header once
    if ! $inline_mode; then
        clear
        print_cyan "######################(DNS-Bulk-Records-Maker-with-IP)#############################"
    else
        print_info "Creating ${v_total_host_records} host records..."
    fi

    while read -r v_host_record v_host_ipv4; do
        # Update progress header in place (move cursor to top)
        if ! $inline_mode; then
            tput cup 1 0
            print_cyan "####################################( Running )####################################"
            print_white "Status     : [ ${v_host_count}/${v_total_host_records} ] host records have been processed"
            print_green "Successful : ${v_count_successfull}"
            print_red "Failed     : ${v_count_failed}"
        fi

        ((v_host_count++))

        print_task "Creating host record ${v_host_record}.${v_domain_name} (${v_host_ipv4})..." "nskip"

        specific_ipv4_requested="yes"
        fn_create_host_record "${v_host_record}" "${v_host_ipv4}" "Automated-Execution"
        local var_exit_status=${?}

        local v_fqdn="${v_host_record}.${v_domain_name}"

        local v_ip_address
        v_ip_address=$(awk -v host="^${v_host_record} " '$0 ~ host && /IN A / {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")
        local v_ipv6_address
        v_ipv6_address=$(awk -v host="^${v_host_record} " '$0 ~ host && /IN AAAA / {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")

        if [[ -z "${v_ip_address}" ]]; then
            v_ip_address="N/A"
        fi

        local v_address_display
        if [[ -n "${v_ipv6_address}" ]]; then
            v_address_display="IPv4: ${v_ip_address}, IPv6: ${v_ipv6_address}"
        else
            v_address_display="${v_ip_address}"
        fi

        local v_details_of_host_record="${v_fqdn} ( ${v_address_display} )"

        if [[ ${var_exit_status} -eq 9 ]]; then
            print_red "Invalid-Host     ${v_details_of_host_record}" >> "${v_tmp_file_dnsbinder}"
            print_task_fail
            ((v_count_failed++))
            ((v_count_invalid_host++))
        elif [[ ${var_exit_status} -eq 7 ]]; then
            print_red "Invalid-IPv4     ${v_details_of_host_record}" >> "${v_tmp_file_dnsbinder}"
            print_task_fail
            ((v_count_failed++))
            ((v_count_invalid_ipv4++))
        elif [[ ${var_exit_status} -eq 8 ]]; then
            print_yellow "Already-Exists   ${v_details_of_host_record}" >> "${v_tmp_file_dnsbinder}"
            print_task_fail
            ((v_count_failed++))
            ((v_count_already_exists++))
        elif [[ ${var_exit_status} -eq 255 ]]; then
            print_red "IP-Exhausted     ${v_details_of_host_record}" >> "${v_tmp_file_dnsbinder}"
            print_task_fail
            ((v_count_failed++))
            ((v_count_ip_exhausted++))
        else
            if grep -q "^${v_host_record} " "${v_fw_zone}" 2>/dev/null; then
                print_green "Created          ${v_details_of_host_record}" >> "${v_tmp_file_dnsbinder}"
                print_task_done
                ((v_count_successfull++))
            else
                print_red "Failed-to-Create ${v_details_of_host_record}" >> "${v_tmp_file_dnsbinder}"
                print_task_fail
                ((v_count_failed++))
                ((v_count_other_failures++))
            fi
        fi

        # Clear from cursor to end of screen for next iteration
        if ! $inline_mode; then
            tput ed
        fi

    done < "${v_work_file}"

    rm -f "${v_work_file}"

    # Clear the progress display before showing final summary
    if ! $inline_mode; then
        clear
    fi

    if [[ ${v_count_successfull} -gt 0 ]]; then
        v_if_autorun_false=true
        fn_update_serial_number_of_zones
        print_task "Reloading DNS..."
        sudo podman exec tux2lab-engine rndc reload &>/dev/null
        if sudo podman exec tux2lab-engine rndc status &>/dev/null; then
            print_task_done
        else
            print_task_fail
        fi
    else
        print_yellow "No changes done! Nothing to do!"
    fi

    print_white "Please find the below details of the records:"
    if [[ "${record_stack}" == "ipv4" ]]; then
        print_white "Action-Taken     FQDN ( IPv4-Address )"
    elif [[ "${record_stack}" == "ipv6" ]]; then
        print_white "Action-Taken     FQDN ( IPv6-Address )"
    elif [[ -n "${dnsbinder_ipv6_ula_subnet}" ]]; then
        print_white "Action-Taken     FQDN ( IPv4-Address, IPv6-Address )"
    else
        print_white "Action-Taken     FQDN ( IPv4-Address )"
    fi

    cat "${v_tmp_file_dnsbinder}"

    # Final completion summary
    print_cyan "######################(DNS-Bulk-Records-Maker-with-IP)#############################"
    print_cyan "###################################( Completed )###################################"
    print_white "Total      : ${v_total_host_records} host records processed"
    print_green "Successful : ${v_count_successfull}"
    print_red "Failed     : ${v_count_failed}"

    if [[ ${v_count_failed} -gt 0 ]]; then
        print_white "Failure Breakdown:"
        if [[ ${v_count_invalid_host} -gt 0 ]]; then
            print_red "  Invalid Host    : ${v_count_invalid_host}"
        fi
        if [[ ${v_count_invalid_ipv4} -gt 0 ]]; then
            print_red "  Invalid IPv4    : ${v_count_invalid_ipv4}"
        fi
        if [[ ${v_count_already_exists} -gt 0 ]]; then
            print_yellow "  Already Exists  : ${v_count_already_exists}"
        fi
        if [[ ${v_count_ip_exhausted} -gt 0 ]]; then
            print_red "  IP Exhausted    : ${v_count_ip_exhausted}"
        fi
        if [[ ${v_count_other_failures} -gt 0 ]]; then
            print_red "  Other Failures  : ${v_count_other_failures}"
        fi
    fi

    rm -f "${v_tmp_file_dnsbinder}"

    fn_release_zone_lock
}

fn_handle_multiple_host_record() {      

    if ! fn_acquire_zone_lock; then return 1; fi

    v_host_list_file="${1}"
    v_action_required="${2}"
    local _verb="${v_action_required%e}"; v_action_verb="${_verb^}ing"
    local v_auto_confirm="${3:-}"

    if ! $inline_mode; then
        clear
    fi

    fn_progress_title() {
    
        if [[ ${v_action_required} == "create" ]]
        then
            print_cyan "#############################(DNS-Bulk-Records-Maker)##############################"

        elif [[ ${v_action_required} == "delete" ]]
        then
            print_cyan "###########################(DNS-Bulk-Records-Destroyer)############################"
        fi
    }

    fn_progress_title
    
    if [[ -z "${v_host_list_file}" ]]
    then
        echo
        print_notify "Name of the file containing the list of host records to ${v_action_required} : " 
        read -e v_host_list_file
    fi
    
    if [[ ! -f "${v_host_list_file}" ]];then print_error "File \"${v_host_list_file}\" doesn't exist!\n";fn_release_zone_lock;exit;fi 
    
    if [[ ! -s "${v_host_list_file}" ]];then print_error "File \"${v_host_list_file}\" is empty!\n";fn_release_zone_lock;exit;fi
    
    # Work on a copy to avoid modifying the user's original file
    local v_work_file
    v_work_file="$(mktemp /tmp/dnsbinder-bulk.XXXXXXXXXX)"
    cp "${v_host_list_file}" "${v_work_file}"
    
    sed -i '/^[[:space:]]*$/d' "${v_work_file}"
    
    sed -i "s/\.${v_domain_name}\.//g" "${v_work_file}"
    
    sed -i "s/\.${v_domain_name}//g" "${v_work_file}"
    
    
    if [[ "${v_auto_confirm}" == "-y" ]]; then
        local v_total_preview
        v_total_preview=$(wc -l < "${v_work_file}")
        print_info "Auto-confirmed: ${v_action_verb} ${v_total_preview} host records..."
    else
        while :
        do
            print_info "Records to be ${v_action_required^}d : "
        
            cat "${v_work_file}"
        
            echo
            print_notify "Provide your confirmation to ${v_action_required} the above host records (y/n) : " "nskip"
            
            read v_confirmation
        
            if [[ ${v_confirmation} == "y" ]]
            then
                break
        
            elif [[ ${v_confirmation} == "n" ]]
            then
                print_error "Cancelled without any changes !!"
                fn_release_zone_lock
                exit
            else
                print_error "Select either (y/n) only !"
                continue
            fi
        done
    fi
    
    > "${v_tmp_file_dnsbinder}"
    
    v_count_successfull=0
    v_count_failed=0
    v_count_invalid_host=0
    v_count_already_exists=0
    v_count_doesnt_exist=0
    v_count_ip_exhausted=0
    v_count_other_failures=0
    
    v_total_host_records=$(wc -l < "${v_work_file}")
    
    v_host_count=0
    
    # Show initial header once
    if ! $inline_mode; then
        clear
        fn_progress_title
    else
        print_info "${v_action_verb} ${v_total_host_records} host records..."
    fi
    
    while read -r v_host_record
    do
        # Update progress header in place (move cursor to top)
        if ! $inline_mode; then
            tput cup 1 0
            print_cyan "####################################( Running )####################################"
            print_white "Status     : [ ${v_host_count}/${v_total_host_records} ] host records have been processed"
            print_green "Successful : ${v_count_successfull}"
            print_red "Failed     : ${v_count_failed}"
        fi
        
        ((v_host_count++))
        
        local _bulk_label="host"
        local _delete_type=""
        if [[ ${v_action_required} == "create" ]]; then
            [[ "${record_stack}" == "ipv4" ]] && _bulk_label="IPv4-only host"
            [[ "${record_stack}" == "ipv6" ]] && _bulk_label="IPv6-only host"
        elif [[ ${v_action_required} == "delete" ]]; then
            if grep -q "^${v_host_record} .*IN CNAME" "${v_fw_zone}" 2>/dev/null; then
                _bulk_label="CNAME"
                _delete_type="cname"
            elif ! grep -q "^${v_host_record} .*IN A " "${v_fw_zone}" 2>/dev/null && grep -q "^${v_host_record} .*IN AAAA" "${v_fw_zone}" 2>/dev/null; then
                _bulk_label="IPv6-only host"
                _delete_type="ipv6"
            else
                _delete_type="dual"
            fi
        fi
        print_task "${v_action_verb} ${_bulk_label} record ${v_host_record}.${v_domain_name}..." "nskip"
    
        if [[ ${v_action_required} == "create" ]]
                then
            if [[ "${record_stack}" == "ipv6" ]]; then
                fn_create_ipv6_only_record "${v_host_record}" "Automated-Execution"
            else
                fn_create_host_record "${v_host_record}" "Automated-Execution"
            fi
            var_exit_status=${?}

        elif [[ ${v_action_required} == "delete" ]]
        then
            if [[ "${_delete_type}" == "cname" ]]; then
                sed -i "/^${v_host_record} / {/IN CNAME/d}" "${v_fw_zone}"
                var_exit_status=0
            elif [[ "${_delete_type}" == "ipv6" ]]; then
                fn_delete_ipv6_only_record "${v_host_record}" "Automated-Execution"
                var_exit_status=${?}
            else
                fn_delete_host_record "${v_host_record}" -y "Automated-Execution"
                var_exit_status=${?}
            fi
        fi
    
            v_fqdn="${v_host_record}.${v_domain_name}"
    
            
        if [[ ${v_action_required} == "create" ]]
        then
            v_ip_address=$(awk -v host="^${v_host_record} " '$0 ~ host && /IN A / {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")
            v_ipv6_address=$(awk -v host="^${v_host_record} " '$0 ~ host && /IN AAAA / {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")
    
                if [[ -n "${v_ip_address}" ]] && [[ -n "${v_ipv6_address}" ]]; then
                    v_address_display="IPv4: ${v_ip_address}, IPv6: ${v_ipv6_address}"
                elif [[ -n "${v_ip_address}" ]]; then
                    v_address_display="IPv4: ${v_ip_address}"
                elif [[ -n "${v_ipv6_address}" ]]; then
                    v_address_display="IPv6: ${v_ipv6_address}"
                else
                    v_address_display="N/A"
                fi
        fi
    
        if [[ ${v_action_required} == "create" ]]
        then
            v_details_of_host_record="${v_fqdn} ( ${v_address_display} )"

        elif [[ ${v_action_required} == "delete" ]]
        then
            v_details_of_host_record="${v_fqdn}"
        fi
            
    if [[ ${var_exit_status} -eq 9 ]]
    then
            print_red "Invalid-Host     ${v_details_of_host_record}" >> "${v_tmp_file_dnsbinder}"
        print_task_fail
        ((v_count_failed++))
        ((v_count_invalid_host++))

    elif [[ ${var_exit_status} -eq 8 ]]
    then
        if [[ ${v_action_required} == "create" ]]
                then
            v_existence_state="Already-Exists  "

        elif [[ ${v_action_required} == "delete" ]]
        then
            v_existence_state="Doesn't-Exist   "
        fi

            print_yellow "${v_existence_state} ${v_details_of_host_record}" >> "${v_tmp_file_dnsbinder}"
        print_task_fail
        ((v_count_failed++))
        if [[ ${v_action_required} == "create" ]]; then
        ((v_count_already_exists++))
        else
        ((v_count_doesnt_exist++))
        fi

    elif [[ ${var_exit_status} -eq 255 ]]
    then
            print_red "IP-Exhausted     ${v_details_of_host_record}" >> "${v_tmp_file_dnsbinder}"
        print_task_fail
        ((v_count_failed++))
        ((v_count_ip_exhausted++))
    else
        local _record_exists=false
        if [[ ${v_action_required} == "create" ]]; then
            grep -q "^${v_host_record} " "${v_fw_zone}" 2>/dev/null && _record_exists=true
        elif [[ ${v_action_required} == "delete" ]]; then
            ! grep -q "^${v_host_record} " "${v_fw_zone}" 2>/dev/null && _record_exists=true
        fi

        if $_record_exists; then
            print_green "${v_action_required^}d          ${v_details_of_host_record}" >> "${v_tmp_file_dnsbinder}"
            print_task_done
        ((v_count_successfull++))
        else
                print_red "Failed-to-${v_action_required^} ${v_details_of_host_record}" >> "${v_tmp_file_dnsbinder}"
            print_task_fail
        ((v_count_failed++))
        ((v_count_other_failures++))
        fi
    fi

    # Clear from cursor to end of screen for next iteration
    if ! $inline_mode; then
        tput ed
    fi
    
    done < "${v_work_file}"

    rm -f "${v_work_file}"

    # Clear the progress display before showing final summary
    if ! $inline_mode; then
        clear
    fi

    if [[ ${v_count_successfull} -gt 0 ]]
    then
        v_if_autorun_false=true
        fn_update_serial_number_of_zones
        print_task "Reloading DNS..."
    
        sudo podman exec tux2lab-engine rndc reload &>/dev/null
    
        if sudo podman exec tux2lab-engine rndc status &>/dev/null;
        then 
            print_task_done
        else
            print_task_fail
        fi
    else
        print_yellow "No changes done! Nothing to do!"
    fi
        
    print_white "Please find the below details of the records:"

    if [[ ${v_action_required} == "create" ]]
    then
        if [[ "${record_stack}" == "ipv4" ]]; then
            print_white "Action-Taken     FQDN ( IPv4-Address )"
        elif [[ "${record_stack}" == "ipv6" ]]; then
            print_white "Action-Taken     FQDN ( IPv6-Address )"
        elif [[ -n "${dnsbinder_ipv6_ula_subnet}" ]]; then
            print_white "Action-Taken     FQDN ( IPv4-Address, IPv6-Address )"
        else
            print_white "Action-Taken     FQDN ( IPv4-Address )"
        fi

    elif [[ ${v_action_required} == "delete" ]]
    then
        print_white "Action-Taken     FQDN"
    fi
    
    cat "${v_tmp_file_dnsbinder}"
    
    # Final completion summary with title and breakdown
    fn_progress_title
    print_cyan "###################################( Completed )###################################"
    print_white "Total      : ${v_total_host_records} host records processed"
    print_green "Successful : ${v_count_successfull}"
    print_red "Failed     : ${v_count_failed}"
    
    # Show failure breakdown if there were failures
    if [[ ${v_count_failed} -gt 0 ]]; then
        print_white "Failure Breakdown:"
        if [[ ${v_count_invalid_host} -gt 0 ]]; then
            print_red "  Invalid Host    : ${v_count_invalid_host}"
        fi
        if [[ ${v_count_already_exists} -gt 0 ]]; then
            print_yellow "  Already Exists  : ${v_count_already_exists}"
        fi
        if [[ ${v_count_doesnt_exist} -gt 0 ]]; then
            print_yellow "  Doesn't Exist   : ${v_count_doesnt_exist}"
        fi
        if [[ ${v_count_ip_exhausted} -gt 0 ]]; then
            print_red "  IP Exhausted    : ${v_count_ip_exhausted}"
        fi
        if [[ ${v_count_other_failures} -gt 0 ]]; then
            print_red "  Other Failures  : ${v_count_other_failures}"
        fi
    fi
    
    rm -f "${v_tmp_file_dnsbinder}"

    fn_release_zone_lock
}

fn_get_cname_record() {

    v_action_requested="${1}"

    fn_get_cname_record_from_user() {
        while :
        do
            if [[ -z "${v_input_cname}" ]]
            then
                if [[ "${v_action_requested}" == "create" ]]
                then
                    read -p "Please Enter the name of CNAME record to ${v_action_requested} : " v_input_cname
                elif  [[ "${v_action_requested}" == "delete" ]]
                then
                    read -p "Please Enter the name of CNAME record to ${v_action_requested} : " v_input_cname
                fi
            fi
                
            v_input_cname="${v_input_cname%.${v_domain_name}.}"  
            v_input_cname="${v_input_cname%.${v_domain_name}}"

            if [[ ! "${#v_input_cname}" -le 63 ]] || [[ ! "${v_input_cname}" =~ ^[[:alnum:]]([[:alnum:]-]*[[:alnum:]])?$ ]]
                then
                fn_instruct_on_valid_host_record
            fi

            break
        done
    }

    fn_get_hostname_record_from_user() {
        while :
        do
            if [[ -z "${v_input_hostname}" ]]
            then
                read -p "Please Enter the host record to which CNAME \"${v_input_cname}\" is required : " v_input_hostname
            fi
                
            v_input_hostname="${v_input_hostname%.${v_domain_name}.}"  
            v_input_hostname="${v_input_hostname%.${v_domain_name}}"

            if [[ ! "${#v_input_hostname}" -le 63 ]] || [[ ! "${v_input_hostname}" =~ ^[[:alnum:]]([[:alnum:]-]*[[:alnum:]])?$ ]]
                then
                fn_instruct_on_valid_host_record
            fi

            break
        done
    }

    fn_get_cname_record_from_user

    if [[ "${v_action_requested}" == "create" ]]
    then
        if grep -q "^${v_input_cname} " <<< "$(sed -n '/;CNAME-Records/,$p' "${v_fw_zone}")"
        then 
            print_error "CNAME record for \"${v_input_cname}.${v_domain_name}\" already exists! "
            exit 1

        elif grep -q "^${v_input_cname} "  <<< "$(sed -n '/;A-Records/,/;CNAME-Records/{//!p;}' "${v_fw_zone}")"
        then
            print_error "Conflict! Already a host record exists with the same name of CNAME \"${v_input_cname}.${v_domain_name}\" ! "
            exit 1
        fi

        fn_get_hostname_record_from_user

        if ! grep -q "^${v_input_hostname} "  <<< "$(sed -n '/;A-Records/,/;CNAME-Records/{//!p;}' "${v_fw_zone}")"
        then
            print_error "Provided host record \"${v_input_hostname}.${v_domain_name}\" doesn't exist to create CNAME \"${v_input_cname}.${v_domain_name}\" ! "
            exit 1
        fi
    fi

    if [[ "${v_action_requested}" == "delete" ]]
    then
        if ! grep -q "^${v_input_cname} " <<< "$(sed -n '/;CNAME-Records/,$p' "${v_fw_zone}")"
        then 
            print_error "CNAME record for ${v_input_cname}.${v_domain_name} doesn't exist! "
            exit 1
        fi
    fi
}

fn_create_cname_record() {
    v_input_cname="${1}"
    v_input_hostname="${2}"
    v_if_autorun_false=true
    
    if ! fn_acquire_zone_lock; then return 1; fi

    fn_get_cname_record "create"

    print_task "Creating CNAME record \"${v_input_cname}.${v_domain_name}\" for the host record \"${v_input_hostname}.${v_domain_name}\"..."

    v_cname_adjusted_space=$(printf "%-*s" 63 "${v_input_cname}")

    local cname_ttl_field=""
    [[ -n "${record_ttl}" ]] && cname_ttl_field="${record_ttl} "
    v_cname_record="${v_cname_adjusted_space} ${cname_ttl_field}IN CNAME ${v_input_hostname}.${v_domain_name}."

    sed -i "/^;CNAME-Records/a \\${v_cname_record}" "${v_fw_zone}"

    print_task_done

    fn_update_serial_number_of_zones "forward-zone-only"

    fn_reload_named_dns_service "true"

    fn_release_zone_lock
}

fn_delete_cname_record() {
    v_input_cname="${1}"
    v_input_delete_confirmation="${2}"
    v_if_autorun_false=true

    if ! fn_acquire_zone_lock; then return 1; fi

    fn_get_cname_record "delete"

    while :
    do
        local cname_target
        cname_target=$(dig @"${dnsbinder_server_ipv4_address}" +short CNAME "${v_input_cname}.${v_domain_name}" 2>/dev/null | head -1 | sed 's/\.$//' || true)
        print_warning "CNAME Record to be deleted : ${v_input_cname}.${v_domain_name} is an alias for ${cname_target}"
        if [[ ! ${v_input_delete_confirmation} == "-y" ]]
        then
            read -p "Please confirm deletion of cname record \"${v_input_cname}.${v_domain_name}\" (y/n) : " v_confirmation
        else
            v_confirmation='y'
        fi

        case "${v_confirmation}" in
            y|Y|"yes")
                break
                ;;
            n|N|"no")
                print_warning "Aborted ! No changes done! "
                fn_release_zone_lock
                return 0
                ;;
            "")
                print_error "No Input Provided! "
                continue
                ;;
            *)
                print_error "Invalid Input! "
                continue
                ;;
        esac
    done

    print_task "Deleting CNAME record \"${v_input_cname}.${v_domain_name}\"..."

    sed -i "/^${v_input_cname} / {/IN CNAME/d}" "${v_fw_zone}" 

    print_task_done

    fn_update_serial_number_of_zones "forward-zone-only"

    fn_reload_named_dns_service "true"

    fn_release_zone_lock
}

v_domain_if_present=$(if [[ -n "${v_domain_name}" ]];then echo -n "${v_domain_name}";else echo '[dnsbinder-not-yet-configured]';fi)
v_domain_if_present=$(printf "%-*s" 53 "${v_domain_if_present}")
v_network_if_present=$(if [[ -n "${dnsbinder_network}" ]];then echo -n "${dnsbinder_network}";else echo '[dnsbinder-not-yet-configured]';fi)
v_network_if_present=$(printf "%-*s" 53 "${v_network_if_present}")
v_ipv6_if_present=$(if [[ -n "${dnsbinder_ipv6_ula_subnet}" ]];then echo -n "${dnsbinder_ipv6_ula_subnet}";else echo '[ipv6-not-configured]';fi)
v_ipv6_if_present=$(printf "%-*s" 53 "${v_ipv6_if_present}")

fn_main_menu() {

while true; do

print_notify "##################################################################
#-------------------------[ DNS-BINDER ]-------------------------#
# Domain  : ${v_domain_if_present}#
# IPv4 Net: ${v_network_if_present}#
# IPv6 Net: ${v_ipv6_if_present}#
#----------------------------------------------------------------#
# 1) Create a DNS host record (dual-stack A + AAAA)              #
# 2) Create an IPv4-only host record (A record only)             #
# 3) Create an IPv6-only host record (AAAA only, offset 1023+)   #
# 4) Create a DNS host with specific IPv4 (auto-generates IPv6)  #
# 5) Create a CNAME/Alias record for existing host record        #
# 6) Delete a DNS record (auto-detects: host/CNAME/IPv6-only)    #
# 7) Rename an existing DNS host record                          #
# 8) Query a DNS record                                          #
# 9) Update TTL for an existing host record                      #
#----------------------------------------------------------------#
# 10) Create multiple DNS host records from a file               #
# 11) Delete multiple DNS records from a file (auto-detects)     #
#----------------------------------------------------------------#
# 0) Configure local dns server and domain (dual-stack)          #
#----------------------------------------------------------------#
# q) Quit without any changes                                    #
#----------------------------------------------------------------#"

read -p "# Please select one of the options above : " var_function

case ${var_function} in
    0)  
        fn_configure_named_dns_server
        exit
        ;;
    1)
        fn_check_existence_of_domain
        fn_create_host_record
        exit
        ;;
    2)
        fn_check_existence_of_domain
        record_stack="ipv4"
        fn_create_host_record
        exit
        ;;
    3)
        fn_check_existence_of_domain
        fn_create_ipv6_only_record ""
        exit
        ;;
    4)
        fn_check_existence_of_domain
        specific_ipv4_requested="yes"
        fn_create_host_record
        exit
        ;;
    5)
        fn_check_existence_of_domain
        fn_create_cname_record
        exit
        ;;
    6)
        fn_check_existence_of_domain
        echo ""
        read -rp "Enter hostname to delete: " _menu_del_host
        if [[ -z "$_menu_del_host" ]]; then
            print_error "No hostname provided."
        else
            _menu_del_host="${_menu_del_host%.${v_domain_name}}"
            if grep -q "^${_menu_del_host} .*IN CNAME" "${v_fw_zone}" 2>/dev/null; then
                fn_delete_cname_record "${_menu_del_host}"
            elif ! grep -q "^${_menu_del_host} .*IN A " "${v_fw_zone}" 2>/dev/null && grep -q "^${_menu_del_host} .*IN AAAA" "${v_fw_zone}" 2>/dev/null; then
                fn_delete_ipv6_only_record "${_menu_del_host}"
            else
                fn_delete_host_record "${_menu_del_host}"
            fi
        fi
        exit
        ;;
    7)
        fn_check_existence_of_domain
        fn_rename_host_record
        exit
        ;;
    8)
        fn_check_existence_of_domain
        fn_query_record
        exit
        ;;
    9)
        fn_check_existence_of_domain
        fn_update_record_ttl
        exit
        ;;
    10)
        fn_check_existence_of_domain
        fn_handle_multiple_host_record "" "create"
        exit
        ;;
    11)
        fn_check_existence_of_domain
        fn_handle_multiple_host_record "" "delete"
        exit
        ;;
    q)
        exit
        ;;
    *)
        print_error "Invalid Option! Try Again! "
        continue
        ;;
esac
done
}


fn_usage_message() {
print_notify "Domain   : ${v_domain_if_present}
IPv4 Net : ${v_network_if_present}
IPv6 Net : ${v_ipv6_if_present}

Usage: dnsbinder [ option ] [ arguments ]
Use one of the following Options :
    -c,    --create              To create a host record (dual-stack: A + AAAA records)
    -c4                          To create an IPv4-only host record (A record only)
    -c6                          To create an IPv6-only host record (AAAA record only, offset 1023+)
    -d,    --delete              To delete a record (auto-detects: host, CNAME, or IPv6-only)
    -dy                          caution ! To do the above without any confirmation
    -r,    --rename              To rename an existing host record (updates A and AAAA records)
    -ry                          caution ! To do the above without any confirmation
    -cf,   --create-from-file    To create multiple host records provided in a file (dual-stack)
    -cfy                         caution ! To do the above without any confirmation
    -c4f                         To create multiple IPv4-only host records from a file
    -c4fy                        caution ! To do the above without any confirmation
    -c6f                         To create multiple IPv6-only host records from a file
    -c6fy                        caution ! To do the above without any confirmation
    -cif,  --create-with-ip-file To create multiple host records with specific IPs from a file (hostname ipv4)
    -cify                        caution ! To do the above without any confirmation
    -df,   --delete-from-file    To delete multiple records provided in a file (auto-detects type)
    -dfy                         caution ! To do the above without any confirmation
    -ci,   --create-with-ip      To create a host record with specific IPv4 Address (auto-generates IPv6)
    -cc,   --create-cname        To create a CNAME/Alias record for an existing host record
    -q,    --query               Lookup any record and display all its relevant records
    -y,    --yes                 Append to any command to skip confirmation prompts
    --inline                     Suppress TUI (no screen clear/cursor control) for bulk operations
    --setup                      To configure local dns server and domain (dual-stack IPv4/IPv6)
                                 Both IPv4 and IPv6 networks are auto-detected from system
                                 Usage: dnsbinder --setup <domain>
                                 Example: dnsbinder --setup tux2lab.internal
    --reconfigure                Regenerate named.conf from template (preserves zone files)
    --update-ttl <host> <sec>    Update TTL for an existing host record (A + AAAA + PTR)
    --ttl <seconds>              Set TTL when creating a record (use with -c, -ci, -cc)
    -h,    --help                To print this usage info 

Note: All host record operations automatically create/manage both IPv4 (A) and IPv6 (AAAA) records

[ Or ]
Run dnsbinder utility without any arguments to get menu driven actions."
}

auto_confirm=""
inline_mode=false
record_ttl=""
record_stack="dual"
specific_ipv4_requested=""

if [[ -n "${1}" ]]
then
    args=("$@")
    for i in "${!args[@]}"; do
        if [[ "${args[$i]}" == "--yes" || "${args[$i]}" == "-y" ]] && [[ $i -gt 0 ]]; then
            auto_confirm="-y"
            unset 'args[$i]'
        elif [[ "${args[$i]}" == "--inline" ]] && [[ $i -gt 0 ]]; then
            inline_mode=true
            unset 'args[$i]'
        elif [[ "${args[$i]}" == "--ttl" ]] && [[ -n "${args[$((i+1))]:-}" ]]; then
            if ! [[ "${args[$((i+1))]}" =~ ^[0-9]+$ ]]; then
                print_error "TTL must be a positive integer (seconds). Got: '${args[$((i+1))]}'"
                exit 1
            fi
            record_ttl="${args[$((i+1))]}"
            unset 'args[$i]'
            unset 'args[$((i+1))]'
        elif [[ "${args[$i]}" == "--ipv4-only" ]]; then
            record_stack="ipv4"
            unset 'args[$i]'
        elif [[ "${args[$i]}" == "--ipv6-only" ]]; then
            record_stack="ipv6"
            unset 'args[$i]'
        fi
    done
    set -- "${args[@]}"

    # Handle comma-separated records by re-invoking self per item
    if [[ "${2:-}" == *,* ]] && [[ "${1}" =~ ^(-c|--create|-c4|-c6|-d|--delete|-dy|-q|--query)$ ]]; then
        IFS=',' read -ra _items <<< "${2}"
        _flag="${1}"

        # For delete operations (not already auto-confirmed), prompt once for the batch
        if [[ "${_flag}" =~ ^(-d|--delete)$ ]] && [[ -z "${auto_confirm}" ]]; then
            echo ""
            print_info "Records to be deleted:"
            for _item in "${_items[@]}"; do
                [[ -z "${_item}" ]] && continue
                echo "  - ${_item}.${v_domain_name}"
            done
            echo ""
            while :; do
                read -p "Please confirm deletion of the above records (y/n) : " _confirm
                case "${_confirm}" in
                    y|Y) break ;;
                    n|N) print_warning "Cancelled without any changes ! "; exit 0 ;;
                    *) print_error "Select only either (y/n) ! " ;;
                esac
            done
        fi

        # Convert -d → -dy for self-invocations (already confirmed)
        [[ "${_flag}" == "-d" || "${_flag}" == "--delete" ]] && _flag="-dy"

        _rc=0
        for _item in "${_items[@]}"; do
            [[ -z "${_item}" ]] && continue
            if [[ -n "${record_ttl}" ]]; then
                "$0" "${_flag}" "${_item}" --ttl "${record_ttl}" || _rc=1
            else
                "$0" "${_flag}" "${_item}" || _rc=1
            fi
        done
        exit ${_rc}
    fi

    case "${1}" in
        -c|--create)
            fn_check_existence_of_domain
            if [[ -n "${3}" ]];then
                print_error "Invalid Option! '${1}' option takes only 1 argument as hostname ! "
                fn_usage_message
                exit 1
            fi
            fn_create_host_record "${2}"
            exit
            ;;
        -c4)
            fn_check_existence_of_domain
            if [[ -n "${3}" ]];then
                print_error "Invalid Option! '${1}' option takes only 1 argument as hostname ! "
                fn_usage_message
                exit 1
            fi
            record_stack="ipv4"
            fn_create_host_record "${2}"
            exit
            ;;
        -c6)
            fn_check_existence_of_domain
            if [[ -n "${3}" ]];then
                print_error "Invalid Option! '${1}' option takes only 1 argument as hostname ! "
                fn_usage_message
                exit 1
            fi
            record_stack="ipv6"
            fn_create_ipv6_only_record "${2}"
            exit
            ;;
        -d|--delete|-dy)
            fn_check_existence_of_domain
            if [[ -n "${3}" ]]; then
                print_error " Invalid Option! ${1} option takes only 1 argument as hostname ! "
                fn_usage_message
                exit 1
            fi
            _del_host="${2}"
            _del_host="${_del_host%.${v_domain_name}}"
            _is_cname=false
            _is_ipv6_only=false
            grep -q "^${_del_host} .*IN CNAME" "${v_fw_zone}" 2>/dev/null && _is_cname=true
            if ! $_is_cname && ! grep -q "^${_del_host} .*IN A " "${v_fw_zone}" 2>/dev/null && grep -q "^${_del_host} .*IN AAAA" "${v_fw_zone}" 2>/dev/null; then
                _is_ipv6_only=true
            fi
            _auto_flag=""
            [[ "${1}" == "-dy" || -n "$auto_confirm" ]] && _auto_flag="-y"
            if $_is_cname; then
                fn_delete_cname_record "${2}" ${_auto_flag}
            elif $_is_ipv6_only; then
                fn_delete_ipv6_only_record "${2}" ${_auto_flag}
            else
                fn_delete_host_record "${2}" ${_auto_flag}
            fi
            exit
            ;;
        -r|--rename|-ry)
            fn_check_existence_of_domain
            if [[ -n "${4}" ]];then
                print_error "Invalid Option! ${1} option takes only 2 arguments [ existing host record and new host record ] ! "
                fn_usage_message
                exit 1
            fi
            if [[ "${1}" == "-ry" || -n "$auto_confirm" ]];then
                fn_rename_host_record "${2}" "${3}" "-y"
            else
                fn_rename_host_record "${2}" "${3}"
            fi
            exit
            ;;
        -cf|--create-from-file|-cfy)
            fn_check_existence_of_domain
            if [[ -n "${3}" ]];then
                print_error "Invalid Option! '${1}' option takes only 1 argument as file containing list of hostnames ! "
                fn_usage_message
                exit 1
            fi
            if [[ "${1}" == "-cfy" || -n "$auto_confirm" ]]; then
                fn_handle_multiple_host_record "${2}" "create" "-y"
            else
                fn_handle_multiple_host_record "${2}" "create"
            fi
            exit
            ;;
        -c4f|-c4fy)
            fn_check_existence_of_domain
            if [[ -n "${3}" ]];then
                print_error "Invalid Option! '${1}' option takes only 1 argument as file containing list of hostnames ! "
                fn_usage_message
                exit 1
            fi
            record_stack="ipv4"
            if [[ "${1}" == "-c4fy" || -n "$auto_confirm" ]]; then
                fn_handle_multiple_host_record "${2}" "create" "-y"
            else
                fn_handle_multiple_host_record "${2}" "create"
            fi
            exit
            ;;
        -c6f|-c6fy)
            fn_check_existence_of_domain
            if [[ -n "${3}" ]];then
                print_error "Invalid Option! '${1}' option takes only 1 argument as file containing list of hostnames ! "
                fn_usage_message
                exit 1
            fi
            record_stack="ipv6"
            if [[ "${1}" == "-c6fy" || -n "$auto_confirm" ]]; then
                fn_handle_multiple_host_record "${2}" "create" "-y"
            else
                fn_handle_multiple_host_record "${2}" "create"
            fi
            exit
            ;;
        -cif|--create-with-ip-file|-cify)
            fn_check_existence_of_domain
            if [[ -n "${3}" ]];then
                print_error "Invalid Option! '${1}' option takes only 1 argument as file containing list of 'hostname ipv4' pairs ! "
                fn_usage_message
                exit 1
            fi
            if [[ "${1}" == "-cify" || -n "$auto_confirm" ]]; then
                fn_handle_multiple_host_record_with_ip "${2}" "-y"
            else
                fn_handle_multiple_host_record_with_ip "${2}"
            fi
            exit
            ;;
        -df|--delete-from-file|-dfy)
            fn_check_existence_of_domain
            if [[ -n "${3}" ]];then
                print_error "Invalid Option! '${1}' option takes only 1 argument as file containing list of hostnames ! "
                fn_usage_message
                exit 1
            fi
            if [[ "${1}" == "-dfy" || -n "$auto_confirm" ]]; then
                fn_handle_multiple_host_record "${2}" "delete" "-y"
            else
                fn_handle_multiple_host_record "${2}" "delete"
            fi
            exit
            ;;
        -ci|--create-with-ip)
            fn_check_existence_of_domain 
            if [[ -n "${4}" ]];then
                print_error "Invalid Option! '${1}' option takes only 2 arguments [ hostname and required ipv4 address ] ! "
                fn_usage_message
                exit 1
            fi
            specific_ipv4_requested="yes"
            fn_create_host_record "${2}" "${3}"
            exit
            ;;
        -cc|--create-cname)
            fn_check_existence_of_domain 
            if [[ -n "${4}" ]];then
                print_error "Invalid Option! '${1}' option takes only 2 arguments [ cname and hostname ] ! "
                fn_usage_message
                exit 1
            fi
            fn_create_cname_record "${2}" "${3}"
            exit
            ;;
        --setup)
            fn_configure_named_dns_server "${2}"
            exit
            ;;
        --reconfigure)
            fn_reconfigure_named
            exit
            ;;
        --update-ttl)
            fn_check_existence_of_domain
            if [[ -z "${2:-}" || -z "${3:-}" ]]; then
                print_error "Usage: dnsbinder --update-ttl <hostname> <ttl_seconds>"
                exit 1
            fi
            fn_update_record_ttl "${2}" "${3}"
            exit
            ;;
        -q|--query)
            fn_check_existence_of_domain
            fn_query_record "${2:-}"
            exit
            ;;
        *)
            if [[ ! "${1}" =~ ^(-h|--help)$ ]]
            then
                print_error "Invalid Option \"${1}\"! "
            fi
            fn_usage_message
            exit 1
            ;;
    esac
else
    fn_main_menu
fi
