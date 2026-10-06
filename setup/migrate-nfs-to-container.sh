#!/usr/bin/env bash
set -euo pipefail

NFS_MIGRATION_PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$NFS_MIGRATION_PROJECT_ROOT/shared-functions/container-nfs.sh"
source "$NFS_MIGRATION_PROJECT_ROOT/shared-functions/nfs-config.sh"
source "$NFS_MIGRATION_PROJECT_ROOT/shared-functions/run-container.sh"

NFS_MIGRATION_DIR=/var/lib/tux2lab/nfs-migration
NFS_ENGINE=tux2lab-engine
NFS_BACKUP=tux2lab-engine-host-nfs-backup
NFS_DATA=/tux2lab-data
NFS_UNITS=(nfs-server.service nfs-kernel-server.service nfs-mountd.service rpc-mountd.service rpc-statd.service nfs-idmapd.service nfsdcld.service rpcbind.socket rpcbind.service proc-fs-nfsd.mount)

migration_preflight() {
    local image="$1" guests exports label unit exists
    container_nfs_image_check "$image" || return 1
    [[ -f "$NFS_DATA/lab-config/lab_environment.json" ]] || return 1
    exists=$(container_nfs_exists "$NFS_BACKUP") || return 1
    if [[ -e "$NFS_MIGRATION_DIR" || "$exists" == true ]]; then
        printf 'A migration checkpoint already exists. Roll it back or archive it deliberately.\n' >&2
        return 1
    fi
    label=$(sudo podman inspect "$NFS_ENGINE" --format '{{index .Config.Labels "io.tux2lab.nfs"}}') || return 1
    [[ "$label" != container-v1 ]] || { printf 'The engine already uses container NFS.\n' >&2; return 1; }
    guests=$(sudo virsh list --name) || return 1
    [[ -z "$guests" ]] || { printf 'Shut down running guests before migration.\n' >&2; return 1; }
    exports=$(sudo exportfs -s) || return 1
    [[ -n "$exports" ]] || { printf 'No host exports found to migrate.\n' >&2; return 1; }
    if ! awk '$1 != "/tux2lab-data" {exit 1}' <<< "$exports"; then
        printf 'Unrelated host exports exist. This migration requires a dedicated lab NFS server.\n' >&2
        return 1
    fi
    container_nfs_require_no_client_mounts || return 1
    for unit in "${NFS_UNITS[@]}"; do
        if [[ "$(sudo systemctl show "$unit" -p LoadState --value)" == loaded ]] &&
           [[ "$(sudo systemctl show "$unit" -p ActiveState --value)" != active &&
              "$(sudo systemctl show "$unit" -p ActiveState --value)" != inactive ]]; then
            printf 'Resolve the transitional or failed host unit first: %s\n' "$unit" >&2
            return 1
        fi
    done
}

snapshot_host_nfs() {
    local unit canonical active enabled load_state
    local -A seen=()
    mkdir -p "$(dirname "$NFS_MIGRATION_DIR")" || return 1
    mkdir -m 700 "$NFS_MIGRATION_DIR" || return 1
    : > "$NFS_MIGRATION_DIR/units" || return 1
    : > "$NFS_MIGRATION_DIR/aliases" || return 1
    : > "$NFS_MIGRATION_DIR/masked" || return 1
    for unit in "${NFS_UNITS[@]}"; do
        load_state=$(systemctl show "$unit" -p LoadState --value) || return 1
        [[ "$load_state" == loaded ]] || continue
        canonical=$(systemctl show "$unit" -p Id --value) || return 1
        if [[ "$unit" != "$canonical" ]]; then
            printf '%s\n' "$unit" >> "$NFS_MIGRATION_DIR/aliases" || return 1
        fi
        [[ -z "${seen[$canonical]:-}" ]] || continue
        seen[$canonical]=yes
        active=$(systemctl show "$canonical" -p ActiveState --value) || return 1
        [[ "$active" == active || "$active" == inactive ]] || return 1
        enabled=$(systemctl show "$canonical" -p UnitFileState --value) || return 1
        printf '%s\t%s\t%s\n' "$canonical" "$active" "$enabled" >> "$NFS_MIGRATION_DIR/units" || return 1
    done
    exportfs -s > "$NFS_MIGRATION_DIR/exports" || return 1
    sysctl -n fs.nfs.nlm_tcpport > "$NFS_MIGRATION_DIR/lockd-tcp" || return 1
    sysctl -n fs.nfs.nlm_udpport > "$NFS_MIGRATION_DIR/lockd-udp" || return 1
    podman inspect "$NFS_ENGINE" --format '{{.State.Running}}' > "$NFS_MIGRATION_DIR/engine-running" || return 1
    podman inspect "$NFS_ENGINE" --format '{{.Id}}' > "$NFS_MIGRATION_DIR/engine-id" || return 1
    touch "$NFS_MIGRATION_DIR/snapshot-complete" || return 1
}

