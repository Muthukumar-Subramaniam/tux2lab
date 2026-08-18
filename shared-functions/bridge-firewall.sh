#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Shared firewall functions for lab bridge.                                              #
# Ensures traffic is allowed on the lab bridge interface.                                #
# Supports firewalld (Fedora/RHEL) and raw iptables (other distros).                    #
#----------------------------------------------------------------------------------------#

# Add the bridge to firewalld trusted zone, or add iptables ACCEPT rules (idempotent)
# Usage: open_bridge_firewall <bridge_interface>
open_bridge_firewall() {
    local bridge="$1"

    # firewalld takes priority if running
    if systemctl is-active firewalld &>/dev/null; then
        print_task "Opening firewall for ${bridge}..."
        if sudo firewall-cmd --zone=trusted --query-interface="${bridge}" &>/dev/null; then
            print_task_skip
            return 0
        fi
        if sudo firewall-cmd --zone=trusted --change-interface="${bridge}" --permanent &>/dev/null && \
           sudo firewall-cmd --zone=trusted --change-interface="${bridge}" &>/dev/null; then
            print_task_done
        else
            print_task_fail
            print_warning "Could not add ${bridge} to firewalld trusted zone."
        fi
        return 0
    fi

    # No iptables available (e.g. openSUSE with pure nftables) — nothing to configure
    if ! command -v iptables &>/dev/null; then
        print_task "Opening firewall for ${bridge}..."
        print_task_skip
        return 0
    fi

    # Fallback: raw iptables/ip6tables
    local rules_needed=false

    if sudo iptables -S INPUT 2>/dev/null | head -1 | grep -q "DROP\|REJECT" || \
       sudo ip6tables -S INPUT 2>/dev/null | head -1 | grep -q "DROP\|REJECT"; then
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

    if sudo iptables -C INPUT -i "${bridge}" -j ACCEPT 2>/dev/null || \
       sudo ip6tables -C INPUT -i "${bridge}" -j ACCEPT 2>/dev/null; then
        print_task_done
    else
        print_task_fail
        print_warning "Could not apply firewall rules for ${bridge}. VMs may not be able to reach lab services."
    fi
}

# Remove bridge from firewalld trusted zone / iptables rules
# Usage: close_bridge_firewall <bridge_interface>
close_bridge_firewall() {
    local bridge="$1"

    if systemctl is-active firewalld &>/dev/null; then
        print_task "Removing ${bridge} from firewalld trusted zone..."
        if sudo firewall-cmd --zone=trusted --query-interface="${bridge}" &>/dev/null; then
            sudo firewall-cmd --zone=trusted --remove-interface="${bridge}" --permanent &>/dev/null
            sudo firewall-cmd --zone=trusted --remove-interface="${bridge}" &>/dev/null
            print_task_done
        else
            print_task_skip
        fi
        return 0
    fi

    # No iptables available (e.g. openSUSE with pure nftables) — nothing to remove
    if ! command -v iptables &>/dev/null; then
        print_task "Removing firewall rules for ${bridge}..."
        print_task_skip
        return 0
    fi

    print_task "Removing firewall rules for ${bridge}..."
    local removed=false
    for rule in \
        "INPUT -i ${bridge} -j ACCEPT" \
        "FORWARD -i ${bridge} -j ACCEPT" \
        "FORWARD -o ${bridge} -j ACCEPT" \
        "OUTPUT -o ${bridge} -j ACCEPT"; do
        if sudo iptables -D $rule 2>/dev/null; then removed=true; fi
        if sudo ip6tables -D $rule 2>/dev/null; then removed=true; fi
    done
    if $removed; then
        print_task_done
    else
        print_task_skip
    fi
}

# Check if bridge firewall rules are in place (for health check)
# Usage: check_bridge_firewall <bridge_interface>
# Returns 0 if rules present or policy is ACCEPT, 1 if missing
check_bridge_firewall() {
    local bridge="$1"

    # firewalld: check if bridge is in trusted zone
    if systemctl is-active firewalld &>/dev/null; then
        sudo firewall-cmd --zone=trusted --query-interface="${bridge}" &>/dev/null && return 0
        return 1
    fi

    # No iptables available (e.g. openSUSE with pure nftables) — no host firewall blocking
    if ! command -v iptables &>/dev/null; then
        return 0
    fi

    # iptables: if INPUT policy is not DROP/REJECT, traffic is allowed (mirrors open_bridge_firewall)
    if ! sudo iptables -S INPUT 2>/dev/null | head -1 | grep -q "DROP\|REJECT"; then
        return 0
    fi

    # Restrictive policy — require explicit ACCEPT rules on the bridge
    if sudo iptables -C INPUT -i "${bridge}" -j ACCEPT 2>/dev/null && \
       sudo ip6tables -C INPUT -i "${bridge}" -j ACCEPT 2>/dev/null; then
        return 0
    fi

    return 1
}
