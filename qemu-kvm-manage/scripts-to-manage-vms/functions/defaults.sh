source /tux2lab/common-utils/color-functions.sh

if [[ "$EUID" -eq 0 ]]; then
    print_error "Running as root user is not allowed."
    print_info "This script should be run as a user with sudo privileges, not as root."
    exit 1
fi

# Read lab environment from JSON (v2.0.0)
readonly LAB_ENV_JSON="/tux2lab-data/lab-config/lab_environment.json"
if [[ ! -f "${LAB_ENV_JSON}" ]]; then
    print_error "Lab environment file not found: ${LAB_ENV_JSON}"
    print_info "Run 'tux2lab deploy' to generate lab configuration."
    exit 1
fi

readonly CONTAINER_NAME="tux2lab-engine"

# Extract variables from JSON
lab_infra_server_hostname=$(jq -r '.lab.engine_fqdn' "${LAB_ENV_JSON}")
lab_infra_domain_name=$(jq -r '.lab.domain' "${LAB_ENV_JSON}")
lab_infra_admin_username=$(jq -r '.admin.username' "${LAB_ENV_JSON}")
lab_infra_server_ipv4_address=$(jq -r '.network.ipv4.address' "${LAB_ENV_JSON}")
lab_infra_server_ipv6_address=$(jq -r '.network.ipv6.address' "${LAB_ENV_JSON}")
lab_infra_server_ipv4_subnet=$(jq -r '.network.ipv4.cidr' "${LAB_ENV_JSON}")
lab_infra_server_ipv6_ula_subnet=$(jq -r '.network.ipv6.ula_subnet' "${LAB_ENV_JSON}")
lab_infra_bridge_interface=$(jq -r '.network.bridge_interface' "${LAB_ENV_JSON}")
