#!/bin/bash
#----------------------------------------------------------------------------------------#
# MAC Address Generation Functions for QEMU/KVM VMs                                     #
#----------------------------------------------------------------------------------------#

[[ -z "${MAC_GEN_LOCK_DIR:-}" ]] && readonly MAC_GEN_LOCK_DIR="/tux2lab-data/.mac-generation.lock"
MAC_GEN_LOCK_ACQUIRED=false

fn_acquire_mac_gen_lock() {
    local retries=200
    local existing_pid=""

    while ! mkdir "${MAC_GEN_LOCK_DIR}" 2>/dev/null; do
        if [[ -f "${MAC_GEN_LOCK_DIR}/pid" ]]; then
            existing_pid=$(cat "${MAC_GEN_LOCK_DIR}/pid" 2>/dev/null)
            if [[ -n "${existing_pid}" ]] && ! kill -0 "${existing_pid}" 2>/dev/null; then
                rm -f "${MAC_GEN_LOCK_DIR}/pid"
                rmdir "${MAC_GEN_LOCK_DIR}" 2>/dev/null || true
                continue
            fi
        fi

        sleep 0.05
        retries=$((retries - 1))
        if [[ "${retries}" -le 0 ]]; then
            print_error "Unable to acquire MAC generation lock. Please retry."
            return 1
        fi
    done

    printf '%s\n' "$$" > "${MAC_GEN_LOCK_DIR}/pid"
    MAC_GEN_LOCK_ACQUIRED=true
}

fn_release_mac_gen_lock() {
    if ! $MAC_GEN_LOCK_ACQUIRED; then
        return
    fi

    local lock_pid=""
    if [[ -f "${MAC_GEN_LOCK_DIR}/pid" ]]; then
        lock_pid=$(cat "${MAC_GEN_LOCK_DIR}/pid" 2>/dev/null)
    fi

    if [[ "${lock_pid}" = "$$" ]]; then
        rm -f "${MAC_GEN_LOCK_DIR}/pid"
        rmdir "${MAC_GEN_LOCK_DIR}" 2>/dev/null || true
    fi

    MAC_GEN_LOCK_ACQUIRED=false
}

# Function to generate a random MAC address for QEMU/KVM VMs
generate_mac() {
    # Use 52:54:00 prefix (QEMU/KVM range) followed by 3 random octets
    local mac="52:54:00:$(openssl rand -hex 3 | sed 's/../&:/g; s/:$//')"
    echo "$mac"
}

# Function to check if MAC is unique across all VMs
is_mac_unique() {
    local mac="$1"
    for used_mac in "${USED_MACS[@]}"; do
        if [[ "$mac" == "$used_mac" ]]; then
            return 1
        fi
    done
    return 0
}

# Function to collect all MAC addresses currently in use across all VMs
collect_used_macs() {
    USED_MACS=()
    # Extract all MAC addresses in a single grep across libvirt VM definitions,
    # avoiding the slow per-VM 'virsh domiflist' loop.
    local mac
    while IFS= read -r mac; do
        [[ -n "$mac" ]] && USED_MACS+=("$mac")
    done < <(sudo grep -roh "52:54:00:[0-9a-f:]\{8\}" /etc/libvirt/qemu/ 2>/dev/null | sort -u)
}

# Main function to generate a unique MAC address for a VM
generate_unique_mac() {
    local hostname="$1"
    local max_attempts=100
    local attempt=0
    local mac

    # Acquire lock to prevent TOCTOU race between concurrent installs
    if ! fn_acquire_mac_gen_lock; then
        return 1
    fi

    # Collect all currently used MACs
    collect_used_macs

    # Try to generate a unique MAC
    while (( attempt < max_attempts )); do
        mac=$(generate_mac)
        if is_mac_unique "$mac"; then
            fn_release_mac_gen_lock
            echo "$mac"
            return 0
        fi
        ((++attempt))
    done

    fn_release_mac_gen_lock
    print_error "Failed to generate unique MAC address for VM \"${hostname}\" after ${max_attempts} attempts."
    return 1
}
