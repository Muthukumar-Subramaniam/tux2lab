#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#

source /tux2lab/common-utils/color-functions.sh

# Source environment variables for IPv6 dual-stack support
if [[ -f /etc/environment ]]; then
    source /etc/environment
fi

if [[ "${UID}" -ne 0 ]]
then
    print_error "Run with sudo or run from root account ! "
    exit 1
fi


v_tmp_file_dnsbinder="$(mktemp /tmp/dnsbinder.XXXXXXXXXX)"

v_domain_name=$(if [[ -f /etc/named.conf ]];then awk '/zones-are-managed-by-dnsbinder/ {print $2}' /etc/named.conf;fi)
dnsbinder_network=$(if [[ -f /etc/named.conf ]];then awk '/dnsbinder-network/ {print $3}' /etc/named.conf;fi)
var_zone_dir='/var/named/dnsbinder-managed-zone-files'
v_fw_zone="${var_zone_dir}/${v_domain_name}-forward.db"

#--- File Locking Mechanism (mkdir-based spinlock with PID tracking) ---#

dnsbinder_lock_dir="/var/named/.dnsbinder-zone.lock"
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
print_warning "FYI :
  > Only allowed TLD is 'local' .
  > Maximum 2 subdomains are only allowed.
  > Only letters, numbers, and hyphens are allowed with subdomains.
  > Hyphens cannot appear at the start or end of the subdomains.
  > The total length must be between 1 and 63 characters.
  > Follows the format defined in RFC 1035.
  > Examples for Valid Domain Names :
      test.local, test.example.local, 123-example.local, test-lab1.local
      123.example.local, test1.lab1.local, test-1.example-1.local"
}

