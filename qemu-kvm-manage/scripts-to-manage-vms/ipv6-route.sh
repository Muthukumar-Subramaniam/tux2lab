#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
# Script Name : ipv6-route.sh
# Description : Top-level dispatcher for 'tux2lab ipv6-route' command
# Usage       : tux2lab ipv6-route <enable|disable|check|auto|status>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec "$SCRIPT_DIR/kvm-ipv6-route.sh" "$@"
