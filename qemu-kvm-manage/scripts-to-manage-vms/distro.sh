#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: distro.sh                                                                 #
# Description: Manage OS distributions for PXE provisioning                              #
# Invoked by : tux2lab distro {list|setup|cleanup} [distro] [--version ver]              #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

readonly PREPARE_SCRIPT="/tux2lab/ks-manage/prepare-distro-for-ksmanager.sh"

show_distro_help() {
    print_cyan "USAGE:
    tux2lab distro <subcommand> [options]

SUBCOMMANDS:
    list                            List all distros with readiness status
    setup [distro --version|-v ver]    Setup a distro for PXE provisioning
    cleanup [distro --version|-v ver]  Remove a distro's PXE provisioning setup

OPTIONS:
    -h, --help                      Show this help message

EXAMPLES:
    tux2lab distro list
    tux2lab distro setup                                    # Interactive mode
    tux2lab distro setup almalinux --version 10             # Non-interactive mode
    tux2lab distro setup almalinux -v 10                    # Short form
    tux2lab distro cleanup almalinux --version 10"
}

# Run prepare-distro-for-ksmanager.sh on the infra server
run_on_infra_server() {
    if $lab_infra_server_mode_is_host; then
        "${PREPARE_SCRIPT}" "$@"
    else
        ssh -o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -t \
            "${lab_infra_admin_username}@${lab_infra_server_hostname}" \
            "${PREPARE_SCRIPT}" "$@"
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
        # Golden images are always on the KVM host — collect filenames locally
        # and pass to infra server so it can display the status
        golden_images=""
        if [[ -d "/tux2lab-data/golden-images-disk-store" ]]; then
            golden_images=$(ls /tux2lab-data/golden-images-disk-store/*.qcow2 2>/dev/null | xargs -I{} basename {} .qcow2 | tr '\n' ',' || true)
        fi
        if $lab_infra_server_mode_is_host; then
            GOLDEN_IMAGES_ON_HOST="$golden_images" "${PREPARE_SCRIPT}" --list
        else
            ssh -o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -t \
                "${lab_infra_admin_username}@${lab_infra_server_hostname}" \
                "GOLDEN_IMAGES_ON_HOST='${golden_images}' ${PREPARE_SCRIPT} --list"
        fi
        ;;
    setup)
        run_on_infra_server --setup "$@"
        ;;
    cleanup)
        run_on_infra_server --cleanup "$@"
        ;;
    *)
        print_error "Unknown distro subcommand: $subcommand"
        echo
        show_distro_help
        exit 1
        ;;
esac
