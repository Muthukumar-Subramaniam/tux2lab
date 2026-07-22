#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Shared firewall functions for lab bridge.                                              #
# Ensures iptables/ip6tables allow traffic on the lab bridge interface.                  #
# Only adds rules if the default policy is DROP/REJECT (restrictive firewall).           #
#----------------------------------------------------------------------------------------#

# Add ACCEPT rules for the lab bridge interface (idempotent)
# Usage: open_bridge_firewall <bridge_interface>
open_bridge_firewall() {
    local bridge="$1"
    local rules_needed=false

    # Check if restrictive policy exists (IPv4 or IPv6)
    if sudo iptables -S INPUT 2>/dev/null | head -1 | grep -q "DROP\|REJECT" || \
       sudo ip6tables -S INPUT 2>/dev/null | head -1 | grep -q "DROP\|REJECT"; then
        # Check if rules already present
        if sudo iptables -C INPUT -i "${bridge}" -j ACCEPT 2>/dev/null && \
           sudo ip6tables -C INPUT -i "${bridge}" -j ACCEPT 2>/dev/null; then
            print_task "Opening firewall for ${bridge}..."
            print_task_skip
            return 0
        fi
        rules_needed=true
    fi

    if ! $rules_needed; then
        print_task "Opening firewall for ${bridge}..."
        print_task_skip
        return 0
    fi

    print_task "Opening firewall for ${bridge}..."

    # IPv4: only if INPUT policy is not ACCEPT
    if sudo iptables -S INPUT 2>/dev/null | head -1 | grep -q "DROP\|REJECT"; then
        for rule in \
            "INPUT -i ${bridge} -j ACCEPT" \
            "FORWARD -i ${bridge} -j ACCEPT" \
            "FORWARD -o ${bridge} -j ACCEPT" \
            "OUTPUT -o ${bridge} -j ACCEPT"; do
            if ! sudo iptables -C $rule 2>/dev/null; then
                sudo iptables -I $rule 2>/dev/null || true
            fi
        done
    fi

    # IPv6: only if INPUT policy is not ACCEPT
    if sudo ip6tables -S INPUT 2>/dev/null | head -1 | grep -q "DROP\|REJECT"; then
        for rule in \
            "INPUT -i ${bridge} -j ACCEPT" \
            "FORWARD -i ${bridge} -j ACCEPT" \
            "FORWARD -o ${bridge} -j ACCEPT" \
            "OUTPUT -o ${bridge} -j ACCEPT"; do
            if ! sudo ip6tables -C $rule 2>/dev/null; then
                sudo ip6tables -I $rule 2>/dev/null || true
            fi
        done
    fi

    # Verify rules were applied
    if sudo iptables -C INPUT -i "${bridge}" -j ACCEPT 2>/dev/null || \
       sudo ip6tables -C INPUT -i "${bridge}" -j ACCEPT 2>/dev/null; then
        print_task_done
    else
        print_task_fail
        print_warning "Could not apply firewall rules for ${bridge}. VMs may not be able to reach lab services."
    fi
}

# Check if bridge firewall rules are in place (for health check)
# Usage: check_bridge_firewall <bridge_interface>
# Returns 0 if rules present or policy is ACCEPT, 1 if missing
check_bridge_firewall() {
    local bridge="$1"

    # If policy is ACCEPT, no rules needed
    if sudo iptables -S INPUT 2>/dev/null | head -1 | grep -q "\-P INPUT ACCEPT"; then
        return 0
    fi

    # Check if our rules exist
    if sudo iptables -C INPUT -i "${bridge}" -j ACCEPT 2>/dev/null && \
       sudo ip6tables -C INPUT -i "${bridge}" -j ACCEPT 2>/dev/null; then
        return 0
    fi

    return 1
}