fn_configure_named_dns_server() {

    # Get the directory where dnsbinder script is located (resolve symlinks)
    v_script_path="${BASH_SOURCE[0]}"
    while [ -L "${v_script_path}" ]; do
        v_script_path="$(readlink -f "${v_script_path}")"
    done
    v_script_dir="$(cd "$(dirname "${v_script_path}")" && pwd)"

    KVM_HOST_MODE_SET=false
    if ip link show labbr0 &>/dev/null; then
        KVM_HOST_MODE_SET=true
    fi

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
            
        if [[ "${#v_given_domain}" -le 63 ]] && [[ "${v_given_domain}" =~ ^[[:alnum:]]+([-.][[:alnum:]]+)*(\.[[:alnum:]]+){0,2}\.local$ ]]
        then
            break
        else
            v_given_domain=""
            fn_instruct_on_valid_domain_name
            continue
        fi
    done

    print_task "Fetching network information from the system..."

    if [[ "${KVM_HOST_MODE_SET}" == "true" ]]; then
        source /tux2lab-data/lab_environment_vars
        v_dns_host_short_name="${lab_infra_server_hostname%%.*}"
        v_primary_interface='labbr0'
        v_primary_ip=$lab_infra_server_ipv4_address
        
        if [[ -z "${v_primary_ip}" ]]; then
            print_error "Critical: lab_infra_server_ipv4_address is not defined in /tux2lab-data/lab_environment_vars."
            print_error "DNS server IP address is required for dig queries."
            exit 1
        fi
        
        v_network_gateway=$lab_infra_server_ipv4_gateway
        # Extract IPv6 information for dual-stack support
        v_ipv6_address=$lab_infra_server_ipv6_address
        v_ipv6_gateway=$lab_infra_server_ipv6_gateway
        v_ipv6_prefix=$lab_infra_server_ipv6_prefix
        if [[ -z "${v_ipv6_ula_subnet}" ]]; then
            v_ipv6_ula_subnet=$lab_infra_server_ipv6_ula_subnet
        fi
    else
        v_dns_host_short_name=$(hostname -s)
        v_primary_interface=$(ip r | awk '/default/ {print $5; exit}')
        v_primary_ip=$(ip r | awk -v iface="${v_primary_interface}" '$0 !~ /default/ && $0 ~ iface {print $9; exit}')
        v_network_gateway=$(ip r | awk '/default/ {print $3; exit}')
        
        if [[ -z "${v_primary_ip}" ]]; then
            print_error "Critical: Failed to detect primary IP address from network interface."
            print_error "DNS server IP address is required for dig queries."
            exit 1
        fi
        
        # Auto-detect IPv6 from system (lab infra server VM must have IPv6 configured)
        # Try to get IPv6 from primary interface (exclude link-local fe80 and loopback ::1)
        v_ipv6_address=$(ip -6 addr show "${v_primary_interface}" | awk '/inet6 fd[0-9a-f:]+/ && !/fe80/ && !/::1/ {for(i=1;i<=NF;i++) if($i ~ /^fd/) {sub(/\/.*/, "", $i); print $i; exit}}')
        if [[ -n "${v_ipv6_address}" ]]; then
            # Extract prefix length
            v_ipv6_prefix=$(ip -6 addr show "${v_primary_interface}" | grep -oP 'fd[0-9a-f:]+/\K[0-9]+' | head -1 || true)
            # Build ULA subnet
            if [[ -n "${v_ipv6_address}" && ! -z "${v_ipv6_prefix}" ]]; then
                # Calculate the network address properly by applying the prefix mask
                v_ipv6_network=$(fn_calculate_ipv6_network "${v_ipv6_address}" "${v_ipv6_prefix}")
                v_ipv6_ula_subnet="${v_ipv6_network}/${v_ipv6_prefix}"
                # Gateway is always ::1 in the subnet (no default route needed for detection)
                v_ipv6_gateway="${v_ipv6_network%::}::1"
            fi
        fi
        
        # Verify dual-stack configuration is present on the system
        if [[ -z "${v_ipv6_ula_subnet}" ]]; then
            print_error "IPv6 configuration not found. Dual-stack (IPv4+IPv6) is required."
            print_error "Please configure IPv6 on ${v_primary_interface} before running this script."
            exit 1
        fi
    fi

    fn_split_network_into_cidr24subnets

    print_task_done

    print_task "Checking whether required bind dns packages are installed..."

    if rpm -q bind bind-utils &>/dev/null 
    then
        print_task_done
    else
        print_warning "Not yet installed"

        print_task "Installing the required bind dns packages..."

        if dnf install bind bind-utils -y &>/dev/null
        then
            print_task_done
        else
            print_task_fail
            print_error "Try installing the packages bind and bind-utils manually then try the script again!"
            exit 1
        fi
    fi

    print_task "Taking backup of named.conf..."

    cp -p /etc/named.conf /etc/named.conf_bkp_by_dnsbinder
    
    print_task_done

    print_task "Configuring named.conf from template..."

    v_template_file="${v_script_dir}/named.conf.template"
    
    if [[ ! -f "${v_template_file}" ]]; then
        print_error "Template file not found: ${v_template_file}"
        exit 1
    fi

    # Prepare listen addresses
    if [[ "${KVM_HOST_MODE_SET}" == "true" ]]; then
        v_listen_ipv4="${v_primary_ip}"
    else
        v_listen_ipv4="127.0.0.1; ${v_primary_ip}"
    fi

    if [[ -n "${v_ipv6_address}" ]]; then
        if [[ "${KVM_HOST_MODE_SET}" == "true" ]]; then
            v_listen_ipv6="${v_ipv6_address}"
        else
            v_listen_ipv6="::1; ${v_ipv6_address}"
        fi
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
            "${v_template_file}" > /etc/named.conf
    else
        # IPv6 not available - remove listen-on-v6 line entirely
        sed -e "s|LISTEN_IPV4_ADDRESSES|${v_listen_ipv4}|g" \
            -e "/listen-on-v6 port 53/d" \
            -e "s|ALLOW_QUERY_NETWORKS|${v_allow_networks}|g" \
            -e "s|ALLOW_RECURSION_NETWORKS|${v_allow_networks}|g" \
            "${v_template_file}" > /etc/named.conf
    fi

    print_task_done

    print_task "Downloading latest root hints file (named.root)..."

    # Download the latest named.root from IANA
    if curl -s -o /var/named/named.root https://www.internic.net/domain/named.root; then
        chown root:named /var/named/named.root
        chmod 640 /var/named/named.root
        print_task_done
    else
        print_warning "Failed to download named.root, using system default"
    fi

    print_task "Adding DNS zones to named.conf..."


    tee -a /etc/named.conf > /dev/null << EOF
# BEGIN zones-of-${v_given_domain}-domain
# dnsbinder-network ${v_network}/${v_cidr}$([[ -n "${v_ipv6_ula_subnet}" ]] && echo " ${v_ipv6_ula_subnet}")
# ${v_given_domain} zones-are-managed-by-dnsbinder
//Forward Zone for ${v_given_domain}
zone "${v_given_domain}" IN {
    type master;
    file "dnsbinder-managed-zone-files/${v_given_domain}-forward.db";
    allow-update { none; };
};
//Reverse Zones ms.local
EOF
    
    for v_subnet_part in ${v_splited_subnets}
    do
        if [[ -z "${v_first_subnet_part}" ]]; then
            v_first_subnet_part="${v_subnet_part}"
        fi

        v_reverse_subnet_part=$(echo "${v_subnet_part}" | awk -F. '{print $3"."$2"."$1}')
        tee -a /etc/named.conf > /dev/null << EOF
zone "${v_reverse_subnet_part}.in-addr.arpa" IN {
    type master;
    file "dnsbinder-managed-zone-files/${v_subnet_part}.${v_given_domain}-reverse.db";
    allow-update { none; };
};
EOF
        v_last_subnet_part="${v_subnet_part}"
    done

    # Add IPv6 reverse zone if IPv6 is configured
    if [[ -n "${v_ipv6_ula_subnet}" ]]; then
        # Extract IPv6 prefix for reverse zone (e.g., fd00:1234:1234:1234::/64)
        # Convert to reverse DNS format
        v_ipv6_base=$(echo "${v_ipv6_ula_subnet}" | cut -d'/' -f1 | sed 's/::$//')
        # For fd00:1234:1234:1234::, reverse is 4.3.2.1.4.3.2.1.4.3.2.1.0.0.d.f.ip6.arpa
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
        
        tee -a /etc/named.conf > /dev/null << EOF
//IPv6 Reverse Zone
zone "${v_ipv6_reverse_zone}.ip6.arpa" IN {
    type master;
    file "dnsbinder-managed-zone-files/${v_given_domain}-ipv6-reverse.db";
    allow-update { none; };
};
EOF
    fi

    echo -e "# END zones-of-${v_given_domain}-domain" | tee -a /etc/named.conf > /dev/null

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

    echo -e "${v_network_adjusted_space} IN A ${v_first_subnet_part}.0" | tee -a  "${v_zone_file_name}" > /dev/null

    v_gateway_adjusted_space=$(printf "%-*s" 63 "gateway")

    echo -e "${v_gateway_adjusted_space} IN A ${v_first_subnet_part}.1" | tee -a  "${v_zone_file_name}" > /dev/null

    v_dns_host_short_name_adjusted_space=$(printf "%-*s" 63 "${v_dns_host_short_name}")
    
    echo -e "${v_dns_host_short_name_adjusted_space} IN A ${v_primary_ip}" | tee -a "${v_zone_file_name}" > /dev/null

    v_broadcast_adjusted_space=$(printf "%-*s" 63 "broadcast")

    echo -e "${v_broadcast_adjusted_space} IN A ${v_last_subnet_part}.255" | tee -a  "${v_zone_file_name}" > /dev/null

    # Add AAAA records for IPv6 (dual-stack)
    if [[ -n "${v_ipv6_address}" ]]; then
        echo -e "\n;AAAA-Records (IPv6)" | tee -a "${v_zone_file_name}" > /dev/null
        
        v_ipv6_gateway_adjusted_space=$(printf "%-*s" 63 "gateway")
        echo -e "${v_ipv6_gateway_adjusted_space} IN AAAA ${v_ipv6_gateway}" | tee -a "${v_zone_file_name}" > /dev/null
        
        v_dns_host_short_name_adjusted_space=$(printf "%-*s" 63 "${v_dns_host_short_name}")
        echo -e "${v_dns_host_short_name_adjusted_space} IN AAAA ${v_ipv6_address}" | tee -a "${v_zone_file_name}" > /dev/null
    fi

    echo -e "\n;CNAME-Records" | tee -a "${v_zone_file_name}" > /dev/null

    for v_subnet_part in ${v_splited_subnets}
    do
        v_zone_file_name="${var_zone_dir}/${v_subnet_part}.${v_given_domain}-reverse.db"
        fn_update_dns_server_data_to_zone_file "${v_zone_file_name}"
        echo -e "\n;PTR-Records" | tee -a "${v_zone_file_name}" > /dev/null
        if [[ "${v_subnet_part}" == "${v_first_subnet_part}" ]]
        then
            echo -e "0   IN PTR network.${v_given_domain}." | tee -a "${v_zone_file_name}" > /dev/null
            echo -e "1   IN PTR gateway.${v_given_domain}." | tee -a "${v_zone_file_name}" > /dev/null
            v_get_ip_part_primary_ip=$(echo "${v_primary_ip}" | awk -F. '{print $4}')
            v_ip_part_primary_ip_adjusted_space=$(printf "%-*s" 3 "${v_get_ip_part_primary_ip}")
            echo -e "${v_ip_part_primary_ip_adjusted_space} IN PTR ${v_dns_host_short_name}.${v_given_domain}." | tee -a "${v_zone_file_name}" > /dev/null
        elif [[ "${v_subnet_part}" == "${v_last_subnet_part}" ]]
        then
            echo -e "255 IN PTR broadcast.${v_given_domain}." | tee -a "${v_zone_file_name}" > /dev/null
        fi
    done

    # Create IPv6 reverse zone file if IPv6 is configured
    if [[ -n "${v_ipv6_address}" && ! -z "${v_ipv6_ula_subnet}" ]]; then
        v_ipv6_zone_file="${var_zone_dir}/${v_given_domain}-ipv6-reverse.db"
        fn_update_dns_server_data_to_zone_file "${v_ipv6_zone_file}"
        echo -e "\n;IPv6 PTR-Records" | tee -a "${v_ipv6_zone_file}" > /dev/null
        
        # Add PTR record for gateway (::1) - only 16 nibbles for /64 host portion
        echo -e "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0 IN PTR gateway.${v_given_domain}." | tee -a "${v_ipv6_zone_file}" > /dev/null
        
        # Add PTR record for DNS server's IPv6 address
        # Convert IPv6 address to full expanded form, then extract host part and reverse it
        v_ipv6_ptr=$(python3 -c "
import ipaddress
addr = ipaddress.IPv6Address('${v_ipv6_address}')
# Get the last 64 bits (host portion for /64)
host_int = int(addr) & ((1 << 64) - 1)
# Convert to 16 hex nibbles
host_hex = format(host_int, '016x')
# Reverse nibbles with dots
ptr = '.'.join(reversed(host_hex))
print(ptr)
")
        
        if [[ -n "${v_ipv6_ptr}" ]]; then
            echo -e "${v_ipv6_ptr} IN PTR ${v_dns_host_short_name}.${v_given_domain}." | tee -a "${v_ipv6_zone_file}" > /dev/null
        fi
    fi

    print_task_done

    print_task "Enabling and starting named DNS Service..."

    systemctl enable --now named &>/dev/null    
    
    print_task_done

    print_task "Doing a final restart of named DNS Service..."

    systemctl restart named &>/dev/null 

    print_task_done

    print_task "Updating dnsbinder related global variables to /etc/environment..."
    declare -A dnsbinder_environment_map=(
        ["dnsbinder_domain"]="$v_given_domain"
        ["dnsbinder_network_cidr"]="$v_network_and_cidr"
        ["dnsbinder_cidr_prefix"]="$v_cidr"
        ["dnsbinder_first24_subnet"]="$v_first_subnet_part"
        ["dnsbinder_last24_subnet"]="$v_last_subnet_part"
        ["dnsbinder_netmask"]="$dnsbinder_netmask"
        ["dnsbinder_gateway"]="$v_network_gateway"
        ["dnsbinder_broadcast"]="${v_last_subnet_part}.255"
        ["dnsbinder_server_ipv4_address"]="$v_primary_ip"
        ["dnsbinder_server_short_name"]="$v_dns_host_short_name"
        ["dnsbinder_server_fqdn"]="${v_dns_host_short_name}.${v_given_domain}"
    )

    # Add IPv6 variables if configured
    if [[ -n "${v_ipv6_address}" ]]; then
        dnsbinder_environment_map["dnsbinder_server_ipv6_address"]="$v_ipv6_address"
        dnsbinder_environment_map["dnsbinder_ipv6_gateway"]="$v_ipv6_gateway"
        dnsbinder_environment_map["dnsbinder_ipv6_prefix"]="$v_ipv6_prefix"
        dnsbinder_environment_map["dnsbinder_ipv6_ula_subnet"]="$v_ipv6_ula_subnet"
    fi

    target_environment_file="/etc/environment"

    # Ensure the environment file exists
    touch "$target_environment_file"

    # Iterate through all key-value pairs and update or append as necessary
    for environment_key in "${!dnsbinder_environment_map[@]}"; do
        environment_value="${dnsbinder_environment_map[$environment_key]}"
        if grep -q "^${environment_key}=" "$target_environment_file"; then
            # Update existing variable line
            sed -i "s|^${environment_key}=.*|${environment_key}=\"${environment_value}\"|" "$target_environment_file"
        else
            # Append new variable if not already present
            echo "${environment_key}=\"${environment_value}\"" | tee -a "$target_environment_file" > /dev/null
        fi
    done

    source /etc/environment

    print_task_done

    if [[ "${KVM_HOST_MODE_SET}" != "true" ]]; then
        print_task "Updating Network Manager to point the local dns server and domain..."
        v_active_connection_name=$(nmcli connection show --active | awk -v iface="${v_primary_interface}" '$0 ~ iface {print $1; exit}')
        nmcli connection modify "${v_active_connection_name}" ipv4.dns-search "${v_given_domain}" &>/dev/null
        nmcli connection modify "${v_active_connection_name}" ipv4.dns "127.0.0.1,8.8.8.8,1.1.1.1"  &>/dev/null
        
        # Configure IPv6 address if dual-stack is configured (but use IPv4 for DNS)
        if [[ -n "${v_ipv6_address}" ]]; then
            nmcli connection modify "${v_active_connection_name}" ipv6.method "manual" &>/dev/null
            nmcli connection modify "${v_active_connection_name}" ipv6.addresses "${v_ipv6_address}/${v_ipv6_prefix}" &>/dev/null
            # Clear any IPv6 DNS servers (we only use IPv4 DNS)
            nmcli connection modify "${v_active_connection_name}" ipv6.dns "" &>/dev/null
        fi
        
        # Reapply settings without restarting the connection
        nmcli connection reload "${v_active_connection_name}" &>/dev/null
        nmcli device reapply "${v_primary_interface}" &>/dev/null
        print_task_done
    else
        print_task "Updating systemd-resolvd to point the local dns server and domain..."
        if command -v resolvectl &>/dev/null; then
                if [[ -n "${v_ipv6_address}" ]]; then
                    resolvectl dns labbr0 "$v_primary_ip" "$v_ipv6_address"
                else
                    resolvectl dns labbr0 "$v_primary_ip"
                fi
                resolvectl domain labbr0 "$v_given_domain"
        fi
        print_task_done
    fi

    print_task "Make named service as a dependency for network-online.target..."

    if [[ "${KVM_HOST_MODE_SET}" != "true" ]]; then
        if [[ ! -f /etc/systemd/system/network-online.target.wants/named.service ]]; then
            ln -s /usr/lib/systemd/system/named.service /etc/systemd/system/network-online.target.wants/named.service 
        fi
    fi

    print_task_done

    print_task "Creating the command dnsbinder..."

    ln -s /tux2lab/named-manage/dnsbinder.sh /usr/sbin/dnsbinder

    print_task_done

    # Display success message with dual-stack info if configured
    if [[ -n "${v_ipv6_address}" ]]; then
        print_success "All done! Your domain \"${v_given_domain}\" with dual-stack DNS server IPv4: ${v_primary_ip}, IPv6: ${v_ipv6_address} [ ${v_dns_host_short_name}.${v_given_domain} ] has been configured."
    else
        print_success "All done! Your domain \"${v_given_domain}\" with DNS server ${v_primary_ip} [ ${v_dns_host_short_name}.${v_given_domain} ] has been configured."
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
                exit
            fi
        fi

    elif [[ "${v_action_requested}" != "create" ]]
    then
        if ${v_if_autorun_false}
        then
            print_error "Host record for ${v_host_record}.${v_domain_name} doesn't exist ! "
            print_error "Nothing to do ! Exiting ! "
            exit
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
        # PTR zone
        v_current_serial_ptr_zone=$(awk -F';' '/;Serial/{gsub(/[[:space:]]/,"",$1); print $1}' "${v_ptr_zone}")
        local new_serial_ptr=$(date +%s)
        if [[ $new_serial_ptr -le $v_current_serial_ptr_zone ]]; then
            new_serial_ptr=$(( v_current_serial_ptr_zone + 1 ))
        fi
        sed -i "/;Serial/s/${v_current_serial_ptr_zone}/${new_serial_ptr}/g" "${v_ptr_zone}"
        
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

    print_task "Reloading the DNS service (named)..."

    systemctl reload named &>/dev/null

    if systemctl is-active named &>/dev/null;
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
            print_success "Successfully created cname record ${v_input_cname}.${v_domain_name}"
        else
            print_task_fail
        fi

        print_info "FYI : ${v_input_cname}.${v_domain_name} is an alias for $(dig @"${dnsbinder_server_ipv4_address}" +short CNAME ${v_input_cname}.${v_domain_name} 2>/dev/null | sed 's/\.$//' || true)"

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
            if ${query_success} && [[ -n "${dnsbinder_ipv6_ula_subnet}" ]]; then
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
            if ${query_success} && [[ -n "${dnsbinder_ipv6_ula_subnet}" ]]; then
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
        if [[  "${v_action_requested}" == "create" ]]
        then
            print_success "Successfully created host record ${v_host_record}.${v_domain_name}"
        elif [[ "${v_action_requested}" == "delete" ]]
        then
            print_success "Successfully deleted host record ${v_host_record}.${v_domain_name}"
        elif [[ "${v_action_requested}" == "rename" ]]
        then
            print_success "Successfully renamed host ${v_host_record}.${v_domain_name} to ${v_rename_record}.${v_domain_name}"
        fi

        if  [[ "${v_action_requested}" == "rename" ]]
        then
            if [[ -n "${dnsbinder_ipv6_ula_subnet}" ]]; then
                print_info "FYI : ${v_rename_record}.${v_domain_name}\n             ├── IPv4: $(dig @"${dnsbinder_server_ipv4_address}" +short A ${v_rename_record}.${v_domain_name} | head -1)\n             └── IPv6: $(dig @"${dnsbinder_server_ipv4_address}" +short AAAA ${v_rename_record}.${v_domain_name} | head -1 || true)"
            else
                print_info "FYI : ${v_rename_record}.${v_domain_name}\n             └── IPv4: $(dig @"${dnsbinder_server_ipv4_address}" +short A ${v_rename_record}.${v_domain_name} | head -1 || true)"
            fi
        else
            if [[ -n "${dnsbinder_ipv6_ula_subnet}" ]]; then
                print_info "FYI : ${v_host_record}.${v_domain_name}\n             ├── IPv4: $(dig @"${dnsbinder_server_ipv4_address}" +short A ${v_host_record}.${v_domain_name} | head -1)\n             └── IPv6: $(dig @"${dnsbinder_server_ipv4_address}" +short AAAA ${v_host_record}.${v_domain_name} | head -1 || true)"
            else
                print_info "FYI : ${v_host_record}.${v_domain_name}\n             └── IPv4: $(dig @"${dnsbinder_server_ipv4_address}" +short A ${v_host_record}.${v_domain_name} | head -1 || true)"
            fi
        fi
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
            read -p "Provide the required IPv4 Address ( within ${dnsbinder_network} ) : " ipv4_provided
        fi

        if ! fn_validate_ipv4_address "${ipv4_provided}"; then
            print_error "Invalid input provided for IPv4 Address ! "
            ipv4_provided=""
            continue
        fi

        if fn_check_whether_ip_in_range "${ipv4_provided}" "${dnsbinder_network}"; then
            break
        else
            print_error "Provided IPv4 address doesn't reside within the network ${dnsbinder_network} ! "
            ipv4_provided=""
            continue
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
                    exit 1
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


    ${v_if_autorun_false} && print_task "Creating host record ${v_host_record}.${v_domain_name}..."

    ############### A Record Creation Section ############################

    v_host_record_adjusted_space=$(printf "%-*s" 63 "${v_host_record}")

    v_add_host_record=$(echo "${v_host_record_adjusted_space} IN A ${v_current_ip_of_host_record}")

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

    # Add AAAA record if IPv6 is configured
    if [[ -n "${dnsbinder_ipv6_ula_subnet}" && ! -z "${dnsbinder_ipv6_gateway}" ]]; then
        # Convert IPv4 to IPv6 using the mapping scheme
        IFS=. read -r oct1 oct2 oct3 oct4 <<< "$v_current_ip_of_host_record"
        
        # Extract IPv6 prefix base from gateway
        ipv6_prefix_base=$(echo "$dnsbinder_ipv6_gateway" | sed 's/::[^:]*$//')
        
        # Build IPv6 address: prefix:subnet_encoding:ipv4_full
        group5=$(printf "%02x%02x" $oct1 $oct2)
        group6=$(printf "00%02x" $oct3)
        group7=$(printf "%02x%02x" $oct1 $oct2)
        group8=$(printf "%02x%02x" $oct3 $oct4)
        
        v_ipv6_address_for_host="${ipv6_prefix_base}:${group5}:${group6}:${group7}:${group8}"
        
        v_add_ipv6_host_record=$(echo "${v_host_record_adjusted_space} IN AAAA ${v_ipv6_address_for_host}")
        
        # Find correct insertion point based on numeric IPv6 address order
        v_insert_after=$(python3 -c "
import ipaddress
import re

new_addr = ipaddress.IPv6Address('${v_ipv6_address_for_host}')

# Read all AAAA records from the zone file
with open('${v_fw_zone}', 'r') as f:
    lines = f.readlines()

# Extract AAAA records between the AAAA-Records header and CNAME-Records
in_aaaa_section = False
aaaa_records = []
for line in lines:
    if ';AAAA-Records (IPv6)' in line:
        in_aaaa_section = True
        continue
    if ';CNAME-Records' in line:
        break
    if in_aaaa_section and 'IN AAAA' in line:
        match = re.search(r'(\S+)\s+IN AAAA\s+([0-9a-f:]+)', line)
        if match:
            hostname = match.group(1)
            addr = ipaddress.IPv6Address(match.group(2))
            aaaa_records.append((hostname, addr))

# Find the last record with address less than the new one
insert_after = ';AAAA-Records (IPv6)'
for hostname, addr in aaaa_records:
    if addr < new_addr:
        insert_after = hostname
    else:
        break

print(insert_after)
")
        
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

    v_add_ptr_record=$(echo "${v_space_adjusted_host_part_of_current_ip} IN PTR ${v_host_record}.${v_domain_name}.")

    if [[ "${v_previous_ip}" == ';PTR-Records' ]]
    then
        sed -i "/^;PTR-Records/a\\${v_add_ptr_record}" "${v_ptr_zone}"
    else
        sed -i "/^${v_host_part_of_previous_ip} /a\\${v_add_ptr_record}" "${v_ptr_zone}"
    fi

    ############# End of PTR Record Create Section #######################

    ################## IPv6 PTR Record Create Section ###################################

    # Add IPv6 PTR record if dual-stack is configured
    if [[ -n "${dnsbinder_ipv6_ula_subnet}" && ! -z "${v_ipv6_address_for_host}" ]]; then
        v_ipv6_zone_file="${var_zone_dir}/${v_domain_name}-ipv6-reverse.db"
        
        # Convert IPv6 address to PTR format (16 nibbles reversed)
        v_ipv6_ptr=$(python3 -c "
import ipaddress
addr = ipaddress.IPv6Address('${v_ipv6_address_for_host}')
# Get the last 64 bits (host portion for /64)
host_int = int(addr) & ((1 << 64) - 1)
# Convert to 16 hex nibbles
host_hex = format(host_int, '016x')
# Reverse nibbles with dots
ptr = '.'.join(reversed(host_hex))
print(ptr)
")
        
        if [[ -n "${v_ipv6_ptr}" ]]; then
            v_add_ipv6_ptr_record="${v_ipv6_ptr} IN PTR ${v_host_record}.${v_domain_name}."
            
            # Find correct insertion point based on lexicographic nibble order
            v_insert_after=$(python3 -c "
import re

new_ptr = '${v_ipv6_ptr}'

# Read all PTR records from the IPv6 reverse zone file
try:
    with open('${v_ipv6_zone_file}', 'r') as f:
        lines = f.readlines()
except:
    print(';IPv6 PTR-Records')
    exit()

# Extract PTR records after the IPv6 PTR-Records header
in_ptr_section = False
ptr_records = []
for line in lines:
    if ';IPv6 PTR-Records' in line:
        in_ptr_section = True
        continue
    if in_ptr_section and 'IN PTR' in line:
        match = re.search(r'^([0-9a-f.]+)\s+IN PTR', line)
        if match:
            ptr_records.append(match.group(1))

# Find the last record with PTR less than the new one (lexicographic = numeric for reversed nibbles)
insert_after = ';IPv6 PTR-Records'
for ptr in ptr_records:
    if ptr < new_ptr:
        insert_after = ptr
    else:
        break

print(insert_after)
")
            
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

    fn_update_serial_number_of_zones

    if ${v_if_autorun_false}
    then
        fn_reload_named_dns_service
    fi

    ${v_if_autorun_false} && fn_release_zone_lock
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

            fn_update_serial_number_of_zones

            if ${v_if_autorun_false}
            then
                fn_reload_named_dns_service
            fi

            ${v_if_autorun_false} && fn_release_zone_lock
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

    v_host_record_exist=$(grep "^${v_host_record} .*IN A " "${v_fw_zone}")
    v_current_ip_of_host_record=$(awk -v host="^${v_host_record} " '$0 ~ host && /IN A / {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")

    fn_set_ptr_zone

    v_host_record_rename=$(printf "%-*s" 63 "${v_rename_record}")
    v_host_record_rename="${v_host_record_rename} IN A ${v_current_ip_of_host_record}"

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

            v_host_record_exist_escaped=$(printf '%s' "${v_host_record_exist}" | sed 's/[.[\*^$()+?{|\\]/\\&/g')
            v_host_record_rename_escaped=$(printf '%s' "${v_host_record_rename}" | sed 's/[&/\\]/\\&/g')
            sed -i "s/${v_host_record_exist_escaped}/${v_host_record_rename_escaped}/g" "${v_fw_zone}"
            sed -i "s/${v_host_record}\.${v_domain_name}\./${v_rename_record}.${v_domain_name}./g" "${v_ptr_zone}"
            
            # Also rename AAAA record if it exists (IPv6 dual-stack)
            v_rename_record_adjusted_space=$(printf "%-*s" 63 "${v_rename_record}")
            sed -i "s/^${v_host_record} \(.*IN AAAA\)/${v_rename_record_adjusted_space} \1/g" "${v_fw_zone}"
            
            # Also rename IPv6 PTR record if it exists
            v_ipv6_zone_file="${var_zone_dir}/${v_domain_name}-ipv6-reverse.db"
            if [[ -f "${v_ipv6_zone_file}" ]]; then
                sed -i "s/IN PTR ${v_host_record}\.${v_domain_name}\./IN PTR ${v_rename_record}.${v_domain_name}./g" "${v_ipv6_zone_file}"
            fi

            print_task_done
            
            fn_update_serial_number_of_zones

            if ${v_if_autorun_false}
            then
                fn_reload_named_dns_service
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

    clear

    print_cyan "######################(DNS-Bulk-Records-Maker-with-IP)#############################"

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
    local v_count_already_exists=0
    local v_count_ip_exhausted=0
    local v_count_other_failures=0

    local v_pre_execution_serial_fw_zone
    v_pre_execution_serial_fw_zone=$(awk -F';' '/;Serial/{gsub(/[[:space:]]/,"",$1); print $1}' "${v_fw_zone}")

    local v_host_count=0

    # Show initial header once
    clear
    print_cyan "######################(DNS-Bulk-Records-Maker-with-IP)#############################"

    while read -r v_host_record v_host_ipv4; do
        # Update progress header in place (move cursor to top)
        tput cup 1 0
        print_cyan "####################################( Running )####################################"
        print_white "Status     : [ ${v_host_count}/${v_total_host_records} ] host records have been processed"
        print_green "Successful : ${v_count_successfull}"
        print_red "Failed     : ${v_count_failed}"

        ((v_host_count++))

        print_task "Attempting to create the host record ${v_host_record}.${v_domain_name} (${v_host_ipv4}) . . . " "nskip"

        local v_serial_fw_zone_pre_execution
        v_serial_fw_zone_pre_execution=$(awk -F';' '/;Serial/{gsub(/[[:space:]]/,"",$1); print $1}' "${v_fw_zone}")

        specific_ipv4_requested="yes"
        fn_create_host_record "${v_host_record}" "${v_host_ipv4}" "Automated-Execution"
        local var_exit_status=${?}

        local v_serial_fw_zone_post_execution
        v_serial_fw_zone_post_execution=$(awk -F';' '/;Serial/{gsub(/[[:space:]]/,"",$1); print $1}' "${v_fw_zone}")

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
            if [[ "${v_serial_fw_zone_pre_execution}" -ne "${v_serial_fw_zone_post_execution}" ]]; then
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
        tput ed

    done < "${v_work_file}"

    rm -f "${v_work_file}"

    # Clear the progress display before showing final summary
    clear

    local v_post_execution_serial_fw_zone
    v_post_execution_serial_fw_zone=$(awk -F';' '/;Serial/{gsub(/[[:space:]]/,"",$1); print $1}' "${v_fw_zone}")

    if [[ "${v_pre_execution_serial_fw_zone}" -ne "${v_post_execution_serial_fw_zone}" ]]; then
        print_task "Reloading the DNS service (named) for the changes to take effect..."
        systemctl reload named &>/dev/null
        if systemctl is-active named &>/dev/null; then
            print_task_done
        else
            print_task_fail
        fi
    else
        print_yellow "No changes done! Nothing to do!"
    fi

    print_white "Please find the below details of the records:"
    if [[ -n "${dnsbinder_ipv6_ula_subnet}" ]]; then
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

    clear

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
    
    > "${v_tmp_file_dnsbinder}"
    
    v_count_successfull=0
    v_count_failed=0
    v_count_invalid_host=0
    v_count_already_exists=0
    v_count_doesnt_exist=0
    v_count_ip_exhausted=0
    v_count_other_failures=0
    
    v_pre_execution_serial_fw_zone=$(awk -F';' '/;Serial/{gsub(/[[:space:]]/,"",$1); print $1}' "${v_fw_zone}")
    
    v_total_host_records=$(wc -l < "${v_work_file}")
    
    v_host_count=0
    
    # Show initial header once
    clear
    fn_progress_title
    
    while read -r v_host_record
    do
        # Update progress header in place (move cursor to top)
        tput cup 1 0
        print_cyan "####################################( Running )####################################"
        print_white "Status     : [ ${v_host_count}/${v_total_host_records} ] host records have been processed"
        print_green "Successful : ${v_count_successfull}"
        print_red "Failed     : ${v_count_failed}"
        
        ((v_host_count++))
        
        print_task "Attempting to ${v_action_required} the host record ${v_host_record}.${v_domain_name} . . . " "nskip"
    
        v_serial_fw_zone_pre_execution=$(awk -F';' '/;Serial/{gsub(/[[:space:]]/,"",$1); print $1}' "${v_fw_zone}")
    
        if [[ ${v_action_required} == "create" ]]
                then
            fn_create_host_record "${v_host_record}" "Automated-Execution"
            var_exit_status=${?}

        elif [[ ${v_action_required} == "delete" ]]
        then
            fn_delete_host_record "${v_host_record}" -y "Automated-Execution"
            var_exit_status=${?}
        fi
    
        v_serial_fw_zone_post_execution=$(awk -F';' '/;Serial/{gsub(/[[:space:]]/,"",$1); print $1}' "${v_fw_zone}")
    
            v_fqdn="${v_host_record}.${v_domain_name}"
    
            
        if [[ ${v_action_required} == "create" ]]
        then
            v_ip_address=$(awk -v host="^${v_host_record} " '$0 ~ host && /IN A / {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")
            v_ipv6_address=$(awk -v host="^${v_host_record} " '$0 ~ host && /IN AAAA / {gsub(/[[:space:]]/,"",$NF); print $NF}' "${v_fw_zone}")
    
            if [[ -z "${v_ip_address}" ]]; then
                    v_ip_address="N/A"
                fi
                
                # Build address display (dual-stack)
                if [[ -n "${v_ipv6_address}" ]]; then
                    v_address_display="IPv4: ${v_ip_address}, IPv6: ${v_ipv6_address}"
                else
                    v_address_display="${v_ip_address}"
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
        v_serial_fw_zone_post_execution=$(awk -F';' '/;Serial/{gsub(/[[:space:]]/,"",$1); print $1}' "${v_fw_zone}")

        if [[ "${v_serial_fw_zone_pre_execution}" -ne "${v_serial_fw_zone_post_execution}" ]]
        then
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
    tput ed
    
    done < "${v_work_file}"

    rm -f "${v_work_file}"

    # Clear the progress display before showing final summary
    clear

    v_post_execution_serial_fw_zone=$(awk -F';' '/;Serial/{gsub(/[[:space:]]/,"",$1); print $1}' "${v_fw_zone}")
    
    if [[ "${v_pre_execution_serial_fw_zone}" -ne "${v_post_execution_serial_fw_zone}" ]]
    then
        print_task "Reloading the DNS service (named) for the changes to take effect..."
    
        systemctl reload named &>/dev/null
    
        if systemctl is-active named &>/dev/null;
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
        if [[ -n "${dnsbinder_ipv6_ula_subnet}" ]]; then
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
        if grep -q "^${v_input_cname} " <<< $(sed -n '/;CNAME-Records/,$p' "${v_fw_zone}")
        then 
            print_error "CNAME record for \"${v_input_cname}.${v_domain_name}\" already exists! "
            exit 1

        elif grep -q "^${v_input_cname} "  <<< $(sed -n '/;A-Records/,/;CNAME-Records/{//!p;}' "${v_fw_zone}")
        then
            print_error "Conflict! Already a host record exists with the same name of CNAME \"${v_input_cname}.${v_domain_name}\" ! "
            exit 1
        fi

        fn_get_hostname_record_from_user

        if ! grep -q "^${v_input_hostname} "  <<< $(sed -n '/;A-Records/,/;CNAME-Records/{//!p;}' "${v_fw_zone}")
        then
            print_error "Provided host record \"${v_input_hostname}.${v_domain_name}\" doesn't exist to create CNAME \"${v_input_cname}.${v_domain_name}\" ! "
            exit 1
        fi
    fi

    if [[ "${v_action_requested}" == "delete" ]]
    then
        if ! grep -q "^${v_input_cname} " <<< $(sed -n '/;CNAME-Records/,$p' "${v_fw_zone}")
        then 
            print_error "CNAME record for ${v_input_cname}.${v_domain_name} doesn't exist! "
            exit 1
        fi
    fi
}

fn_create_cname_record() {
    v_input_cname="${1}"
    v_input_hostname="${2}"
    
    if ! fn_acquire_zone_lock; then return 1; fi

    fn_get_cname_record "create"

    print_task "Creating CNAME record \"${v_input_cname}.${v_domain_name}\" for the host record \"${v_input_hostname}.${v_domain_name}\"..."

    v_cname_adjusted_space=$(printf "%-*s" 63 "${v_input_cname}")

    v_cname_record="${v_cname_adjusted_space} IN CNAME ${v_input_hostname}.${v_domain_name}."

    sed -i "/^;CNAME-Records/a \\${v_cname_record}" "${v_fw_zone}"

    print_task_done

    fn_update_serial_number_of_zones "forward-zone-only"

    fn_reload_named_dns_service "true"

    fn_release_zone_lock
}

fn_delete_cname_record() {
    v_input_cname="${1}"
    v_input_delete_confirmation="${2}"

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
                exit
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
# 2) Delete a DNS host record (removes A + AAAA)                 #
# 3) Rename an existing DNS host record (updates A + AAAA)       #
# 4) Create multiple DNS host records provided in a file         #
# 5) Delete multiple DNS host records provided in a file         #
# 6) Create DNS host with specific IPv4 (auto-generates IPv6)    #
# 7) Create a CNAME/Alias record for existing host record        #
# 8) Delete a CNAME/Alias record for existing host record        #
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
        fn_delete_host_record
        exit
        ;;
    3)
        fn_check_existence_of_domain
        fn_rename_host_record
        exit
        ;;
    4)
        fn_check_existence_of_domain
        fn_handle_multiple_host_record "${2}" "create"
        exit
        ;;
    5)
        fn_check_existence_of_domain
        fn_handle_multiple_host_record "${2}" "delete"
        exit
        ;;
    6)
        fn_check_existence_of_domain
        specific_ipv4_requested="yes"
        fn_create_host_record 
        exit
        ;;
    7)
        fn_check_existence_of_domain
        fn_create_cname_record
        exit
        ;;
    8)
        fn_check_existence_of_domain
        fn_delete_cname_record
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
    -c      To create a host record (dual-stack: A + AAAA records)
    -d      To delete a host record (removes both A and AAAA records)
    -dy     caution ! To do the above without any confirmation
    -r      To rename an existing host record (updates A and AAAA records)
    -ry     caution ! To do the above without any confirmation
    -cf     To create multiple host records provided in a file (dual-stack)
    -cif    To create multiple host records with specific IPs from a file (hostname ipv4)
    -cify   caution ! To do the above without any confirmation
    -df     To delete multiple host records provided in a file (dual-stack)
    -ci     To create a host record with specific IPv4 Address (auto-generates IPv6)
    -cc     To create a CNAME/Alias record for an existing host record
    -dc     To delete a CNAME/Alias record for an existing host record
    -dcy    caution ! To do the above without any confirmation
    --setup To configure local dns server and domain (dual-stack IPv4/IPv6)
            Both IPv4 and IPv6 networks are auto-detected from system
            Usage: dnsbinder --setup <domain>
            Example: dnsbinder --setup lab.local
    -h (or) --help To print this usage info 

Note: All host record operations automatically create/manage both IPv4 (A) and IPv6 (AAAA) records

[ Or ]
Run dnsbinder utility without any arguements to get menu driven actions."
}

