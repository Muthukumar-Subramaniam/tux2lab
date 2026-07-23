################################################################################
# Function: normalize_os_distro
# Description: Normalize OS distro names to standard formats, handling version suffixes
# Parameters:
#   $1 - OS distro name (OS_DISTRO)
# Returns:
#   0 - Success (sets NORMALIZED_OS_DISTRO and VERSION_TYPE globals)
#   1 - Unrecognized distro
################################################################################

normalize_os_distro() {
    local os_distro="$1"

    if [[ -z "$os_distro" ]]; then
        print_error "normalize_os_distro requires OS distro name"
        return 1
    fi

    # Normalize OS distro names (case-insensitive exact match or known aliases)
    local base_distro="${os_distro}"
    case "${base_distro,,}" in
        almalinux|alma)
            NORMALIZED_OS_DISTRO="almalinux"
            ;;
        centos-stream|centos)
            NORMALIZED_OS_DISTRO="centos-stream"
            ;;
        rocky)
            NORMALIZED_OS_DISTRO="rocky"
            ;;
        oraclelinux|oracle)
            NORMALIZED_OS_DISTRO="oraclelinux"
            ;;
        rhel|redhat)
            NORMALIZED_OS_DISTRO="rhel"
            ;;
        ubuntu-lts|ubuntu)
            NORMALIZED_OS_DISTRO="ubuntu-lts"
            ;;
        debian)
            NORMALIZED_OS_DISTRO="debian"
            ;;
        opensuse-leap|opensuse|suse)
            NORMALIZED_OS_DISTRO="opensuse-leap"
            ;;
        *)
            print_error "Unrecognized OS distro: $base_distro"
            print_info "Supported distros: almalinux, rocky, oraclelinux, centos-stream, rhel, ubuntu-lts, debian, opensuse-leap"
            return 1
            ;;
    esac

    return 0
}
