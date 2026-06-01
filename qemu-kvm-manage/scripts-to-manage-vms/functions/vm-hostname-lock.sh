#!/bin/bash
#----------------------------------------------------------------------------------------#
# Per-hostname singleton lock for VM operations (install, reimage).                      #
# Prevents two processes from operating on the same VM hostname simultaneously.          #
# Different hostnames are fully independent — no contention.                             #
#----------------------------------------------------------------------------------------#

VM_HOSTNAME_LOCK_DIR=""
VM_HOSTNAME_LOCK_ACQUIRED=false

fn_acquire_vm_hostname_lock() {
    local hostname="$1"
    VM_HOSTNAME_LOCK_DIR="/tux2lab-data/.vm-operation-${hostname}.lock"

    if ! mkdir "${VM_HOSTNAME_LOCK_DIR}" 2>/dev/null; then
        if [[ -f "${VM_HOSTNAME_LOCK_DIR}/pid" ]]; then
            local existing_pid
            existing_pid=$(cat "${VM_HOSTNAME_LOCK_DIR}/pid" 2>/dev/null)
            if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
                print_error "Another operation on '${hostname}' is already in progress (PID ${existing_pid})."
                return 1
            fi
            # Stale lock from a dead process — reclaim it
            rm -f "${VM_HOSTNAME_LOCK_DIR}/pid"
            rmdir "${VM_HOSTNAME_LOCK_DIR}" 2>/dev/null || true
        fi
        if ! mkdir "${VM_HOSTNAME_LOCK_DIR}" 2>/dev/null; then
            print_error "Cannot acquire operation lock for '${hostname}'. Please retry."
            return 1
        fi
    fi

    printf '%s\n' "$$" > "${VM_HOSTNAME_LOCK_DIR}/pid"
    VM_HOSTNAME_LOCK_ACQUIRED=true
}

fn_release_vm_hostname_lock() {
    if ! $VM_HOSTNAME_LOCK_ACQUIRED; then
        return
    fi

    local lock_pid=""
    if [[ -f "${VM_HOSTNAME_LOCK_DIR}/pid" ]]; then
        lock_pid=$(cat "${VM_HOSTNAME_LOCK_DIR}/pid" 2>/dev/null)
    fi

    if [[ "${lock_pid}" = "$$" ]]; then
        rm -f "${VM_HOSTNAME_LOCK_DIR}/pid"
        rmdir "${VM_HOSTNAME_LOCK_DIR}" 2>/dev/null || true
    fi

    VM_HOSTNAME_LOCK_ACQUIRED=false
}
