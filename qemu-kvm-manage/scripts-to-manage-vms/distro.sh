#!/bin/bash
#----------------------------------------------------------------------------------------#
# Script Name: distro.sh                                                                 #
# Description: Manage OS distributions for PXE provisioning                              #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh
source /tux2lab/ks-manage/distro-versions.conf

show_distro_help() {
    print_cyan "USAGE:
    tux2lab distro <subcommand> [options]

SUBCOMMANDS:
    list                            List all distros with readiness status
    setup [distro --version ver]    Setup a distro for PXE provisioning
    cleanup [distro --version ver]  Remove a distro's PXE provisioning setup

OPTIONS:
    -h, --help                      Show this help message

EXAMPLES:
    tux2lab distro list
    tux2lab distro setup                                    # Interactive mode
    tux2lab distro setup almalinux --version 10             # Non-interactive mode
    tux2lab distro cleanup almalinux --version 10"
}

# Run a command on the infra server (locally in HOST mode, via SSH in VM mode)
run_on_infra_server() {
    local cmd="$1"
    if $lab_infra_server_mode_is_host; then
        eval "$cmd"
    else
        ssh -o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -t \
            "${lab_infra_admin_username}@${lab_infra_server_hostname}" "$cmd"
    fi
}

distro_list() {
    run_on_infra_server "/tux2lab/ks-manage/prepare-distro-for-ksmanager.sh --list"
}

distro_setup() {
    if [[ $# -eq 0 ]]; then
        run_on_infra_server "/tux2lab/ks-manage/prepare-distro-for-ksmanager.sh --setup"
    else
        run_on_infra_server "/tux2lab/ks-manage/prepare-distro-for-ksmanager.sh --setup $*"
    fi
}

distro_cleanup() {
    if [[ $# -eq 0 ]]; then
        run_on_infra_server "/tux2lab/ks-manage/prepare-distro-for-ksmanager.sh --cleanup"
    else
        run_on_infra_server "/tux2lab/ks-manage/prepare-distro-for-ksmanager.sh --cleanup $*"
    fi
}

# Main dispatch
if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_distro_help
    exit 0
fi

subcommand="$1"
shift

case "$subcommand" in
    list)
        distro_list
        ;;
    setup)
        distro_setup "$@"
        ;;
    cleanup)
        distro_cleanup "$@"
        ;;
    *)
        print_error "Unknown distro subcommand: $subcommand"
        echo
        show_distro_help
        exit 1
        ;;
esac
