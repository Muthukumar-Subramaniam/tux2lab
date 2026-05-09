#!/bin/bash

# IPv6 Default Route Manager for Lab VMs
# Purpose: Enable/disable IPv6 default gateway when QEMU host has/loses IPv6 internet connectivity
# Usage: Run from QEMU host to manage routes on all running VMs

set -uo pipefail

# Source color functions
source /tux2lab/common-utils/color-functions.sh

# Source lab environment variables
if [[ -f /kvm-hub/lab_environment_vars ]]; then
    source /kvm-hub/lab_environment_vars
else
    print_error "Lab environment not configured. Run deploy-lab-infra-server.sh first."
    exit 1
fi

# Validate required variables
if [[ -z "${lab_infra_server_ipv6_gateway:-}" ]]; then
    print_error "IPv6 gateway not configured in lab environment."
    exit 1
fi

if [[ -z "${lab_infra_admin_username:-}" ]]; then
    print_error "Admin username not configured in lab environment."
    exit 1
fi

IPV6_TEST_HOST="2001:4860:4860::8888"  # Google Public DNS IPv6
IPV6_GATEWAY="${lab_infra_server_ipv6_gateway}"

# SSH options for connecting to VMs
ssh_options="-o StrictHostKeyChecking=no \
             -o UserKnownHostsFile=/dev/null \
             -o LogLevel=QUIET \
             -o ConnectTimeout=2 \
             -o PasswordAuthentication=no \
             -o PubkeyAuthentication=yes \
             -o PreferredAuthentications=publickey \
             -o BatchMode=yes"

fn_usage() {
    cat << EOF
$(print_notify "IPv6 Default Route Manager")

Usage: qlabvmctl ipv6-route [OPTION]

Options:
    enable      Enable IPv6 default route on all running VMs
    disable     Disable IPv6 default route on all running VMs
    check       Check IPv6 internet connectivity and current route status
    auto        Automatically enable/disable based on host IPv6 connectivity
    status      Show IPv6 route status for all VMs

Examples:
    qlabvmctl ipv6-route enable      # Enable IPv6 default route
    qlabvmctl ipv6-route disable     # Remove IPv6 default route
    qlabvmctl ipv6-route check       # Test connectivity and show status
    qlabvmctl ipv6-route auto        # Auto-configure based on connectivity

Note: This script manages the default IPv6 route. Local IPv6 subnet routes
      are always present regardless of this setting.
EOF
}

fn_test_ipv6_connectivity() {
    print_task "Testing IPv6 internet connectivity from QEMU host..."
    
    if ping6 -c 2 -W 3 "$IPV6_TEST_HOST" &>/dev/null; then
        print_task_done
        print_success "IPv6 internet connectivity available"
        return 0
    else
        print_task_fail
        print_warning "No IPv6 internet connectivity"
        return 1
    fi
}

fn_get_running_vms() {
    sudo virsh list --name | grep -v "^$"
}

fn_vm_is_ssh_ready() {
    local vm_name="$1"
    nc -z -w 1 "$vm_name" 22 &>/dev/null
    return $?
}

fn_enable_ipv6_route() {
    local vm_name="$1"
    
    if ! fn_vm_is_ssh_ready "$vm_name"; then
        print_warning "VM $vm_name: SSH not ready, skipping"
        return 1
    fi
    
    # Check if route already exists
    local route_check=$(ssh $ssh_options "${lab_infra_admin_username}@${vm_name}" \
        'sudo ip -6 route show default' 2>/dev/null)
    
    if [[ "$route_check" =~ "default" ]]; then
        print_info "VM $vm_name: IPv6 default route already exists"
        return 0
    fi
    
    # Add default route
    if ssh $ssh_options "${lab_infra_admin_username}@${vm_name}" \
        "sudo ip -6 route add default via ${IPV6_GATEWAY}" &>/dev/null; then
        print_success "VM $vm_name: IPv6 default route added"
        return 0
    else
        print_error "VM $vm_name: Failed to add IPv6 default route"
        return 1
    fi
}

fn_disable_ipv6_route() {
    local vm_name="$1"
    
    if ! fn_vm_is_ssh_ready "$vm_name"; then
        print_warning "VM $vm_name: SSH not ready, skipping"
        return 1
    fi
    
    # Remove default route (ignore errors if route doesn't exist)
    ssh $ssh_options "${lab_infra_admin_username}@${vm_name}" \
        'sudo ip -6 route del default 2>/dev/null' &>/dev/null || true
    
    print_success "VM $vm_name: IPv6 default route removed"
    return 0
}

fn_check_vm_ipv6_route() {
    local vm_name="$1"
    
    if ! fn_vm_is_ssh_ready "$vm_name"; then
        echo "  $vm_name: [SSH not ready]"
        return 1
    fi
    
    local route_check=$(ssh $ssh_options "${lab_infra_admin_username}@${vm_name}" \
        'sudo ip -6 route show default' 2>/dev/null)
    
    if [[ "$route_check" =~ "default" ]]; then
        echo "  $vm_name: $(print_green "[IPv6 default route: ENABLED]")"
    else
        echo "  $vm_name: $(print_yellow "[IPv6 default route: DISABLED]")"
    fi
}