if [[ -n "${1}" ]]
then

    case "${1}" in
        -c)
            fn_check_existence_of_domain
            if [[ -n "${3}" ]];then
                print_error "Invalid Option! '-c' option takes only 1 arguement as hostname ! "
                fn_usage_message
                exit 1
            fi
            fn_create_host_record "${2}"
            exit
            ;;
        -d|-dy)
            fn_check_existence_of_domain
            if [[ -n "${3}" ]];then
                print_error " Invalid Option! ${1} option takes only 1 arguement as hostname ! "
                fn_usage_message
                exit 1
            fi
            if [[ "${1}" == "-d" ]];then
                fn_delete_host_record "${2}"
            elif [[ "${1}" == "-dy" ]];then
                fn_delete_host_record "${2}" "-y"
            fi
            exit
            ;;
        -r|-ry)
            fn_check_existence_of_domain
            if [[ -n "${4}" ]];then
                print_error "Invalid Option! ${1} option takes only 2 arguements [ existing host record and new host record ] ! "
                fn_usage_message
                exit 1
            fi
            if [[ "${1}" == "-r" ]];then
                fn_rename_host_record "${2}" "${3}"
            elif [[ "${1}" == "-ry" ]];then
                fn_rename_host_record "${2}" "${3}" "-y"
            fi
            exit
            ;;
        -cf)
            fn_check_existence_of_domain
            if [[ -n "${3}" ]];then
                print_error "Invalid Option! '-cf' option takes only 1 arguement as file containing list of hostnames ! "
                fn_usage_message
                exit 1
            fi
            fn_handle_multiple_host_record "${2}" "create"
            exit
            ;;
        -cif|-cify)
            fn_check_existence_of_domain
            if [[ -n "${3}" ]];then
                print_error "Invalid Option! '${1}' option takes only 1 arguement as file containing list of 'hostname ipv4' pairs ! "
                fn_usage_message
                exit 1
            fi
            if [[ "${1}" == "-cif" ]]; then
                fn_handle_multiple_host_record_with_ip "${2}"
            elif [[ "${1}" == "-cify" ]]; then
                fn_handle_multiple_host_record_with_ip "${2}" "-y"
            fi
            exit
            ;;
        -df)
            fn_check_existence_of_domain
            if [[ -n "${3}" ]];then
                print_error "Invalid Option! '-df' option takes only 1 arguement as file containing list of hostnames ! "
                fn_usage_message
                exit 1
            fi
            fn_handle_multiple_host_record "${2}" "delete"
            exit
            ;;
        -ci)    
            fn_check_existence_of_domain 
            if [[ -n "${4}" ]];then
                print_error "Invalid Option! '-ci' option takes only 2 arguements [ hostname and required ipv4 address ] ! "
                fn_usage_message
                exit 1
            fi
            specific_ipv4_requested="yes"
            fn_create_host_record "${2}" "${3}"
            exit
            ;;
        -cc)    
            fn_check_existence_of_domain 
            if [[ -n "${4}" ]];then
                print_error "Invalid Option! '-cc' option takes only 2 arguements [ cname and hostname ] ! "
                fn_usage_message
                exit 1
            fi
            fn_create_cname_record "${2}" "${3}"
            exit
            ;;
        -dc|-dcy)   
            fn_check_existence_of_domain 
            if [[ -n "${3}" ]];then
                print_error "Invalid Option! ${1} option takes only 1 arguement as cname ! "
                fn_usage_message
                exit 1
            fi
            if [[ "${1}" == "-dc" ]];then
                fn_delete_cname_record "${2}"
            elif [[ "${1}" == "-dcy" ]];then
                fn_delete_cname_record "${2}" "-y"
            fi
            exit
            ;;
        --setup)
            fn_configure_named_dns_server "${2}"
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
