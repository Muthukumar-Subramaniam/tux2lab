#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Shared NFS functions for host-side NFS server management.                              #
# NFS runs on the host (not in the container) because the kernel NFS server              #
# cannot serve host-side ISO submounts from inside a container due to mount               #
# namespace isolation.                                                                   #
#----------------------------------------------------------------------------------------#

readonly NFS_EXPORTS_DROPIN="/etc/exports.d/tux2lab.exports"
readonly NFS_CONF_BACKUP="/tux2lab-data/nfs/nfs.conf.original"

# Detect the correct systemd NFS service name
_nfs_service_name() {
    if systemctl list-unit-files nfs-server.service &>/dev/null; then
        echo "nfs-server"
    elif systemctl list-unit-files nfs-kernel-server.service &>/dev/null; then
        echo "nfs-kernel-server"
    else
        echo ""
    fi
}

# Patch /etc/nfs.conf [nfsd] host= to bind to bridge IPs only
_patch_nfs_conf() {
    local nfs_hosts="$1"
    if [[ -f /etc/nfs.conf ]]; then
        # Backup original before first patch
        if [[ ! -f "${NFS_CONF_BACKUP}" ]]; then
            sudo cp /etc/nfs.conf "${NFS_CONF_BACKUP}"
        fi
        if grep -q '^\[nfsd\]' /etc/nfs.conf; then
            # Remove any existing host line (commented or not) under [nfsd]
            sudo sed -i '/^\[nfsd\]/,/^\[/{s/^[# ]*host *=.*//}' /etc/nfs.conf
            # Add host= after [nfsd]
            sudo sed -i "/^\[nfsd\]/a host = ${nfs_hosts}" /etc/nfs.conf
        else
            printf '\n[nfsd]\nhost = %s\n' "${nfs_hosts}" | sudo tee -a /etc/nfs.conf &>/dev/null
        fi
    else
        printf '[nfsd]\nhost = %s\n' "${nfs_hosts}" | sudo tee /etc/nfs.conf &>/dev/null
    fi
}

# Restore original /etc/nfs.conf from backup
_restore_nfs_conf() {
    if [[ -f "${NFS_CONF_BACKUP}" ]]; then
        sudo cp "${NFS_CONF_BACKUP}" /etc/nfs.conf
    fi
}

# Start NFS server on host
# Usage: start_host_nfs <ipv4_address> <ipv6_address>
start_host_nfs() {
    local ipv4="$1" ipv6="$2"
    if [[ ! -f /tux2lab-data/nfs/exports ]]; then return 0; fi

    print_task "Starting NFS server on host..."
    sudo mkdir -p /etc/exports.d
    sudo cp /tux2lab-data/nfs/exports "${NFS_EXPORTS_DROPIN}"
    _patch_nfs_conf "${ipv4},${ipv6}"

    local svc
    svc=$(_nfs_service_name)
    [[ -n "${svc}" ]] && sudo systemctl start "${svc}" 2>/dev/null || true
    sudo exportfs -ra 2>/dev/null || true
    print_task_done
}

# Stop NFS server on host and restore config
stop_host_nfs() {
    # Check if there's anything NFS-related to stop
    local svc
    svc=$(_nfs_service_name)
    local nfs_active=false
    if [[ -n "${svc}" ]] && systemctl is-active "${svc}" &>/dev/null; then
        nfs_active=true
    fi
    if ! $nfs_active && [[ ! -f "${NFS_EXPORTS_DROPIN}" ]] && [[ ! -f "${NFS_CONF_BACKUP}" ]]; then
        print_task "Stopping NFS server on host..."
        print_task_skip
        return 0
    fi

    print_task "Stopping NFS server on host..."
    sudo exportfs -ua 2>/dev/null || true
    sudo rm -f "${NFS_EXPORTS_DROPIN}"
    if $nfs_active; then
        sudo systemctl stop "${svc}" 2>/dev/null || true
    fi
    _restore_nfs_conf
    print_task_done
}

# Restart NFS server on host (after config regeneration)
restart_host_nfs() {
    if [[ ! -f /tux2lab-data/nfs/exports ]]; then return 0; fi

    print_task "Restarting NFS server on host..."
    sudo mkdir -p /etc/exports.d
    sudo cp /tux2lab-data/nfs/exports "${NFS_EXPORTS_DROPIN}"

    local svc
    svc=$(_nfs_service_name)
    [[ -n "${svc}" ]] && sudo systemctl restart "${svc}" 2>/dev/null || true
    sudo exportfs -ra 2>/dev/null || true
    print_task_done
}
