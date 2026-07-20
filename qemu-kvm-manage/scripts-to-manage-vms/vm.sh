#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
# Script Name : vm.sh
# Description : VM subcommand dispatcher for the tux2lab CLI
# Usage       : tux2lab vm <subcommand> [options] [args]

set -euo pipefail

# Source color functions
source /tux2lab/common-utils/color-functions.sh

# Script directory - same directory as this script
SCRIPT_DIR="/tux2lab/qemu-kvm-manage/scripts-to-manage-vms"

# Version - read from project_version.json
VERSION=$(grep -o '"version": *"[^"]*"' /tux2lab/project_version.json | cut -d'"' -f4)

# Show version
show_version() {
    print_cyan "tux2lab vm - Lab VM Management Tool
├─ Version    : $VERSION
├─ Repository : https://github.com/Muthukumar-Subramaniam/tux2lab
└─ Issues     : https://github.com/Muthukumar-Subramaniam/tux2lab/issues"
}

# Display usage information
show_usage() {
    show_version
    echo ""
    print_cyan "USAGE:
    tux2lab vm <subcommand> [options] [arguments]

VM DEPLOYMENT:
    install                 Deploy VM(s) [--via-golden (default) | --via-pxe]
    reimage                 Reinstall VM(s) [--via-golden (default) | --via-pxe]

VM OPERATIONS:
    list                    List all VMs and their status
    info                    Display detailed VM information
    validate                Validate post-install state of VM(s)
    console                 Connect to VM serial console
    start                   Start VM(s)
    stop                    Force stop (power off) VM(s)
    shutdown                Gracefully shutdown VM(s)
    restart                 Hard restart (reset) VM(s)
    reboot                  Gracefully reboot VM(s)
    remove                  Delete VM(s) and its data

VM CONFIGURATION:
    resize                  Resize VM resources (CPU, memory, disk)
    disk-add                Add additional disk to VM
    disk-resize             Resize additional disk(s)
    disk-attach             Attach disk(s) from detached storage
    disk-detach             Detach and save disk(s) from VM
    disk-delete             Permanently delete disk(s) from detached storage
    nic-add                 Add network interface to VM
    nic-remove              Remove network interface from VM

VM SNAPSHOTS:
    snapshot-create         Create an offline snapshot of VM(s)
    snapshot-list           List all snapshots for VM(s)
    snapshot-info           Show detailed snapshot information
    snapshot-delete         Delete a snapshot from VM(s)
    snapshot-revert         Revert VM(s) to a previous snapshot

OPTIONS:
    -h, --help              Show this help message
    -v, --version           Show version information

NOTES:
    - Use 'tux2lab vm <subcommand> --help' to see help for a specific subcommand"
}

# Main logic
main() {
    # No arguments or help flag
    if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        show_usage
        exit 0
    fi
    
    local subcommand="$1"
    shift
    
    # Handle version flag
    if [[ "$subcommand" == "version" ]] || [[ "$subcommand" == "-v" ]] || [[ "$subcommand" == "--version" ]]; then
        show_version
        exit 0
    fi
    
    # Map subcommand to script
    local script_name=""
    case "$subcommand" in
        start|stop|shutdown|restart|reboot|remove|list|console|resize|info|validate)
            script_name="kvm-${subcommand}.sh"
            ;;
        install|reimage)
            script_name="kvm-${subcommand}.sh"
            ;;
        disk-add|disk-resize|disk-attach|disk-detach|disk-delete|nic-add|nic-remove)
            script_name="kvm-${subcommand}.sh"
            ;;
        snapshot-create|snapshot-list|snapshot-info|snapshot-delete|snapshot-revert)
            script_name="kvm-${subcommand}.sh"
            ;;
        *)
            print_error "Unknown subcommand: $subcommand"
            echo
            echo "Run 'tux2lab vm --help' to see available subcommands"
            exit 1
            ;;
    esac
    
    # Check if script exists
    local script_path="$SCRIPT_DIR/$script_name"
    if [[ ! -f "$script_path" ]]; then
        print_error "Script not found: $script_name"
        exit 1
    fi
    
    # Execute the underlying script with all remaining arguments
    exec "$script_path" "$@"
}

main "$@"
