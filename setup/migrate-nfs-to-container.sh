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
NFS_HOST_EXPORTS=/etc/exports
NFS_HOST_EXPORTS_DIR=/etc/exports.d
NFS_UNITS=(nfs-server.service nfs-kernel-server.service nfs-mountd.service rpc-mountd.service rpc-statd.service nfs-idmapd.service nfsdcld.service rpcbind.socket rpcbind.service proc-fs-nfsd.mount)

prepare_fresh_host_nfs() {
    local containers guests exports unit load_state active_state registrations
    local rpc_active=false
    local -a units=()
    if [[ -e "$NFS_DATA/lab-config/lab_environment.json" || -L "$NFS_DATA/lab-config/lab_environment.json" ||
          -e "$NFS_MIGRATION_DIR" || -L "$NFS_MIGRATION_DIR" ]]; then
        printf 'Existing lab or migration state: use rebuild or resolve the migration first.\n' >&2
        return 1
    fi
    containers=$(sudo podman ps -aq) || return 1
    guests=$(sudo virsh list --all --name) || return 1
    [[ -z "$containers" && -z "$guests" ]] || {
        printf 'Fresh NFS preparation requires no containers or defined VMs.\n' >&2
        return 1
    }
    container_nfs_require_no_client_mounts || return 1
    exports=$(sudo exportfs -s) || return 1
    [[ -z "$exports" ]] || { printf 'Active host exports prevent fresh NFS preparation.\n' >&2; return 1; }
    if [[ -e "$NFS_HOST_EXPORTS" || -L "$NFS_HOST_EXPORTS" ]]; then
        awk 'NF && $1 !~ /^#/ {exit 1}' "$NFS_HOST_EXPORTS" || {
            printf 'Configured or unreadable host exports prevent fresh NFS preparation.\n' >&2
            return 1
        }
    fi
    if [[ -e "$NFS_HOST_EXPORTS_DIR" || -L "$NFS_HOST_EXPORTS_DIR" ]]; then
        [[ -d "$NFS_HOST_EXPORTS_DIR" ]] || return 1
        find -L "$NFS_HOST_EXPORTS_DIR" -maxdepth 1 -name '*.exports' \
            -exec awk 'NF && $1 !~ /^#/ {exit 1}' {} + || {
            printf 'Configured or unreadable export drop-ins prevent fresh NFS preparation.\n' >&2
            return 1
        }
    fi
    for unit in "${NFS_UNITS[@]}"; do
        load_state=$(sudo systemctl show "$unit" -p LoadState --value) || return 1
        case "$load_state" in
            not-found) continue ;;
            loaded|masked) ;;
            *) printf 'Cannot determine host unit state: %s\n' "$unit" >&2; return 1 ;;
        esac
        active_state=$(sudo systemctl show "$unit" -p ActiveState --value) || return 1
        [[ "$active_state" == active || "$active_state" == inactive ]] || {
            printf 'Resolve the transitional or failed host unit first: %s\n' "$unit" >&2
            return 1
        }
        units+=("$unit")
        if [[ "$unit" == rpcbind.service && "$active_state" == active ]]; then rpc_active=true; fi
    done
    if [[ "$rpc_active" == true ]]; then
        registrations=$(sudo timeout --kill-after=5 15 rpcinfo -p) || return 1
        awk 'NR == 1 {if ($1 != "program") exit 1; next}
             $1 !~ /^(100000|100003|100005|100021|100024|100227)$/ {exit 1}
             END {if (NR == 0) exit 1}' <<< "$registrations" || {
            printf 'Unknown RPC registrations prevent fresh NFS preparation.\n' >&2
            return 1
        }
    fi
    for unit in "${units[@]}"; do
        [[ "$unit" == *.socket ]] || continue
        sudo systemctl stop "$unit" || return 1
        sudo systemctl mask "$unit" || return 1
    done
    for unit in "${units[@]}"; do
        [[ "$unit" != *.socket ]] || continue
        sudo systemctl stop "$unit" || return 1
    done
    for unit in "${units[@]}"; do
        [[ "$unit" == *.socket || "$unit" == *.mount ]] || sudo systemctl mask "$unit" || return 1
    done
    verify_container_nfs_stopped || return 1
    container_nfs_host_preflight || return 1
    printf 'Fresh host NFS/RPC ownership prepared; native packages and configuration retained.\n'
}