restore_host_nfs() {
    local unit active enabled status=0 exists
    [[ -f "$NFS_MIGRATION_DIR/snapshot-complete" ]] || return 1
    exists=$(container_nfs_exists "$NFS_BACKUP") || return 1
    if [[ "$exists" == true ]]; then
        [[ "$(sudo podman inspect "$NFS_BACKUP" --format '{{.Id}}')" == "$(cat "$NFS_MIGRATION_DIR/engine-id")" ]] || return 1
        exists=$(container_nfs_exists "$NFS_ENGINE") || return 1
        if [[ "$exists" == true ]]; then
            stop_engine_nfs "$NFS_ENGINE" || return 1
            remove_engine_container "$NFS_ENGINE" || return 1
        fi
        verify_container_nfs_stopped || return 1
        sudo podman rename "$NFS_BACKUP" "$NFS_ENGINE" || return 1
    elif [[ "$(sudo podman inspect "$NFS_ENGINE" --format '{{.Id}}')" != "$(cat "$NFS_MIGRATION_DIR/engine-id")" ]]; then
        printf 'Original engine is missing; refusing host NFS restoration beside an unknown owner.\n' >&2
        return 1
    fi
    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue
        sudo systemctl unmask "$unit" || status=1
    done < "$NFS_MIGRATION_DIR/masked"
    [[ "$status" == 0 ]] || return 1
    sudo sysctl -w "fs.nfs.nlm_tcpport=$(cat "$NFS_MIGRATION_DIR/lockd-tcp")" \
        "fs.nfs.nlm_udpport=$(cat "$NFS_MIGRATION_DIR/lockd-udp")" >/dev/null || return 1
    while IFS=$'\t' read -r unit active enabled; do
        if [[ "$unit" == rpcbind.service && "$active" == active ]]; then
            sudo systemctl start "$unit" || return 1
        fi
    done < "$NFS_MIGRATION_DIR/units"
    while IFS=$'\t' read -r unit active enabled; do
        if [[ "$active" == active ]]; then
            sudo systemctl start "$unit" || status=1
        fi
    done < "$NFS_MIGRATION_DIR/units"
    while IFS=$'\t' read -r unit active enabled; do
        if [[ "$active" == inactive ]]; then
            sudo systemctl stop "$unit" || status=1
        fi
    done < "$NFS_MIGRATION_DIR/units"
    sudo exportfs -ra || return 1
    while IFS=$'\t' read -r unit active enabled; do
        [[ "$(sudo systemctl show "$unit" -p ActiveState --value)" == "$active" ]] || status=1
        [[ "$(sudo systemctl show "$unit" -p UnitFileState --value)" == "$enabled" ]] || status=1
    done < "$NFS_MIGRATION_DIR/units"
    sudo exportfs -s | cmp -s "$NFS_MIGRATION_DIR/exports" - || status=1
    if [[ "$(cat "$NFS_MIGRATION_DIR/engine-running")" == true ]]; then
        sudo podman start "$NFS_ENGINE" || status=1
    fi
    [[ "$status" == 0 ]] || return 1
    mv "$NFS_MIGRATION_DIR" "${NFS_MIGRATION_DIR}-restored-$(date -u +%Y%m%dT%H%M%SZ)" || return 1
    printf 'Host NFS and the previous engine restored. Use main for legacy lifecycle commands.\n'
}

