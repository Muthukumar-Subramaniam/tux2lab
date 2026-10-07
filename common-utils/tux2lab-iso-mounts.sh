#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name : tux2lab-iso-mounts.sh
# Description : Mount/unmount all ISO files listed in the iso-mounts config
# Used by     : tux2lab start/stop
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#
set -uo pipefail
IFS=$'\n\t'

readonly CONFIG_FILE="/tux2lab-data/iso-mounts.conf"
readonly ISO_DIR="/tux2lab-data/iso-files"
readonly MOUNT_BASE="/tux2lab-data/os-repos"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

iso_is_mounted() {
    local mount_dir="$1" device parent_device
    [[ -d "$mount_dir" ]] || return 1
    device=$(stat -Lc %d -- "$mount_dir") || return 2
    parent_device=$(stat -Lc %d -- "$mount_dir/..") || return 2
    [[ "$device" != "$parent_device" ]]
}

do_mount() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "No config file at ${CONFIG_FILE} — nothing to mount."
        exit 0
    fi

    local count=0 skipped=0 failed=0

    while IFS=$'\t ' read -r iso_file distro version; do
        # Skip empty lines and comments
        [[ -z "$iso_file" || "$iso_file" == \#* ]] && continue

        local iso_path="${ISO_DIR}/${iso_file}"
        local mount_dir="${MOUNT_BASE}/${distro}/${version}"

        if [[ ! -f "$iso_path" ]]; then
            log "SKIP: ISO not found: ${iso_path}"
            (( skipped++ ))
            continue
        fi

        if iso_is_mounted "$mount_dir"; then
            log "SKIP: Already mounted: ${mount_dir}"
            (( skipped++ ))
            continue
        elif [[ $? != 1 ]]; then
            log "FAILED: Could not inspect ${mount_dir}"
            (( failed++ ))
            continue
        fi

        if ! mkdir -p "$mount_dir"; then
            log "FAILED: Could not create ${mount_dir}"
            (( failed++ ))
            continue
        fi

        local loop_device
        if ! loop_device=$(losetup --find --show --read-only "$iso_path"); then
            log "FAILED: Could not allocate a loop device for ${iso_path}"
            (( failed++ ))
            continue
        fi

        if mount -o ro "$loop_device" "$mount_dir" 2>/dev/null; then
            log "MOUNTED: ${iso_path} → ${mount_dir}"
            (( count++ ))
        else
            log "FAILED: Could not mount ${iso_path} → ${mount_dir}"
            (( failed++ ))
        fi

        if ! losetup --detach "$loop_device"; then
            log "FAILED: Could not enable cleanup for ${loop_device}"
            (( failed++ ))
        fi
    done < "$CONFIG_FILE"

    log "Mount complete: ${count} mounted, ${skipped} skipped, ${failed} failed."

    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

do_unmount() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        exit 0
    fi

    local count=0 failed=0

    while IFS=$'\t ' read -r iso_file distro version; do
        [[ -z "$iso_file" || "$iso_file" == \#* ]] && continue

        local mount_dir="${MOUNT_BASE}/${distro}/${version}"

        if iso_is_mounted "$mount_dir"; then
            if umount "$mount_dir" 2>/dev/null; then
                log "UNMOUNTED: ${mount_dir}"
                (( count++ ))
            else
                log "WARN: Could not unmount ${mount_dir} (busy?)"
                (( failed++ ))
            fi
        elif [[ $? != 1 ]]; then
            log "FAILED: Could not inspect ${mount_dir}"
            (( failed++ ))
        fi
    done < "$CONFIG_FILE"

    log "Unmount complete: ${count} unmounted, ${failed} failed."
    [[ $failed == 0 ]]
}

case "${1:-}" in
    start)  do_mount ;;
    stop)   do_unmount ;;
    *)
        echo "Usage: $0 {start|stop}" >&2
        exit 1
        ;;
esac
