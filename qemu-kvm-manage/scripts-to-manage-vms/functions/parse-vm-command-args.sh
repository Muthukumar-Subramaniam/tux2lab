# parse-vm-command-args.sh
# 
# Reusable argument parsing function for VM management commands
# Handles common flags: -c/--console, -f/--force, -H/--hosts, -h/--help, --reset-specs-to-default, -v/--version
#
# Usage:
#   source /path/to/parse-vm-command-args.sh
#   parse_vm_command_args "$@"
#
# This function sets the following global variables:
#   ATTACH_CONSOLE  - "yes" or "no"
#   RESET_SPECS     - "yes" or "no" (if supported)
#   FORCE_REIMAGE   - "true" or "false" (if supported)
#   OS_DISTRO       - OS distribution name (if specified)
#   VERSION_TYPE    - OS version number (e.g., 10, 9, 26.04, 16.0)
#   HOSTNAMES       - Array of validated hostnames
#   TOTAL_VMS       - Number of VMs to process
#
# The function expects a help function named 'fn_show_help' to be defined before calling

parse_vm_command_args() {
    local supports_reset_specs="${SUPPORTS_RESET_SPECS:-no}"
    local supports_force="${SUPPORTS_FORCE:-no}"
    local supports_distro="${SUPPORTS_DISTRO:-no}"
    local supports_version="${SUPPORTS_VERSION:-no}"
    local supports_stack="${SUPPORTS_STACK:-no}"
    
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
            --reset-specs-to-default)
                if [[ "$supports_reset_specs" != "yes" ]]; then
                    print_error "No such option: $1"
                    fn_show_help
                    exit 1
                fi
                if [[ "$RESET_SPECS" == "yes" ]]; then
                    print_error "Duplicate --reset-specs-to-default option."
                    fn_show_help
                    exit 1
                fi
                RESET_SPECS="yes"
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
                    print_error "--version/-v requires a version number (e.g., 10, 9, 26.04, 16.0)."
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
            --ipv4-only)
                if [[ "$supports_stack" != "yes" ]]; then
                    print_error "No such option: $1"
                    fn_show_help
                    exit 1
                fi
                STACK_MODE="ipv4"
                STACK_MODE_EXPLICIT=true
                shift
                ;;
            --ipv6-only)
                if [[ "$supports_stack" != "yes" ]]; then
                    print_error "No such option: $1"
                    fn_show_help
                    exit 1
                fi
                STACK_MODE="ipv6"
                STACK_MODE_EXPLICIT=true
                shift
                ;;
            --dual-stack)
                if [[ "$supports_stack" != "yes" ]]; then
                    print_error "No such option: $1"
                    fn_show_help
                    exit 1
                fi
                STACK_MODE="dual"
                STACK_MODE_EXPLICIT=true
                shift
                ;;
            --cpu)
                if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                    print_error "--cpu requires a number."
                    exit 1
                fi
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]] || (( ($2 & ($2 - 1)) != 0 )); then
                    print_error "--cpu must be a power of 2 (1, 2, 4, 8, 16...). Got: '$2'"
                    exit 1
                fi
                local _host_cpus; _host_cpus=$(nproc)
                if (( $2 > _host_cpus )); then
                    print_error "--cpu cannot exceed host CPU count (${_host_cpus}). Got: '$2'"
                    exit 1
                fi
                local _min_cpu=1
                [[ "${SUPPORTS_MIN_RESOURCES:-}" == "pxe" ]] && _min_cpu=2
                if (( $2 < _min_cpu )); then
                    print_error "--cpu must be at least ${_min_cpu} for this operation. Got: '$2'"
                    exit 1
                fi
                VM_CPUS="$2"
                VM_CPUS_SPECIFIED=true
                shift 2
                ;;
            --memory)
                if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                    print_error "--memory requires a value in GiB (power of 2)."
                    exit 1
                fi
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]] || (( ($2 & ($2 - 1)) != 0 )); then
                    print_error "--memory must be a power of 2 in GiB (1, 2, 4, 8, 16...). Got: '$2'"
                    exit 1
                fi
                local _host_mem_kib; _host_mem_kib=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
                local _host_mem_gib=$(( _host_mem_kib / 1024 / 1024 ))
                if (( $2 >= _host_mem_gib )); then
                    print_error "--memory must be less than host memory (${_host_mem_gib} GiB). Got: '$2'"
                    exit 1
                fi
                local _min_mem=1
                [[ "${SUPPORTS_MIN_RESOURCES:-}" == "pxe" ]] && _min_mem=2
                if (( $2 < _min_mem )); then
                    print_error "--memory must be at least ${_min_mem} GiB for this operation. Got: '$2'"
                    exit 1
                fi
                VM_MEMORY="$2"
                VM_MEMORY_SPECIFIED=true
                shift 2
                ;;
            --root-disk-size)
                if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                    print_error "--root-disk-size requires a value in GiB (multiple of 5)."
                    exit 1
                fi
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]] || (( $2 < 30 || $2 > 500 || $2 % 5 != 0 )); then
                    print_error "--root-disk-size must be 30-500 GiB (minimum 30 GiB, multiple of 5). Got: '$2'"
                    exit 1
                fi
                VM_DISK_SIZE="$2"
                VM_DISK_SIZE_SPECIFIED=true
                shift 2
                ;;
            -*)
                print_error "No such option: $1"
                fn_show_help
                exit 1
                ;;
            *)
                print_error "Unexpected argument: $1"
                print_info "Use -H/--hosts to specify hostname(s)."
                fn_show_help
                exit 1
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
