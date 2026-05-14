# parse-vm-command-args.sh
# 
# Reusable argument parsing function for VM management commands
# Handles common flags: -c/--console, -f/--force, -H/--hosts, -h/--help, -C/--clean-install, -v/--version
#
# Usage:
#   source /path/to/parse-vm-command-args.sh
#   parse_vm_command_args "$@"
#
# This function sets the following global variables:
#   ATTACH_CONSOLE  - "yes" or "no"
#   CLEAN_INSTALL   - "yes" or "no" (if supported)
#   FORCE_REIMAGE   - "true" or "false" (if supported)
#   OS_DISTRO       - OS distribution name (if specified)
#   VERSION_TYPE    - OS version number (e.g., 10, 9, 24.04, 15.6)
#   HOSTNAMES       - Array of validated hostnames
#   TOTAL_VMS       - Number of VMs to process
#
# The function expects a help function named 'fn_show_help' to be defined before calling

parse_vm_command_args() {
    local supports_clean_install="${SUPPORTS_CLEAN_INSTALL:-no}"
    local supports_force="${SUPPORTS_FORCE:-no}"
    local supports_distro="${SUPPORTS_DISTRO:-no}"
    local supports_version="${SUPPORTS_VERSION:-no}"
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                fn_show_help
                exit 0
                ;;
            -c|--console)
                if [[ "$ATTACH_CONSOLE" == "yes" ]]; then
                    print_error "Duplicate --console/-c option."
                    fn_show_help
                    exit 1
                fi
                ATTACH_CONSOLE="yes"
                shift
                ;;
            -f|--force)
                if [[ "$supports_force" != "yes" ]]; then
                    print_error "No such option: $1"
                    fn_show_help
                    exit 1
                fi
                if [[ "$FORCE_REIMAGE" == "true" ]]; then
                    print_error "Duplicate --force/-f option."
                    fn_show_help
                    exit 1
                fi
                FORCE_REIMAGE="true"
                shift
                ;;
            -C|--clean-install)
                if [[ "$supports_clean_install" != "yes" ]]; then
                    print_error "No such option: $1"
                    fn_show_help
                    exit 1
                fi
                if [[ "$CLEAN_INSTALL" == "yes" ]]; then
                    print_error "Duplicate --clean-install option."
                    fn_show_help
                    exit 1
                fi
                CLEAN_INSTALL="yes"
                shift
                ;;
            -d|--distro)
                if [[ "$supports_distro" != "yes" ]]; then
                    print_error "No such option: $1"
                    fn_show_help
                    exit 1
                fi
                if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                    print_error "--distro/-d requires a distribution name."
                    fn_show_help
                    exit 1
                fi
                if [[ -n "$OS_DISTRO" ]]; then
                    print_error "Duplicate --distro/-d option."
                    fn_show_help
                    exit 1
                fi
                OS_DISTRO="$2"
                shift 2
                ;;
            -v|--version)
                if [[ "$supports_version" != "yes" ]]; then
                    print_error "No such option: $1"
                    fn_show_help
                    exit 1
                fi
                if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                    print_error "--version/-v requires a version number (e.g., 10, 9, 24.04, 15.6)."
                    fn_show_help
                    exit 1
                fi
                if [[ -n "$VERSION_TYPE" ]]; then
                    print_error "Duplicate --version/-v option."
                    fn_show_help
                    exit 1
                fi
                VERSION_TYPE="$2"
                shift 2
                ;;
            -H|--hosts)
                if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                    print_error "--hosts/-H requires a comma-separated list of hostnames."
                    fn_show_help
                    exit 1
                fi
                IFS=',' read -ra HOSTNAMES <<< "$2"
                shift 2
                ;;
            -*)
                print_error "No such option: $1"
                fn_show_help
                exit 1
                ;;
            *)
                if [[ ${#HOSTNAMES[@]} -eq 0 ]]; then
                    HOSTNAMES+=("$1")
                else
                    print_error "Cannot mix positional hostname with --hosts/-H option."
                    fn_show_help
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate console + multiple VMs conflict
    if [[ "$ATTACH_CONSOLE" == "yes" && ${#HOSTNAMES[@]} -gt 1 ]]; then
        print_error "--console/-c option cannot be used with multiple VMs."
        fn_show_help
        exit 1
    fi

    # Remove duplicates from HOSTNAMES
    if [[ ${#HOSTNAMES[@]} -gt 1 ]]; then
        UNIQUE_HOSTNAMES=($(printf '%s\n' "${HOSTNAMES[@]}" | sort -u))
        if [[ ${#UNIQUE_HOSTNAMES[@]} -ne ${#HOSTNAMES[@]} ]]; then
            print_warning "Removed duplicate hostnames from the list."
            HOSTNAMES=("${UNIQUE_HOSTNAMES[@]}")
        fi
    fi

    # If no hostnames provided, prompt for one
    if [[ ${#HOSTNAMES[@]} -eq 0 ]]; then
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/input-hostname.sh ""
        HOSTNAMES=("$qemu_kvm_hostname")
    fi

    # Validate all hostnames using input-hostname.sh
    if [[ ${#HOSTNAMES[@]} -gt 0 ]]; then
        validated_hosts=()
        for vm_name in "${HOSTNAMES[@]}"; do
            vm_name=${vm_name// /}  # Trim all whitespace
            [[ -z "$vm_name" ]] && continue  # Skip empty entries
            # Use input-hostname.sh to validate and normalize
            source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/input-hostname.sh "$vm_name"
            validated_hosts+=("$qemu_kvm_hostname")
        done
        HOSTNAMES=("${validated_hosts[@]}")
    fi

    # Check if any valid hosts remain after validation
    if [[ ${#HOSTNAMES[@]} -eq 0 ]]; then
        print_error "No valid hostnames provided."
        exit 1
    fi

    # Set TOTAL_VMS for convenience
    TOTAL_VMS=${#HOSTNAMES[@]}
}
