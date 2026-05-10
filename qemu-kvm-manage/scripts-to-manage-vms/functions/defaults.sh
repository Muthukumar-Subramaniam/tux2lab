source /tux2lab/common-utils/color-functions.sh

if [[ "$EUID" -eq 0 ]]; then
    print_error "Running as root user is not allowed."
    print_info "This script should be run as a user with sudo privileges, not as root."
    exit 1
fi

# Check if we're inside a QEMU guest
if command -v dmidecode &>/dev/null; then
    if sudo dmidecode -s system-manufacturer | grep -qi 'QEMU'; then
        print_error "This script cannot be executed inside a QEMU guest VM."
        print_info "This script must be run on the host system managing QEMU/KVM virtual machines."
        print_info "Current environment is a QEMU guest, which is not supported."
        exit 1
    fi
fi

LAB_ENV_VARS_FILE="/tux2lab-data/lab_environment_vars"
if [[ -f "$LAB_ENV_VARS_FILE" ]]; then
    source "$LAB_ENV_VARS_FILE"
else
    print_error "Lab environment variables file not found at $LAB_ENV_VARS_FILE"
    exit 1
fi
