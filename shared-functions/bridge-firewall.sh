#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Shared firewall functions for lab bridge.                                              #
# Ensures traffic is allowed on the lab bridge interface.                                #
# Supports firewalld (Fedora/RHEL) and raw iptables (other distros).                    #
#----------------------------------------------------------------------------------------#

write_bridge_network_xml() {
    python3 - "$@" <<'BRIDGE_XML'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

source, name, interface, zone, live = sys.argv[1:]
if zone not in ("", "trusted"):
    raise SystemExit("Unsupported managed bridge zone")

def parse_network(data):
    network = ET.fromstring(data)
    bridges = network.findall("bridge")
    if (network.tag != "network" or network.findtext("name") != name
            or len(bridges) != 1 or bridges[0].get("name") != interface):
        raise SystemExit("Network name or bridge does not match the requested lab")
    if bridges[0].get("zone") not in (None, "trusted"):
        raise SystemExit("Refusing to overwrite a custom libvirt bridge zone")
    return network, bridges[0]

original = Path(source).read_bytes()
network, bridge = parse_network(original)
needs_restart = False
if live:
    _, live_bridge = parse_network(Path(live).read_bytes())
    needs_restart = bool(zone and live_bridge.get("zone") != zone)
if bridge.get("zone") == (zone or None):
    sys.stdout.buffer.write(original)
else:
    if zone:
        bridge.set("zone", zone)
    else:
        bridge.attrib.pop("zone", None)
    sys.stdout.buffer.write(ET.tostring(network, encoding="utf-8"))
sys.exit(3 if needs_restart else 0)
BRIDGE_XML
}

ensure_bridge_network() (
    local name="$1" bridge="$2" definition="$3" state zone networks scratch xml live=''
    local exists=false running=false comparison=0 transform_status=0
    state=$(systemctl show firewalld.service -p ActiveState --value) || return 1
    case "$state" in
        active) zone=trusted ;;
        inactive|failed) zone='' ;;
        *) printf 'Cannot configure the lab network while firewalld state is %s.\n' "$state" >&2; return 1 ;;
    esac
    networks=$(sudo virsh net-list --all --name) || return 1
    scratch=$(mktemp -d) || return 1
    trap 'rm -rf -- "$scratch"' EXIT
    if grep -Fxq -- "$name" <<< "$networks"; then
        exists=true
        networks=$(sudo virsh net-list --all --persistent --name) || return 1
        if ! grep -Fxq -- "$name" <<< "$networks"; then
            printf 'Refusing to replace transient network %s.\n' "$name" >&2
            return 1
        fi
        xml=$(sudo virsh net-dumpxml "$name" --inactive) || return 1
        printf '%s\n' "$xml" > "$scratch/original.xml" || return 1
        networks=$(sudo virsh net-list --name) || return 1
        if grep -Fxq -- "$name" <<< "$networks"; then
            running=true
            live="$scratch/live.xml"
            xml=$(sudo virsh net-dumpxml "$name") || return 1
            printf '%s\n' "$xml" > "$live" || return 1
        fi
    else
        cp -- "$definition" "$scratch/original.xml" || return 1
    fi
    write_bridge_network_xml "$scratch/original.xml" "$name" "$bridge" "$zone" "$live" \
        > "$scratch/network.xml" || transform_status=$?
    [[ "$transform_status" == 0 || "$transform_status" == 3 ]] || return 1
    cmp -s "$scratch/original.xml" "$scratch/network.xml" || comparison=$?
    [[ "$comparison" == 0 || "$comparison" == 1 ]] || return 1
    if ! "$exists" || [[ "$comparison" == 1 ]]; then
        sudo virsh net-define "$scratch/network.xml" --validate >/dev/null || return 1
    fi
    if [[ "$transform_status" == 3 ]]; then
        printf 'Persistent trusted zone prepared for %s; live network unchanged. Stop/start the lab in a maintenance window, then retry.\n' "$name" >&2
        return 1
    fi
    if ! "$running"; then
        sudo virsh net-start "$name" >/dev/null || return 1
    fi
    sudo virsh net-autostart "$name" >/dev/null || return 1
)

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
