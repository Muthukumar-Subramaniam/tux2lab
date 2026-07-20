#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: kvm-install.sh                                                           #
# Description: Deploy VM(s) — golden image (default) or PXE boot                        #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect --via-pxe or --via-golden flag
method="golden"
pass_args=()

for arg in "$@"; do
    case "$arg" in
        --via-pxe)
            method="pxe"
            ;;
        --via-golden)
            method="golden"
            ;;
        -h|--help)
            print_cyan "USAGE:
    tux2lab vm install [OPTIONS] [ARGUMENTS]

DESCRIPTION:
    Deploy new VM(s). Uses golden image by default (fast disk clone).
    Use --via-pxe for a full network install.

OPTIONS:
    --via-golden        Deploy from golden image (default)
    --via-pxe           Deploy via PXE network boot
    -H <hostnames>      Hostname(s) to deploy (comma-separated)
    -d <distro>         OS distribution
    -v <version>        OS version
    --console           Attach to serial console during install (PXE only)
    -h, --help          Show this help message

EXAMPLES:
    tux2lab vm install -H vm1
    tux2lab vm install -H vm1 -d almalinux -v 10
    tux2lab vm install -H vm1,vm2,vm3
    tux2lab vm install --via-pxe -H vm1 -d ubuntu-lts -v 24.04
    tux2lab vm install --via-pxe -H vm1 --console"
            exit 0
            ;;
        *)
            pass_args+=("$arg")
            ;;
    esac
done

if [[ "$method" == "pxe" ]]; then
    exec "$SCRIPT_DIR/kvm-install-pxe.sh" "${pass_args[@]}"
else
    exec "$SCRIPT_DIR/kvm-install-golden.sh" "${pass_args[@]}"
fi
