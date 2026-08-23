# Lab running-state guards
# Provides fn_lab_is_running, fn_require_lab_running and
# fn_require_lab_running_unless_help.
# Source this file, do not execute directly.
#
# Requires the print helpers from common-utils/color-functions.sh.

# The bridge is created by the 'tux2lab' libvirt network, so it tracks lab state
# without naming a libvirt unit, which varies by distro. Probing virsh instead
# is correct but costs roughly 700ms on every command.
fn_lab_is_running() {
    ip link show "${lab_infra_bridge_interface:-labbr0}" &>/dev/null
}

# Guard for commands that talk to libvirt. Without it virsh leaks raw
# hypervisor connection errors and the command still exits 0.
fn_require_lab_running() {
    if fn_lab_is_running; then
        return 0
    fi

    local env_json="${LAB_ENV_JSON:-/tux2lab-data/lab-config/lab_environment.json}"
    if [[ ! -f "${env_json}" ]]; then
        print_red "No lab is deployed on this host."
        print_yellow "Deploy one with: tux2lab deploy"
        exit 1
    fi

    print_red "The lab is not running."
    print_yellow "Start it with: tux2lab start"
    exit 1
}

# Same guard, but lets help requests through so usage text stays readable
# while the lab is stopped.
fn_require_lab_running_unless_help() {
    local arg
    for arg in "$@"; do
        if [[ "${arg}" == "-h" || "${arg}" == "--help" ]]; then
            return 0
        fi
    done

    fn_require_lab_running
}
