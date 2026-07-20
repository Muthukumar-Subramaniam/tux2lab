# lablink0 management functions
# Provides ensure_lablink0 and remove_lablink0 for bridge carrier management.
# Source this file — do not execute directly.

# Create lablink0 dummy interface to keep the bridge in UP state.
# Idempotent — skips if already exists. Waits for bridge UP + IPv6 DAD.
ensure_lablink0() {
    local bridge_if="${1:-labbr0}"

    if ! ip link show "${bridge_if}" &>/dev/null; then
        print_error "Bridge ${bridge_if} does not exist."
        return 1
    fi

    if ! ip link show lablink0 &>/dev/null; then
        print_task "Creating lablink0 to keep ${bridge_if} UP..."
        sudo ip link add name lablink0 type dummy
        sudo ip link set lablink0 master "${bridge_if}"
        sudo ip link set lablink0 up
        print_task_done
    fi

    # Wait for bridge to reach UP state
    local timeout=10
    local elapsed=0
    while ! ip link show "${bridge_if}" 2>/dev/null | grep -q "state UP"; do
        if ((elapsed >= timeout)); then
            print_error "${bridge_if} did not reach UP state."
            return 1
        fi
        sleep 1
        ((++elapsed))
    done

    # Wait for IPv6 DAD to complete (tentative → permanent)
    elapsed=0
    while ip -6 addr show dev "${bridge_if}" 2>/dev/null | grep -q "tentative"; do
        if ((elapsed >= timeout)); then
            print_warning "IPv6 DAD did not complete within ${timeout}s, proceeding anyway."
            break
        fi
        sleep 1
        ((++elapsed))
    done
}

# Remove lablink0 dummy interface. Idempotent — skips if not present.
remove_lablink0() {
    if ip link show lablink0 &>/dev/null; then
        print_task "Removing lablink0 interface..."
        sudo ip link set lablink0 down 2>/dev/null || true
        sudo ip link del lablink0 2>/dev/null || true
        print_task_done
    fi
}
