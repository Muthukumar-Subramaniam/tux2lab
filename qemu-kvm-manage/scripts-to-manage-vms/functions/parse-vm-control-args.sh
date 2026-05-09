# parse-vm-control-args.sh
# 
# Parses common arguments for VM control scripts (start/stop/shutdown/reboot/restart/remove)
#
# Usage:
#   SUPPORTS_FORCE="yes"  # Set to "yes" if script supports -f/--force flag
#   SUPPORTS_IGNORE_KSMANAGER="yes"  # Set to "yes" if script supports --ignore-ksmanager-cleanup flag
#   source /path/to/parse-vm-control-args.sh
#   parse_vm_control_args "$@"
#
# Sets global variables:
#   FORCE_FLAG - true/false (only if SUPPORTS_FORCE="yes")
#   IGNORE_KSMANAGER_CLEANUP - true/false (only if SUPPORTS_IGNORE_KSMANAGER="yes")
#   HOSTS_LIST - comma-separated list of hostnames (if --hosts provided)
#   VM_HOSTNAME_ARG - single hostname argument (if provided)
#
# Note: Script must define fn_show_help() function before sourcing this

parse_vm_control_args() {
    # Initialize variables based on script support
    if [[ "${SUPPORTS_FORCE:-no}" == "yes" ]]; then
        FORCE_FLAG=false
    fi
    if [[ "${SUPPORTS_IGNORE_KSMANAGER:-no}" == "yes" ]]; then
        IGNORE_KSMANAGER_CLEANUP=false
    fi
    HOSTS_LIST=""
    VM_HOSTNAME_ARG=""
    
    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                fn_show_help
                exit 0
                ;;
            -f|--force)
                if [[ "${SUPPORTS_FORCE:-no}" == "yes" ]]; then
                    FORCE_FLAG=true
                    shift
                else
                    print_error "No such option: $1"
                    fn_show_help
                    exit 1
                fi
                ;;
            --ignore-ksmanager-cleanup)
                if [[ "${SUPPORTS_IGNORE_KSMANAGER:-no}" == "yes" ]]; then
                    IGNORE_KSMANAGER_CLEANUP=true
                    shift
                else
                    print_error "No such option: $1"
                    fn_show_help
                    exit 1
                fi
                ;;
            -H|--hosts)
                if [[ -z "$2" || "$2" == -* ]]; then
                    print_error "--hosts requires a comma-separated list of hostnames."
                    fn_show_help
                    exit 1
                fi
                HOSTS_LIST="$2"
                shift 2
                ;;
            -*)
                print_error "No such option: $1"
                fn_show_help
                exit 1
                ;;
            *)
                # This is the hostname argument
                if [[ -n "$HOSTS_LIST" ]]; then
                    print_error "Cannot use both hostname argument and --hosts option."
                    fn_show_help
                    exit 1
                fi
                VM_HOSTNAME_ARG="$1"
                shift
                ;;
        esac
    done
}
