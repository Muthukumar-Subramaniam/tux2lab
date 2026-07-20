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