apply_nfs_migration() {
    local image="$1" unit active enabled ipv4 ipv6 ipv4_network ipv6_network bridge hostname domain
    migration_preflight "$image" || return 1
    ipv4=$(jq -er '.network.ipv4.address' "$NFS_DATA/lab-config/lab_environment.json") || return 1
    ipv6=$(jq -r '.network.ipv6.address // empty' "$NFS_DATA/lab-config/lab_environment.json") || return 1
    ipv4_network=$(jq -er '.network.ipv4 | .network + "/" + (.prefix|tostring)' "$NFS_DATA/lab-config/lab_environment.json") || return 1
    ipv6_network=$(jq -r '.network.ipv6.ula_subnet // empty' "$NFS_DATA/lab-config/lab_environment.json") || return 1
    bridge=$(jq -er '.network.bridge_interface' "$NFS_DATA/lab-config/lab_environment.json") || return 1
    hostname=$(jq -er '.lab.engine_fqdn' "$NFS_DATA/lab-config/lab_environment.json") || return 1
    domain=$(jq -er '.lab.domain' "$NFS_DATA/lab-config/lab_environment.json") || return 1
    mkdir -p "$NFS_DATA/nfs"
    write_container_nfs_exports "$NFS_DATA" "$ipv4_network" "$ipv6_network" "$domain" > "$NFS_DATA/nfs/container.exports" || return 1
    write_container_nfs_conf "$ipv4" "$ipv6" > "$NFS_DATA/nfs/container.conf" || return 1
    prepare_container_nfs "$NFS_DATA" || return 1
    snapshot_host_nfs || return 1
    trap 'migration_exit $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    trap 'exit 131' QUIT
    while IFS=$'\t' read -r unit active enabled; do
        [[ "$unit" != *.mount ]] || continue
        printf '%s\n' "$unit" >> "$NFS_MIGRATION_DIR/masked" || return 1
        systemctl mask "$unit" || return 1
    done < "$NFS_MIGRATION_DIR/units"
    while IFS= read -r unit; do
        printf '%s\n' "$unit" >> "$NFS_MIGRATION_DIR/masked" || return 1
        systemctl mask "$unit" || return 1
    done < "$NFS_MIGRATION_DIR/aliases"
    while IFS=$'\t' read -r unit active enabled; do
        if ! systemctl stop "$unit"; then
            [[ "$(systemctl show "$unit" -p ActiveState --value)" != active ]] || return 1
            [[ "$(systemctl show "$unit" -p MainPID --value)" == 0 ]] || return 1
        fi
    done < "$NFS_MIGRATION_DIR/units"
    verify_container_nfs_stopped || return 1
    podman stop --time 30 "$NFS_ENGINE" || return 1
    podman rename "$NFS_ENGINE" "$NFS_BACKUP" || return 1
    run_tux2lab_container "$NFS_ENGINE" "$image" "$hostname" "$NFS_DATA" "$ipv4" "$bridge" || return 1
    touch "$NFS_MIGRATION_DIR/committed" || return 1
    trap - EXIT INT TERM HUP QUIT
    printf 'Container NFS is ready. Previous engine and host service checkpoint retained for rollback.\n'
}

migration_exit() {
    local status="$1"
    trap - EXIT INT TERM HUP QUIT
    if ! restore_host_nfs; then
        printf 'Automatic rollback incomplete. Keep filesystems mounted and inspect %s.\n' "$NFS_MIGRATION_DIR" >&2
    fi
    exit "$status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --help|-h)
            printf 'Usage: sudo bash setup/migrate-nfs-to-container.sh --check IMAGE | --apply IMAGE | --rollback\n'
            exit 0 ;;
        --check|--apply) [[ $# == 2 ]] || exit 2 ;;
        --rollback) [[ $# == 1 ]] || exit 2 ;;
        *) printf 'Use --help for migration usage.\n' >&2; exit 2 ;;
    esac
    [[ "$EUID" == 0 ]] || { printf 'Run this migration command with sudo.\n' >&2; exit 1; }
    mkdir -p /run/lock
    exec 9>/run/lock/tux2lab-nfs-migration.lock
    flock -n 9 || { printf 'Another NFS migration is running.\n' >&2; exit 1; }
    (
        case "$1" in
            --check) migration_preflight "$2" ;;
            --apply) apply_nfs_migration "$2" ;;
            --rollback) restore_host_nfs ;;
        esac
    ) 9>&-
fi