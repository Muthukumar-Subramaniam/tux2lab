#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: deploy.sh                                                                #
# Description: Deploy a new lab infrastructure server                                    #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh

# ====== HELP ======
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_cyan "USAGE:
    tux2lab deploy

DESCRIPTION:
    Deploy a new lab infrastructure server. This is the starting point
    for creating your tux2lab KVM environment.

    Guides you through an interactive setup to configure:
    - Admin credentials (password)
    - SSH keys and SSL certificates
    - All service configurations (DNS, DHCP, NTP, HTTP, TFTP, NFS)

    Deploys the tux2lab-engine container with all lab services.

    Prerequisites:
    - Run setup/setup-host.sh first to prepare the host"
    exit 0
fi

if [[ $# -gt 0 ]]; then
    print_error "Unknown argument: $1"
    echo "Run 'tux2lab deploy --help' for usage information."
    exit 1
fi

if [[ "$EUID" -eq 0 ]]; then
    print_error "Running as root user is not allowed."
    print_info "This script should be run as a user with sudo privileges, not as root."
    exit 1
fi

exec /tux2lab/setup/deploy-lab.sh
