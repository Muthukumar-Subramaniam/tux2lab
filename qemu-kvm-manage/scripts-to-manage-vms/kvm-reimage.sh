#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: kvm-reimage.sh                                                           #
# Description: Reinstall VM(s) — golden image (default) or PXE boot                     #
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
    tux2lab vm reimage [OPTIONS] [ARGUMENTS]

DESCRIPTION:
    Wipe and reinstall VM(s). Uses golden image by default (fast disk clone) or
    full PXE network reinstall. Preserves existing VM identity (MAC address) while
    replacing the OS. Supports stack mode switching, resource overrides (CPU, memory,
    disk), auto-detection of previous OS, and --reset-specs-to-default for a clean slate.

OPTIONS:
    --via-golden        Reinstall from golden image (default)
    --via-pxe           Reinstall via PXE network boot
    -H <hostnames>      Hostname(s) to reinstall (comma-separated)
    -d <distro>         OS distribution
    -v <version>        OS version
    --console           Attach to serial console during install (PXE only)
    --ipv4-only         Reimage as IPv4-only VM
    --ipv6-only         Reimage as IPv6-only VM
    --dual-stack        Force dual-stack (override auto-detected single-stack)
    --cpu <n>           vCPUs (power of 2, default: 2)
    --memory <n>        RAM in GiB (power of 2, default: 2)
    --root-disk-size <n> Disk in GiB (multiple of 5, default: 30)
    --reset-specs-to-default  Destroy and reinstall with default specs
    -f, --force         Skip confirmation prompt
    -h, --help          Show this help message

EXAMPLES:
    tux2lab vm reimage -H testvm1
    tux2lab vm reimage -H testvm1 -d rocky -v 10
    tux2lab vm reimage -H testvm1 --ipv4-only
    tux2lab vm reimage -H testvm1 --ipv6-only -d debian -v 13
    tux2lab vm reimage -H testvm1 --dual-stack --cpu 4 --memory 8
    tux2lab vm reimage -H testvm1 --root-disk-size 50
    tux2lab vm reimage -H testvm1 --reset-specs-to-default
    tux2lab vm reimage --via-pxe -H testvm1 -d ubuntu-lts -v 24.04
    tux2lab vm reimage --via-pxe -H testvm1 --console
    tux2lab vm reimage -f -H testvm1,testvm2,testvm3"
            exit 0
            ;;
        *)
            pass_args+=("$arg")
            ;;
    esac
done

if [[ "$method" == "pxe" ]]; then
    exec "$SCRIPT_DIR/kvm-reimage-pxe.sh" "${pass_args[@]}"
else
    exec "$SCRIPT_DIR/kvm-reimage-golden.sh" "${pass_args[@]}"
fi
