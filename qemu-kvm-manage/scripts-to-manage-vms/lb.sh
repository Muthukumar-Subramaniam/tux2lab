#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: lb.sh                                                                     #
# Description: Manage TCP load balancers for the tux2lab infrastructure                   #
# If you encounter any issues with this script, or have suggestions or feature requests,  #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues       #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# ====== HELP ======
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_cyan "USAGE:
    tux2lab lb <command> [options]

DESCRIPTION:
    Manage nginx TCP stream load balancers on the lab infrastructure.
    Run without arguments for an interactive menu.

COMMANDS:
    create          Create a new TCP load balancer
    delete          Delete an existing load balancer
    update          Update backends, ports, or algorithm
    list            List all configured load balancers
    status          Check health of load balancers
    restore         Re-apply secondary IPs from registry

OPTIONS (create):
    --name           Load balancer name (DNS hostname)
    --port           Listen port (frontend)
    --target-port    Backend server port
    --backends       Comma-separated backend hostnames
    --algorithm      round-robin (default), least-conn, ip-hash
    -y, --yes        Skip interactive prompts

OPTIONS (delete):
    --name           Load balancer name
    -y, --yes        Skip confirmation prompt

OPTIONS (update):
    --name           Load balancer name
    --add-backend    Add backend(s), comma-separated
    --remove-backend Remove backend(s), comma-separated
    --port           Change listen port
    --target-port    Change target port
    --algorithm      Change algorithm

OPTIONS (status):
    --name           Check specific load balancer (default: all)

EXAMPLES:
    tux2lab lb create --name k8s-api --port 6443 --target-port 6443 \\
        --backends k8s-cp1,k8s-cp2,k8s-cp3 --algorithm least-conn

    tux2lab lb update --name k8s-api --add-backend k8s-cp4

    tux2lab lb delete --name k8s-api -y

    tux2lab lb list

    tux2lab lb status --name k8s-api"
    exit 0
fi

# ====== VALIDATE SUBCOMMAND ======
if [[ $# -gt 0 ]]; then
    valid_subcommands=(create delete update list status restore)
    subcommand_is_valid=false
    for sub in "${valid_subcommands[@]}"; do
        if [[ "$1" == "$sub" ]]; then
            subcommand_is_valid=true
            break
        fi
    done
    if ! $subcommand_is_valid; then
        print_error "Unknown subcommand: $1"
        echo "Run 'tux2lab lb --help' for usage information."
        exit 1
    fi
fi

# ====== PREREQUISITE: labbr0 must be up ======
if ! ip link show labbr0 &>/dev/null; then
    print_error "labbr0 interface is not available!"
    print_info "Start the lab infrastructure first: tux2lab start"
    exit 1
fi

# ====== INVOKE LBMANAGER ======
sudo /tux2lab/lb-manage/lbmanager.sh "$@"
