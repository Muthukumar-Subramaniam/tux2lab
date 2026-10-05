#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$PROJECT_ROOT/shared-functions/container-nfs.sh"

TEST_UNITS=(nfs-server.service nfs-mountd.service nfs-idmapd.service nfsdcld.service
    rpc-statd.service rpcbind.service rpcbind.socket proc-fs-nfsd.mount
    auth-rpcgss-module.service rpc-statd-notify.service rpc_pipefs.target
    var-lib-nfs-rpc_pipefs.mount nfs-client.target gssproxy.service)
SAVED_ENGINE=tux2lab-engine-acceptance-original

snapshot_units() {
    local unit load active enabled
    for unit in "${TEST_UNITS[@]}"; do
        load=$(systemctl show "$unit" -p LoadState --value) || return 1
        [[ "$load" == not-found ]] && continue
        [[ "$load" == loaded || "$load" == masked ]] || return 1
        active=$(systemctl show "$unit" -p ActiveState --value) || return 1
        enabled=$(systemctl show "$unit" -p UnitFileState --value) || return 1
        [[ "$active" == active || "$active" == inactive ]] || return 1
        printf '%s\t%s\t%s\n' "$unit" "$active" "$enabled"
    done
}

check_evidence() {
    [[ "$EUID" == 0 && -d "$EVIDENCE" && "$(readlink -e "$EVIDENCE")" == "$EVIDENCE" ]] || return 1
    [[ "$EVIDENCE" == /home/*/nfs-migration-validation.* && "$EVIDENCE" != /tux2lab-data* ]] || return 1
}

check_test_host() {
    local expected_host="$1" guests containers
    [[ "$expected_host" != localhost && "$(hostname -f)" == "$expected_host" ]] || return 1
    guests=$(sudo -n virsh list --name) || return 1
    [[ -z "$guests" ]] || return 1
    containers=$(sudo -n podman ps -a --format '{{.Names}}') || return 1
    [[ "$containers" == tux2lab-engine ]] || return 1
    require_container_nfs_engine tux2lab-engine
    check_engine_nfs tux2lab-engine
    container_nfs_require_no_client_mounts
    sudo -n test ! -e /var/lib/tux2lab/nfs-migration
    ip -d -j link show dev labbr0 | jq -e 'length == 1 and .[0].linkinfo.info_kind == "bridge"' >/dev/null
    ip -d -j link show master labbr0 | jq -e 'all(.[]; .linkinfo.info_kind == "dummy")' >/dev/null
    printf 'PASS: dedicated host is ready for migration-test preparation\n'
}

read_installer() (
    local ipv4="$1" ipv6="$2" expected="$3" protocol server options checksum
    local client_dir
    client_dir=$(mktemp -d /tmp/tux2lab-migration-client.XXXXXXXX)
    cleanup_reader() {
        local status=$?
        trap - EXIT
        if mountpoint -q "$client_dir"; then umount "$client_dir" || exit 1; fi
        rmdir "$client_dir" || exit 1
        exit "$status"
    }
    trap cleanup_reader EXIT
    for protocol in v3-ipv4 v4-ipv4 v4-ipv6; do
        case "$protocol" in
            v3-ipv4) server="$ipv4"; options=vers=3,proto=tcp,nolock ;;
            v4-ipv4) server="$ipv4"; options=vers=4.1,proto=tcp ;;
            v4-ipv6) server="[$ipv6]"; options=vers=4.1,proto=tcp6 ;;
        esac
        timeout -k 5 180 mount -t nfs -o "ro,soft,timeo=50,retrans=30,retry=0,$options" \
            "$server:/tux2lab-data" "$client_dir"
        checksum=$(timeout -k 5 180 sha256sum "$client_dir/os-repos/almalinux/9/images/install.img")
        [[ "${checksum%% *}" == "$expected" ]]
        umount "$client_dir"
        printf 'PASS: full installer checksum over %s\n' "$protocol"
    done
)

verify_protocols() {
    local ipv4 ipv6 checksum discovery
    ipv4=$(jq -er '.network.ipv4.address' /tux2lab-data/lab-config/lab_environment.json)
    ipv6=$(jq -er '.network.ipv6.address' /tux2lab-data/lab-config/lab_environment.json)
    checksum=$(sha256sum /tux2lab-data/os-repos/almalinux/9/images/install.img)
    discovery=$(showmount -e "$ipv4")
    [[ "$(awk 'NR > 1 {print $1}' <<< "$discovery")" == /tux2lab-data ]]
    unshare --mount --propagation private bash "$PROJECT_ROOT/container/run-migration-tests.sh" \
        --read-client "$ipv4" "$ipv6" "${checksum%% *}"
}

verify_baseline() {
    [[ "$(podman inspect tux2lab-engine --format '{{.Id}}')" == "$(cat "$EVIDENCE/baseline-id")" ]]
    [[ "$(podman inspect tux2lab-engine --format '{{.State.Running}}')" == true ]]
    systemctl is-active --quiet nfs-server.service
    exportfs -s | cmp -s "$EVIDENCE/baseline-exports" -
    snapshot_units | cmp -s "$EVIDENCE/baseline-units" -
    [[ "$(sysctl -n fs.nfs.nlm_tcpport)" == "$(cat "$EVIDENCE/baseline-lockd-tcp")" ]]
    [[ "$(sysctl -n fs.nfs.nlm_udpport)" == "$(cat "$EVIDENCE/baseline-lockd-udp")" ]]
    verify_protocols
    printf 'PASS: released engine, host exports, unit states and lockd settings restored\n'
}

restore_current_engine() {
    local original exists unit active enabled state
    check_evidence || return 1
    [[ "$(cat "$EVIDENCE/host")" == "$(hostname -f)" ]] || return 1
    original=$(cat "$EVIDENCE/original-id") || return 1
    exists=$(container_nfs_exists "$SAVED_ENGINE") || return 1
    if [[ "$exists" == true ]]; then
        [[ "$(podman inspect "$SAVED_ENGINE" --format '{{.Id}}')" == "$original" ]] || return 1
        if [[ -e /var/lib/tux2lab/nfs-migration ]]; then
            bash "$PROJECT_ROOT/setup/migrate-nfs-to-container.sh" --rollback || return 1
        fi
        exists=$(container_nfs_exists tux2lab-engine) || return 1
        if [[ "$exists" == true ]]; then
            [[ -f "$EVIDENCE/baseline-id" && "$(podman inspect tux2lab-engine --format '{{.Id}}')" == "$(cat "$EVIDENCE/baseline-id")" ]] || return 1
            podman stop --time 30 tux2lab-engine || return 1
            podman rm tux2lab-engine || return 1
        fi
        while IFS=$'\t' read -r unit active enabled; do
            if [[ "$active" == inactive ]]; then
                systemctl stop "$unit" || {
                    [[ "$(systemctl show "$unit" -p MainPID --value)" == 0 ]] || return 1
                }
                state=$(systemctl show "$unit" -p ActiveState --value) || return 1
                if [[ "$state" == failed ]]; then systemctl reset-failed "$unit" || return 1; fi
                [[ "$(systemctl show "$unit" -p ActiveState --value)" == inactive ]] || return 1
            fi
        done < "$EVIDENCE/original-units"
        verify_container_nfs_stopped || return 1
        rm -f /etc/exports.d/tux2lab.exports || return 1
        tar -xpf "$EVIDENCE/host-config.tar" -C / || return 1
        tar -xpf "$EVIDENCE/host-nfs-state.tar" -C /var/lib/nfs || return 1
        if [[ -d "$EVIDENCE/original-nfs" ]]; then
            cp -a "$EVIDENCE/original-nfs/." /tux2lab-data/nfs/ || return 1
            if [[ ! -e "$EVIDENCE/original-nfs/nfs.conf.original" ]]; then
                rm -f /tux2lab-data/nfs/nfs.conf.original || return 1
            fi
        fi
        sysctl -w "fs.nfs.nlm_tcpport=$(cat "$EVIDENCE/original-lockd-tcp")" \
            "fs.nfs.nlm_udpport=$(cat "$EVIDENCE/original-lockd-udp")" >/dev/null || return 1
        while IFS=$'\t' read -r unit active enabled; do
            if [[ "$enabled" == masked ]]; then systemctl mask "$unit" || return 1; fi
            if [[ "$active" == active ]]; then systemctl start "$unit" || return 1; fi
        done < "$EVIDENCE/original-units"
        snapshot_units | cmp -s "$EVIDENCE/original-units" - || return 1
        podman rename "$SAVED_ENGINE" tux2lab-engine || return 1
    fi
    [[ "$(podman inspect tux2lab-engine --format '{{.Id}}')" == "$original" ]] || return 1
    if [[ "$(podman inspect tux2lab-engine --format '{{.State.Running}}')" != true ]]; then
        podman start tux2lab-engine || return 1
    fi
    wait_for_engine_nfs tux2lab-engine || return 1
    touch "$EVIDENCE/restored" || return 1
    printf 'PASS: original container-NFS engine and host service configuration restored\n'
}

run_acceptance() (
    local expected_host="$1" released_image="$2" candidate_image="$3" released_source="$EVIDENCE/released-source"
    local ipv4 ipv6 bridge engine_fqdn failure_status label clients
    check_evidence
    check_test_host "$expected_host"
    [[ ! -e "$EVIDENCE/original-id" && ! -e /etc/exports.d/tux2lab.exports ]]
    [[ -f "$released_source/shared-functions/host-nfs.sh" && -f "$released_source/shared-functions/run-container.sh" ]]
    label=$(podman image inspect "$released_image" --format '{{index .Labels "io.tux2lab.nfs"}}')
    [[ -z "$label" ]]
    container_nfs_image_check "$candidate_image"
    clients=$(podman exec tux2lab-engine find /proc/fs/nfsd/clients -mindepth 1 -maxdepth 1 -type d)
    [[ -z "$clients" ]]
    exec 8>/run/lock/tux2lab-nfs-acceptance.lock
    flock -n 8
    hostname -f > "$EVIDENCE/host"
    podman inspect tux2lab-engine --format '{{.Id}}' > "$EVIDENCE/original-id"
    snapshot_units > "$EVIDENCE/original-units"
    sysctl -n fs.nfs.nlm_tcpport > "$EVIDENCE/original-lockd-tcp"
    sysctl -n fs.nfs.nlm_udpport > "$EVIDENCE/original-lockd-udp"
    tar -cpf "$EVIDENCE/host-config.tar" -C / etc/nfs.conf etc/exports etc/exports.d
    tar --one-file-system --exclude=./rpc_pipefs -cpf "$EVIDENCE/host-nfs-state.tar" -C /var/lib/nfs .
    chmod 600 "$EVIDENCE/host-config.tar" "$EVIDENCE/host-nfs-state.tar"
    restore_on_exit() {
        local status=$?
        trap - EXIT
        if ! restore_current_engine; then
            printf 'RESTORATION INCOMPLETE: retain %s and the saved original engine.\n' "$EVIDENCE" >&2
            exit 1
        fi
        exit "$status"
    }
    trap restore_on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    stop_engine_nfs tux2lab-engine
    cp -a /tux2lab-data/nfs "$EVIDENCE/original-nfs"
    podman rename tux2lab-engine "$SAVED_ENGINE"
    systemctl unmask rpcbind.service rpcbind.socket
    sysctl -w fs.nfs.nlm_tcpport=0 fs.nfs.nlm_udpport=0 >/dev/null
    ipv4=$(jq -er '.network.ipv4.address' /tux2lab-data/lab-config/lab_environment.json)
    ipv6=$(jq -er '.network.ipv6.address' /tux2lab-data/lab-config/lab_environment.json)
    bridge=$(jq -er '.network.bridge_interface' /tux2lab-data/lab-config/lab_environment.json)
    engine_fqdn=$(jq -er '.lab.engine_fqdn' /tux2lab-data/lab-config/lab_environment.json)
    (
        trap - EXIT INT TERM
        source "$released_source/common-utils/color-functions.sh"
        source "$released_source/shared-functions/run-container.sh"
        source "$released_source/shared-functions/host-nfs.sh"
        run_tux2lab_container tux2lab-engine "$released_image" "$engine_fqdn" /tux2lab-data "$ipv4" "$bridge"
        podman inspect tux2lab-engine --format '{{.Id}}' > "$EVIDENCE/baseline-id"
        start_host_nfs "$ipv4" "$ipv6"
    )
    systemctl is-active --quiet nfs-server.service
    exportfs -s > "$EVIDENCE/baseline-exports"
    snapshot_units > "$EVIDENCE/baseline-units"
    sysctl -n fs.nfs.nlm_tcpport > "$EVIDENCE/baseline-lockd-tcp"
    sysctl -n fs.nfs.nlm_udpport > "$EVIDENCE/baseline-lockd-udp"
    verify_baseline | tee "$EVIDENCE/baseline-reads.log"
    bash "$PROJECT_ROOT/setup/migrate-nfs-to-container.sh" --check "$candidate_image"
    bash "$PROJECT_ROOT/setup/migrate-nfs-to-container.sh" --apply "$candidate_image" | tee "$EVIDENCE/apply.log"
    check_engine_nfs tux2lab-engine
    verify_protocols | tee "$EVIDENCE/migrated-reads.log"
    bash "$PROJECT_ROOT/setup/migrate-nfs-to-container.sh" --rollback | tee "$EVIDENCE/rollback.log"
    verify_baseline | tee "$EVIDENCE/rollback-reads.log"
    failure_status=0
    bash -s -- "$PROJECT_ROOT" "$candidate_image" <<'FAILURE' > "$EVIDENCE/injected-failure.log" 2>&1 || failure_status=$?
set -euo pipefail
source "$1/setup/migrate-nfs-to-container.sh"
exec 9>/run/lock/tux2lab-nfs-migration.lock
flock -n 9
run_tux2lab_container() {
    (
        trap - EXIT INT TERM HUP QUIT
        source "$NFS_MIGRATION_PROJECT_ROOT/shared-functions/run-container.sh"
        run_tux2lab_container "$@"
    ) || return 1
    printf 'INJECTED: reject handover after the real candidate becomes ready\n' >&2
    return 1
}
apply_nfs_migration "$2"
FAILURE
    cat "$EVIDENCE/injected-failure.log"
    [[ "$failure_status" == 1 ]]
    grep -q '^INJECTED:' "$EVIDENCE/injected-failure.log"
    [[ ! -e /var/lib/tux2lab/nfs-migration ]]
    verify_baseline | tee "$EVIDENCE/failure-rollback-reads.log"
    restore_current_engine
    trap - EXIT INT TERM
    verify_protocols | tee "$EVIDENCE/restored-reads.log"
    printf 'PASS: successful migration, explicit rollback, failed-handover rollback and original restoration\n'
)

case "${1:-}" in
    --check)
        [[ $# == 2 ]] || exit 2
        check_test_host "$2" ;;
    --run)
        [[ $# == 5 ]] || exit 2
        EVIDENCE="$3"
        run_acceptance "$2" "$4" "$5" ;;
    --restore)
        [[ $# == 3 && "$(hostname -f)" == "$2" ]] || exit 2
        EVIDENCE="$3"
        restore_current_engine ;;
    --read-client)
        [[ $# == 4 && "$EUID" == 0 ]] || exit 2
        read_installer "$2" "$3" "$4" ;;
    *) printf 'Usage: %s --check HOST | --run HOST EVIDENCE RELEASED_IMAGE CANDIDATE_IMAGE | --restore HOST EVIDENCE\n' "$0" >&2; exit 2 ;;
esac