fn_enable_host_ipv6_forwarding() {
    print_task "Enabling IPv6 forwarding on QEMU host..."
    
    # Enable IPv6 forwarding
    sudo sysctl -w net.ipv6.conf.all.forwarding=1 &>/dev/null
    
    # Keep accepting Router Advertisements on primary interface
    local primary_if=$(ip route | awk '/default/ {print $5; exit}')
    if [[ ! -z "${primary_if}" ]]; then
        sudo sysctl -w net.ipv6.conf.${primary_if}.accept_ra=2 &>/dev/null
    fi
    
    # Enable NAT66 for ULA subnet so VMs can reach internet via host's global IPv6
    if [[ ! -z "${lab_infra_server_ipv6_ula_subnet:-}" ]] && [[ ! -z "${primary_if}" ]]; then
        # Add NAT66 masquerading for ULA subnet
        if ! sudo ip6tables -t nat -C POSTROUTING -s ${lab_infra_server_ipv6_ula_subnet} -o ${primary_if} -j MASQUERADE 2>/dev/null; then
            sudo ip6tables -t nat -A POSTROUTING -s ${lab_infra_server_ipv6_ula_subnet} -o ${primary_if} -j MASQUERADE &>/dev/null
        fi
        
        # Add forwarding rules
        if ! sudo ip6tables -C FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; then
            sudo ip6tables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT &>/dev/null
        fi
        
        if ! sudo ip6tables -C FORWARD -i labbr0 -o ${primary_if} -j ACCEPT 2>/dev/null; then
            sudo ip6tables -A FORWARD -i labbr0 -o ${primary_if} -j ACCEPT &>/dev/null
        fi
    fi
    
    print_task_done
}

fn_enable_all() {
    print_notify "Enabling IPv6 default route on all running VMs..."
    echo ""
    
    # First, test if IPv6 internet is available
    if ! fn_test_ipv6_connectivity; then
        echo ""
        print_error "Cannot enable IPv6 default routes: No IPv6 internet connectivity"
        print_info "Routes will not be configured until IPv6 internet is available"
        print_info "Use 'qlabvmctl ipv6-route auto' to auto-configure based on connectivity"
        return 1
    fi
    
    echo ""
    
    # Enable host-level forwarding and NAT
    fn_enable_host_ipv6_forwarding
    echo ""
    
    local vms=$(fn_get_running_vms)
    
    if [[ -z "$vms" ]]; then
        print_warning "No running VMs found"
        return 0
    fi
    
    for vm in $vms; do
        fn_enable_ipv6_route "$vm"
    done
    
    echo ""
    print_success "IPv6 default route configuration complete"
}

fn_disable_all() {
    print_notify "Disabling IPv6 default route on all running VMs..."
    echo ""
    
    local vms=$(fn_get_running_vms)
    
    if [[ -z "$vms" ]]; then
        print_warning "No running VMs found"
        return 0
    fi
    
    for vm in $vms; do
        fn_disable_ipv6_route "$vm"
    done
    
    echo ""
    print_success "IPv6 default route removal complete"
}

fn_auto_configure() {
    print_notify "Auto-configuring IPv6 default routes based on connectivity..."
    echo ""
    
    if fn_test_ipv6_connectivity; then
        echo ""
        print_info "IPv6 internet available → Enabling default routes"
        fn_enable_all
    else
        echo ""
        print_info "No IPv6 internet → Disabling default routes"
        fn_disable_all
    fi
}

fn_show_status() {
    print_notify "IPv6 Configuration Status"
    echo ""
    
    # Test host connectivity
    print_task "QEMU Host IPv6 Internet:" "nskip"
    if ping6 -c 2 -W 3 "$IPV6_TEST_HOST" &>/dev/null; then
        print_green " [AVAILABLE]"
    else
        print_yellow " [NOT AVAILABLE]"
    fi
    
    echo ""
    print_task "VM IPv6 Default Routes:"
    echo ""
    
    local vms=$(fn_get_running_vms)
    
    if [[ -z "$vms" ]]; then
        print_warning "No running VMs found"
        return 0
    fi
    
    for vm in $vms; do
        fn_check_vm_ipv6_route "$vm"
    done
    
    echo ""
    print_info "Note: Local IPv6 subnet (${lab_infra_server_ipv6_ula_subnet}) is always accessible"
}

fn_check_and_report() {
    fn_show_status
    echo ""
    print_notify "Recommendation:"
    
    if ping6 -c 2 -W 3 "$IPV6_TEST_HOST" &>/dev/null; then
        print_info "IPv6 internet is available. Run 'qlabvmctl ipv6-route enable' to enable default routes."
    else
        print_info "No IPv6 internet. Current configuration (routes disabled) is optimal."
    fi
}

# Main execution
if [[ $# -eq 0 ]]; then
    fn_usage
    exit 0
fi

case "${1}" in
    enable)
        fn_enable_all
        ;;
    disable)
        fn_disable_all
        ;;
    auto)
        fn_auto_configure
        ;;
    check)
        fn_check_and_report
        ;;
    status)
        fn_show_status
        ;;
    -h|--help)
        fn_usage
        ;;
    *)
        print_error "Invalid option: $1"
        echo ""
        fn_usage
        exit 1
        ;;
esac
