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
    print_cyan "tux2lab - KVM Lab Management Tool
├─ Version    : $VERSION
├─ Repository : https://github.com/Muthukumar-Subramaniam/tux2lab
└─ Issues     : https://github.com/Muthukumar-Subramaniam/tux2lab/issues"
}

# Display usage information
show_usage() {
    show_version
    echo ""
    print_cyan "USAGE:
    tux2lab <command> [options] [arguments]

COMMANDS:
    vm          Manage KVM virtual machines
    golden-image Manage golden image disks for OS provisioning
    distro      Manage OS distributions for PXE provisioning
    start       Start the lab infrastructure
    health      Check lab infrastructure health
    dns         Manage DNS records for lab infrastructure
    ipv6-route  Manage IPv6 default routes on lab VMs

OPTIONS:
    -h, --help              Show this help message
    -v, --version           Show version information

EXAMPLES:
    tux2lab vm list                  # List all VMs and their status
    tux2lab vm install-pxe vm1      # Deploy VM using PXE boot
    tux2lab golden-image list        # List available golden images
    tux2lab golden-image create      # Build a golden image
    tux2lab distro list              # List distro readiness status
    tux2lab distro setup             # Setup a distro for PXE provisioning
    tux2lab dns -c vm1 10.0.0.5     # Create DNS record
    tux2lab ipv6-route status        # Show IPv6 route status for all VMs
    tux2lab ipv6-route auto          # Auto-configure IPv6 routes

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
        health)
            exec "$SCRIPT_DIR/health.sh" "$@"
            ;;
        dns)
            exec "$SCRIPT_DIR/dns.sh" "$@"
            ;;
        ipv6-route)
            exec "$SCRIPT_DIR/ipv6-route.sh" "$@"
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
