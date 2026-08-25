#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
# Script Name : tux2lab
# Description : Unified command-line interface for managing the tux2lab KVM environment
# Usage       : tux2lab <command> [options] [args]

set -euo pipefail

# Source color functions
source /tux2lab/common-utils/color-functions.sh

# Script directory - same directory as this script
SCRIPT_DIR="/tux2lab/qemu-kvm-manage/scripts-to-manage-vms"

# Version - read from project_version.json
VERSION=$(grep -o '"version": *"[^"]*"' /tux2lab/project_version.json | cut -d'"' -f4)

# Show version
show_version() {
    print_cyan "tux2lab - Virtual Lab Management Tool
├─ Version    : $VERSION
├─ Repository : https://github.com/Muthukumar-Subramaniam/tux2lab
└─ Issues     : https://github.com/Muthukumar-Subramaniam/tux2lab/issues"
}

# Display usage information
show_usage() {
    show_version
    echo ""
    print_cyan "DESCRIPTION:
    Transform your Linux workstation into a powerful, automated virtual datacenter.
    Build golden images via PXE boot, then deploy VMs in seconds from those images.
    Supports Red Hat, Debian, and SUSE families with dual-stack networking, automated
    infrastructure services, and complete VM lifecycle management.

USAGE:
    tux2lab <command> [options] [arguments]

VM MANAGEMENT:
    vm               Manage virtual machines
    golden-image     Manage golden image disks for OS provisioning
    distro           Manage OS distributions for PXE provisioning
    ipv6-route       Manage IPv6 default routes on lab VMs

LAB OPERATIONS:
    start            Start the lab infrastructure
    stop             Stop the lab infrastructure
    enable           Enable lab infrastructure auto-start on boot
    disable          Disable lab infrastructure auto-start on boot
    health           Check lab infrastructure health
    info             Display lab deployment information
    dns              Manage DNS records for lab infrastructure
    credentials      Manage lab credentials (password, SSH keys, cert)
    logflush         Clear all service log files

LAB ADD-ONS:
    lb               Manage TCP load balancers

LAB LIFECYCLE:
    deploy           Deploy the lab environment (one-time setup)
    rebuild          Regenerate configs and recreate container
    destroy          Permanently destroy the entire lab environment

OPTIONS:
    -h, --help       Show this help message
    -v, --version    Show version information

Use 'tux2lab <command> --help' for more information about a specific command."
}

# Main logic
main() {
    # No arguments or help flag
    if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        show_usage
        exit 0
    fi

    local command="$1"
    shift

    # Handle version flag
    if [[ "$command" == "version" ]] || [[ "$command" == "-v" ]] || [[ "$command" == "--version" ]]; then
        show_version
        exit 0
    fi

    # Dispatch to the appropriate script
    case "$command" in
        vm)
            exec "$SCRIPT_DIR/vm.sh" "$@"
            ;;
        distro)
            exec "$SCRIPT_DIR/distro.sh" "$@"
            ;;
        golden-image)
            exec "$SCRIPT_DIR/golden-image.sh" "$@"
            ;;
        start)
            exec "$SCRIPT_DIR/start.sh" "$@"
            ;;
        stop)
            exec "$SCRIPT_DIR/stop.sh" "$@"
            ;;
        enable)
            exec "$SCRIPT_DIR/enable.sh" "$@"
            ;;
        disable)
            exec "$SCRIPT_DIR/disable.sh" "$@"
            ;;
        health)
            exec "$SCRIPT_DIR/health.sh" "$@"
            ;;
        dns)
            exec "$SCRIPT_DIR/dns.sh" "$@"
            ;;
        lb)
            exec "$SCRIPT_DIR/lb.sh" "$@"
            ;;
        deploy)
            exec "$SCRIPT_DIR/deploy.sh" "$@"
            ;;
        destroy)
            exec "$SCRIPT_DIR/destroy.sh" "$@"
            ;;
        rebuild)
            exec "$SCRIPT_DIR/rebuild.sh" "$@"
            ;;
        sync)
            # Deprecated alias — redirect to rebuild
            exec "$SCRIPT_DIR/rebuild.sh" "$@"
            ;;
        ipv6-route)
            exec "$SCRIPT_DIR/ipv6-route.sh" "$@"
            ;;
        info)
            exec "$SCRIPT_DIR/info.sh" "$@"
            ;;
        credentials)
            exec "$SCRIPT_DIR/credentials.sh" "$@"
            ;;
        logflush)
            exec "$SCRIPT_DIR/logflush.sh" "$@"
            ;;
        *)
            print_error "Unknown command: $command"
            echo
            echo "Run 'tux2lab --help' to see available commands"
            exit 1
            ;;
    esac
}

main "$@"
