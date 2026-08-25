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
    Deploy new VM(s). Uses golden image by default (fast disk clone) or full
    PXE network install. Supports per-VM stack mode selection (dual/IPv4/IPv6),
    custom resource specs (CPU, memory, disk), multi-VM batch deployment, and
    console attachment for monitoring PXE installations.

OPTIONS:
    --via-golden        Deploy from golden image (default)
    --via-pxe           Deploy via PXE network boot
    -H <hostnames>      Hostname(s) to deploy (comma-separated)
    -d <distro>         OS distribution
    -v <version>        OS version
    --console           Attach to serial console during install (PXE only)
    --ipv4-only         Create IPv4-only VM
    --ipv6-only         Create IPv6-only VM
    --dual-stack        Create dual-stack VM (default if neither is specified)
    --cpu <n>           vCPUs (power of 2, default: 2)
    --memory <n>        RAM in GiB (power of 2, default: 2)
    --root-disk-size <n> Disk in GiB (multiple of 5, default: 30)
    -h, --help          Show this help message

EXAMPLES:
    tux2lab vm install -H testvm1
    tux2lab vm install -H testvm1 -d almalinux -v 10
    tux2lab vm install -H testvm1 --ipv4-only -d almalinux -v 10
    tux2lab vm install -H testvm1 --ipv6-only -d rocky -v 10
    tux2lab vm install -H testvm1 --cpu 4 --memory 8 --root-disk-size 50
    tux2lab vm install -H testvm1,testvm2,testvm3
    tux2lab vm install --via-pxe -H testvm1 -d ubuntu-lts -v 24.04
    tux2lab vm install --via-pxe -H testvm1 --console"
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
