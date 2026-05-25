#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: start.sh                                                             #
# Description: Start the tux2lab infrastructure and verify essential services            #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh

# ====== HELP ======
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_cyan "USAGE:
    tux2lab start

DESCRIPTION:
    Starts the tux2lab infrastructure, including libvirtd, the virtual
    network, and the lab infra server (VM or host services).
    Verifies all essential services are reachable after startup."
    exit 0
fi

if [[ $# -gt 0 ]]; then
    print_error "Unknown argument: $1"
    echo "Run 'tux2lab start --help' for usage information."
    exit 1
fi

# ====== GLOBAL CONFIGURATION ======
lab_bridge_interface_name="labbr0"

# ====== DNS CONFIGURATION FUNCTION ======
configure_dns_for_bridge() {
    print_task "Configuring DNS for $lab_bridge_interface_name..."
    sudo resolvectl dns "$lab_bridge_interface_name" "$lab_infra_server_ipv4_address" "$lab_infra_server_ipv6_address" || print_warning "Could not set DNS server"
    sudo resolvectl domain "$lab_bridge_interface_name" "$lab_infra_domain_name" || print_warning "Could not set DNS domain"
    print_task_done
}

when_lab_infra_server_is_host() {
    # ====== CONFIGURATION ======
    local lab_bridge_dummy_interface_name="dummy-vnet"
    local lab_essential_services=("kea-ctrl-agent" "kea-dhcp4" "kea-dhcp6" "radvd" "nfs-server" "tftp.socket" "nginx")
    
    # ====== CLEANUP ON EXIT ======
    trap 'print_error "Script interrupted!"' SIGINT

    # ====== STEP 1: Check and start libvirtd if needed ======
    if sudo systemctl is-active --quiet libvirtd; then
        print_info "libvirtd is already running"
    else
        print_task "Starting libvirtd..."
        if ! sudo systemctl restart libvirtd; then
            print_task_fail
            print_error "Failed to start libvirtd"
            return 1
        fi
        print_task_done
    fi
    
    # ====== STEP 2: Wait for labbr0 (autostart or manual net-start) ======
    print_task "Waiting for $lab_bridge_interface_name to be created..."
    local bridge_creation_timeout_seconds=30
    local bridge_creation_elapsed_seconds=0
    local net_start_attempted=false
    until ip link show "$lab_bridge_interface_name" &>/dev/null; do
        if [[ $bridge_creation_elapsed_seconds -ge $bridge_creation_timeout_seconds ]]; then
            print_task_fail
            print_error "Timeout waiting for $lab_bridge_interface_name"
            return 1
        fi
        # If bridge hasn't appeared after 5s, try starting the network manually
        if [[ $bridge_creation_elapsed_seconds -ge 5 ]] && ! $net_start_attempted; then
            sudo virsh net-start tux2lab &>/dev/null || true
            net_start_attempted=true
        fi
        sleep 1
        bridge_creation_elapsed_seconds=$((bridge_creation_elapsed_seconds + 1))
    done
    print_task_done
    
    # ====== STEP 3: Create dummy link if missing ======
    if ! ip link show "$lab_bridge_dummy_interface_name" &>/dev/null; then
        print_task "Creating dummy interface $lab_bridge_dummy_interface_name to keep $lab_bridge_interface_name always up..."
        sudo ip link add name "$lab_bridge_dummy_interface_name" type dummy || { print_task_fail; print_error "Failed to create dummy interface"; return 1; }
        sudo ip link set "$lab_bridge_dummy_interface_name" master "$lab_bridge_interface_name" || { print_task_fail; print_error "Failed to attach dummy to bridge"; return 1; }
        sudo ip link set "$lab_bridge_dummy_interface_name" up || { print_task_fail; print_error "Failed to bring up dummy interface"; return 1; }
        print_task_done
    else
        print_info "Dummy interface $lab_bridge_dummy_interface_name already exists."
    fi
    
    # ====== STEP 4: Wait for labbr0 to come up ======
    print_task "Waiting for $lab_bridge_interface_name to come UP..."
    local bridge_up_timeout_seconds=30
    local bridge_up_elapsed_seconds=0
    while ! ip link show "$lab_bridge_interface_name" 2>/dev/null | grep -q 'state UP'; do
        if [[ $bridge_up_elapsed_seconds -ge $bridge_up_timeout_seconds ]]; then
            print_task_fail
            print_error "Timeout waiting for $lab_bridge_interface_name to come up"
            return 1
        fi
        sleep 1
        bridge_up_elapsed_seconds=$((bridge_up_elapsed_seconds + 1))
    done
    print_task_done
    
    # ====== STEP 5: Assign IP addresses (dual-stack) ======
    local lab_infra_server_ipv4_cidr_prefix
    lab_infra_server_ipv4_cidr_prefix=$(awk -F. '{for(i=1;i<=4;i++){n=$i+0; while(n){c+=n%2; n=int(n/2)}}} END{print c+0}' <<< "${lab_infra_server_ipv4_netmask}")

    print_task "Configuring IPv4 ${lab_infra_server_ipv4_address}/${lab_infra_server_ipv4_cidr_prefix} on $lab_bridge_interface_name..."
    if sudo ip addr add "${lab_infra_server_ipv4_address}/${lab_infra_server_ipv4_cidr_prefix}" dev "$lab_bridge_interface_name" 2>/dev/null; then
        print_task_done
    else
        print_task_done
        print_info "IPv4 address may already be assigned"
    fi

    print_task "Configuring IPv6 ${lab_infra_server_ipv6_address}/${lab_infra_server_ipv6_prefix} on $lab_bridge_interface_name..."
    if sudo ip addr add "${lab_infra_server_ipv6_address}/${lab_infra_server_ipv6_prefix}" dev "$lab_bridge_interface_name" 2>/dev/null; then
        print_task_done
    else
        print_task_done
        print_info "IPv6 address may already be assigned"
    fi

    # ====== STEP 5.1: Wait for IPv6 DAD to complete ======
    print_task "Waiting for IPv6 address to complete DAD..."
    local dad_timeout=10
    local dad_elapsed=0
    while [[ $dad_elapsed -lt $dad_timeout ]]; do
        if ip -6 addr show dev "$lab_bridge_interface_name" | grep -q "${lab_infra_server_ipv6_address}.*scope global" && \
           ! ip -6 addr show dev "$lab_bridge_interface_name" | grep -q "${lab_infra_server_ipv6_address}.*tentative"; then
            break
        fi
        sleep 1
        ((++dad_elapsed))
    done
    if [[ $dad_elapsed -ge $dad_timeout ]]; then
        print_task_fail
        print_warning "IPv6 DAD may not have completed, but continuing..."
    else
        print_task_done
    fi

    # ====== STEP 6: Restart named service ======
    print_task "Restarting named service..."
    if ! sudo systemctl restart named; then
        print_task_fail
        print_error "Failed to restart named service"
        return 1
    fi
    print_task_done
    
    # ====== STEP 7: Restart dependent services sequentially ======
    print_info "Restarting dependent lab services sequentially..."
    local failed_services_list=()
    for service_name in "${lab_essential_services[@]}"; do
        print_task "Restarting $service_name..."
        if sudo systemctl restart "$service_name" 2>/dev/null; then
            print_task_done
        else
            print_task_fail
            failed_services_list+=("$service_name")
        fi
    done
    
    if [[ ${#failed_services_list[@]} -eq 0 ]]; then
        print_success "All lab services restarted successfully."
    else
        print_warning "Some services failed: ${failed_services_list[*]}"
    fi
    
    # ====== STEP 8: Verify critical services ======
    print_info "Verifying critical services..."
    local all_services_active=true
    for service_name in libvirtd named "${lab_essential_services[@]}"; do
        if sudo systemctl is-active --quiet "$service_name"; then
            print_success "  $service_name is active."
        else
            print_error "  $service_name is not active"
            all_services_active=false
        fi
    done

    # ====== STEP 9: Configure DNS for labbr0 ======
    configure_dns_for_bridge || return 1

    if $all_services_active; then
        print_success "tux2lab Infra is started, and all essential services are live."
    else
        print_warning "tux2lab Infra is started, but some services need attention."
        print_info "Run 'sudo systemctl status <service>' for details."
    fi
}

when_lab_infra_server_is_vm() {
    # ====== CLEANUP ON EXIT ======
    trap 'print_error "Script interrupted!"' SIGINT

    # ====== STEP 1: Check and start libvirtd if needed ======
    if sudo systemctl is-active --quiet libvirtd; then
        print_info "libvirtd is already running"
    else
        print_task "Starting libvirtd..."
        if ! sudo systemctl restart libvirtd; then
            print_task_fail
            print_error "Failed to start libvirtd"
            return 1
        fi
        print_task_done
    fi
    # ====== STEP 2: Wait for labbr0 (autostart or manual net-start) ======
    print_task "Waiting for $lab_bridge_interface_name to be created..."
    local bridge_creation_timeout_seconds=30
    local bridge_creation_elapsed_seconds=0
    local net_start_attempted=false
    until ip link show "$lab_bridge_interface_name" &>/dev/null; do
        if [[ $bridge_creation_elapsed_seconds -ge $bridge_creation_timeout_seconds ]]; then
            print_task_fail
            print_error "Timeout waiting for $lab_bridge_interface_name"
            return 1
        fi
        # If bridge hasn't appeared after 5s, try starting the network manually
        if [[ $bridge_creation_elapsed_seconds -ge 5 ]] && ! $net_start_attempted; then
            sudo virsh net-start tux2lab &>/dev/null || true
            net_start_attempted=true
        fi
        sleep 1
        bridge_creation_elapsed_seconds=$((bridge_creation_elapsed_seconds + 1))
    done
    print_task_done
    # ====== STEP 3: Check and start lab infra server VM ======
    print_task "Checking lab infra server VM status..."
    if sudo virsh list --state-running | awk '{print $2}' | grep -Fxq "$lab_infra_server_hostname"; then
        print_task_done
        print_info "VM is already running"
    else
        print_task_done
        print_task "Starting VM..."
        if sudo virsh start "$lab_infra_server_hostname" >/dev/null 2>&1; then
            print_task_done
        else
            print_task_fail
            print_error "Failed to start lab infra server VM"
            return 1
        fi
    fi

    # ====== STEP 4: Wait for lab infra server VM to be SSH accessible ======
    print_task "Waiting for VM to become SSH accessible..."
    local ssh_check_timeout=120
    local ssh_check_elapsed=0
    local ssh_check_interval=5
    local vm_is_ssh_accessible=false
    
    local ssh_connection_options=(
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=QUIET
        -o ConnectTimeout=5
        -o ConnectionAttempts=1
        -o ServerAliveInterval=5
        -o PreferredAuthentications=publickey
        -o ServerAliveCountMax=1
    )
    
    while [[ $ssh_check_elapsed -lt $ssh_check_timeout ]]; do
        local sys_state
        sys_state=$(ssh "${ssh_connection_options[@]}" "${lab_infra_admin_username}@${lab_infra_server_hostname}" \
           'systemctl is-system-running 2>/dev/null || true' 2>/dev/null </dev/null) || true
        if [[ "$sys_state" == "running" || "$sys_state" == "degraded" ]]; then
            vm_is_ssh_accessible=true
            break
        fi
        sleep "$ssh_check_interval"
        ssh_check_elapsed=$((ssh_check_elapsed + ssh_check_interval))
        echo -n "."
    done
    
    if [[ "$vm_is_ssh_accessible" != "true" ]]; then
        print_task_fail
        print_error "VM did not become SSH accessible within ${ssh_check_timeout} seconds"
        return 1
    fi
    print_task_done
    # ====== STEP 5: Configure DNS for labbr0 ======
    configure_dns_for_bridge || return 1

    print_cyan "--------------------------------------------------------------"
    print_success "tux2lab Infra is started."
    print_info "Run 'tux2lab health' for full deep validation."
}
    
# ====== MAIN LOGIC ======

print_cyan "--------------------------------------------------------------"
print_cyan "tux2lab Infrastructure Startup"
print_cyan "--------------------------------------------------------------"

if $lab_infra_server_mode_is_host; then
    print_notify "Lab Infra Server Mode: HOST ( $lab_infra_server_hostname )"
    print_cyan "--------------------------------------------------------------"
    when_lab_infra_server_is_host || exit_code=$?
else
    print_notify "Lab Infra Server Mode: VM ( $lab_infra_server_hostname )"
    print_cyan "--------------------------------------------------------------"
    when_lab_infra_server_is_vm || exit_code=$?
fi

print_cyan "--------------------------------------------------------------"
exit "${exit_code:-0}"
