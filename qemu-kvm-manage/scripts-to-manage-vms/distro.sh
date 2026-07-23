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

readonly PREPARE_SCRIPT="/tux2lab/ks-manage/prepare-distro-for-ksmanager.sh"

show_distro_help() {
    print_cyan "USAGE:
    tux2lab distro <command> [<distro> -v <version>]
    tux2lab distro -h

DESCRIPTION:
    Manage OS distributions for PXE-based provisioning. Before a distro can
    be used to install or reimage VMs, its boot media must be downloaded and
    prepared. This command handles that lifecycle.

    Note: If a distro is not yet set up when building a golden image, it
    will be prepared automatically. This command is useful for pre-staging
    ISOs ahead of time or cleaning up disk space.

COMMANDS:
    list                        List all distros with PXE and golden image readiness
    setup                       Download ISO and prepare a distro for PXE provisioning
    cleanup                     Unmount ISO and remove files to free disk space
    -h, --help                  Show this help message

ARGUMENTS:
    <distro>                    OS distribution identifier (see below)
    -v, --version <version>     OS version number (see below)
                                If omitted, an interactive menu is displayed.
    -f, --force                 Skip confirmation prompt (cleanup only)

SUPPORTED DISTROS AND VERSIONS:
    almalinux                   10, 9, 8
    rocky                       10, 9, 8
    oraclelinux                 10, 9, 8
    centos-stream               10, 9, 8
    rhel                        10, 9, 8
    ubuntu-lts                  26.04, 24.04, 22.04
    debian                      13, 12, 11
    opensuse-leap               16.0, 15.6

EXAMPLES:
    tux2lab distro list
    tux2lab distro setup                                    # Interactive mode
    tux2lab distro setup almalinux -v 10                    # Non-interactive mode
    tux2lab distro setup almalinux --version 10             # Long form
    tux2lab distro cleanup almalinux -v 10                  # Free disk space
    tux2lab distro cleanup almalinux -v 10 --force          # Skip confirmation"
}

# Show help without requiring lab environment
if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_distro_help
    exit 0
fi

# All other subcommands require the lab environment to be deployed
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# Run prepare-distro-for-ksmanager.sh directly (v2.0.0 — all local)
run_on_infra_server() {
    "${PREPARE_SCRIPT}" "$@"
}

subcommand="$1"
shift

case "$subcommand" in
    list)
        if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
            show_distro_help
            exit 0
        fi
        # Golden images are always on the KVM host — collect filenames
        golden_images=""
        if [[ -d "/tux2lab-data/golden-images-disk-store" ]]; then
            golden_images=$(ls /tux2lab-data/golden-images-disk-store/*.qcow2 2>/dev/null | xargs -I{} basename {} .qcow2 | tr '\n' ',' || true)
        fi
        GOLDEN_IMAGES_ON_HOST="$golden_images" "${PREPARE_SCRIPT}" --list
        ;;
    setup)
        if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
            show_distro_help
            exit 0
        fi
        # Validate distro/version locally before SSH to infra server
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/validate-distro-version.sh
        _distro="" _version="" _prev=""
        for _arg in "$@"; do
            if [[ "$_prev" == "-v" || "$_prev" == "--version" ]]; then
                _version="$_arg"; _prev="$_arg"; continue
            fi
            _prev="$_arg"
            case "$_arg" in -v|--version|-*) continue ;; *) [[ -z "$_distro" ]] && _distro="$_arg" ;; esac
        done
        validate_distro_version "$_distro" "$_version"
        run_on_infra_server --setup "$@"
        ;;
    cleanup)
        if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
            show_distro_help
            exit 0
        fi
        # Validate distro/version locally before SSH to infra server
        source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/validate-distro-version.sh
        _distro="" _version="" _prev=""
        for _arg in "$@"; do
            if [[ "$_prev" == "-v" || "$_prev" == "--version" ]]; then
                _version="$_arg"; _prev="$_arg"; continue
            fi
            _prev="$_arg"
            case "$_arg" in -v|--version|-*) continue ;; *) [[ -z "$_distro" ]] && _distro="$_arg" ;; esac
        done
        validate_distro_version "$_distro" "$_version"
        run_on_infra_server --cleanup "$@"
        ;;
    *)
        print_error "Unknown distro subcommand: $subcommand"
        echo
        show_distro_help
        exit 1
        ;;
esac
