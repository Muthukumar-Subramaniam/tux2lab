source /tux2lab/common-utils/color-functions.sh

if [[ "$EUID" -eq 0 ]]; then
    print_error "Running as root user is not allowed."
    print_info "This script should be run as a user with sudo privileges, not as root."
    exit 1
fi

LAB_ENV_VARS_FILE="/tux2lab-data/lab_environment_vars"
if [[ -f "$LAB_ENV_VARS_FILE" ]]; then
    source "$LAB_ENV_VARS_FILE"
else
    print_error "Lab environment variables file not found at $LAB_ENV_VARS_FILE"
    exit 1
fi