migration_preflight() {
    local image="$1" allow_running_guests="${2:-}" guests exports label unit exists
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
    if [[ -n "$guests" ]]; then
        if [[ "$allow_running_guests" != --allow-running-guests ]]; then
            printf 'Shut down running guests or explicitly acknowledge their independence with --allow-running-guests.\n' >&2
            return 1
        fi
        printf 'Keeping running guests: operator confirms no NFS dependency and accepts engine-service interruption.\n%s\n' "$guests" >&2
    fi
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
    printf 'Host NFS and the previous engine restored. Restore the previous source version before using legacy lifecycle commands.\n'
}

destroy_nfs_engine() {
    local engine_exists backup_exists backup_id='' metadata mounts checkpoint=false
    engine_exists=$(container_nfs_exists "$NFS_ENGINE") || return 1
    backup_exists=$(container_nfs_exists "$NFS_BACKUP") || return 1
    if [[ -e "$NFS_MIGRATION_DIR" || -L "$NFS_MIGRATION_DIR" ]]; then
        [[ -d "$NFS_MIGRATION_DIR" && "$(readlink -e "$NFS_MIGRATION_DIR")" == "$NFS_MIGRATION_DIR" ]] || return 1
        mounts=$(findmnt --json -o TARGET) || return 1
        jq -e --arg path "$NFS_MIGRATION_DIR" '[.. | objects | .target? // empty | select(. == $path or startswith($path + "/"))] | length == 0' <<< "$mounts" >/dev/null || return 1
        checkpoint=true
    fi
    if [[ "$backup_exists" == true ]]; then
        [[ "$checkpoint" == true ]] || { printf 'Cannot identify the migration backup without its checkpoint.\n' >&2; return 1; }
        [[ -f "$NFS_MIGRATION_DIR/snapshot-complete" && -f "$NFS_MIGRATION_DIR/committed" ]] || {
            printf 'Incomplete NFS migration; resolve rollback before destroy.\n' >&2
            return 1
        }
        backup_id=$(cat "$NFS_MIGRATION_DIR/engine-id") || return 1
        [[ "$backup_id" =~ ^[a-f0-9]{64}$ ]] || return 1
        metadata=$(sudo podman inspect "$NFS_BACKUP") || return 1
        jq -e --arg id "$backup_id" 'length == 1 and (.[0] | .Id == $id and .State.Running == false and .State.Pid == 0 and (.State.Restarting // false) == false)' <<< "$metadata" >/dev/null || {
            printf 'Migration backup identity or stopped state could not be verified.\n' >&2
            return 1
        }
    fi
    stop_engine_nfs "$NFS_ENGINE" || return 1
    if [[ "$engine_exists" == true ]]; then
        remove_engine_container "$NFS_ENGINE" || return 1
    fi
    if [[ "$backup_exists" == true ]]; then
        remove_engine_container "$backup_id" || return 1
    fi
    if [[ "$checkpoint" == true ]]; then
        sudo rm -rf --one-file-system -- "$NFS_MIGRATION_DIR" || return 1
    fi
    printf 'Engine cleanup complete; no active migration backup or checkpoint remains.\n'
}

apply_nfs_migration() {
    local image="$1" allow_running_guests="${2:-}" unit active enabled ipv4 ipv6 ipv4_network ipv6_network bridge hostname domain
    migration_preflight "$image" "$allow_running_guests" || return 1
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
            printf 'Usage: sudo bash setup/migrate-nfs-to-container.sh {--check|--apply} IMAGE [--allow-running-guests] | --rollback\n'
            printf 'Use --allow-running-guests only after confirming guests have no NFS dependency and accepting engine-service interruption.\n'
            printf 'Fresh deployment: --prepare-fresh requires an empty host and retains native NFS packages.\n'
            printf 'Internal: --destroy-engine is called only after tux2lab destroy confirmation.\n'
            exit 0 ;;
        --check|--apply)
            [[ $# == 2 || ( $# == 3 && "${3:-}" == --allow-running-guests ) ]] || exit 2 ;;
        --rollback|--destroy-engine|--prepare-fresh) [[ $# == 1 ]] || exit 2 ;;
        *) printf 'Use --help for migration usage.\n' >&2; exit 2 ;;
    esac
    [[ "$EUID" == 0 ]] || { printf 'Run this migration command with sudo.\n' >&2; exit 1; }
    mkdir -p /run/lock
    exec 9>/run/lock/tux2lab-nfs-migration.lock
    flock -n 9 || { printf 'Another NFS migration is running.\n' >&2; exit 1; }
    (
        case "$1" in
            --check) migration_preflight "$2" "${3:-}" ;;
            --apply) apply_nfs_migration "$2" "${3:-}" ;;
            --rollback) restore_host_nfs ;;
            --destroy-engine) destroy_nfs_engine ;;
            --prepare-fresh) prepare_fresh_host_nfs ;;
        esac
    ) 9>&-
fi