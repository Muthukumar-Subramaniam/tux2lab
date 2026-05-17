#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name : prepare-distro-for-ksmanager.sh
# Description : Manage OS distribution ISOs for PXE provisioning on the lab infra server
# Invoked by  : tux2lab distro {list|setup|cleanup} [distro] [--version ver]
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/ks-manage/distro-versions.conf

# Source environment variables
if [[ -f /etc/environment ]]; then
    source /etc/environment
fi
if [[ -f /tux2lab-data/lab_environment_vars ]]; then
    source /tux2lab-data/lab_environment_vars
fi
# In host mode, mgmt_super_user may come from lab_environment_vars as lab_infra_admin_username
if [[ -z "${mgmt_super_user:-}" && -n "${lab_infra_admin_username:-}" ]]; then
    mgmt_super_user="${lab_infra_admin_username}"
fi

# ====== ACCESS CONTROL ======
if [[ "$USER" != "$mgmt_super_user" ]]; then
    print_error "Access denied. Only infra management super user '${mgmt_super_user}' is authorized to run this tool."
    print_error "If the user itself is ${mgmt_super_user}, please do not elevate access again with sudo."
    exit 1
fi

set -euo pipefail

: "${dnsbinder_server_fqdn:?Must set dnsbinder_server_fqdn}"
: "${dnsbinder_domain:?Must set dnsbinder_domain}"
: "${mgmt_super_user:?Must set mgmt_super_user}"

# ====== CONSTANTS ======
readonly ISO_DIR="/tux2lab-data/iso-files"
readonly FSTAB="/etc/fstab"
readonly GOLDEN_IMAGE_DIR="/tux2lab-data/golden-images-disk-store"
readonly MIN_DISK_SPACE_GB=12

# ====== DEPENDENCY CHECK ======
MISSING_COMMANDS=()
for cmd in wget curl mountpoint sed awk grep sha256sum; do
    command -v "$cmd" &>/dev/null || MISSING_COMMANDS+=("$cmd")
done
if [[ ${#MISSING_COMMANDS[@]} -gt 0 ]]; then
    print_error "Missing required commands: ${MISSING_COMMANDS[*]}"
    print_info "Please install the missing tools before running this script."
    exit 1
fi

# ====== USAGE ======
print_usage() {
    print_info "Usage: tux2lab distro <subcommand> [distro] [--version|-v <version>]

Subcommands:
    list                                    List all distros with readiness status
    setup [distro --version|-v ver]         Download ISO and mount for PXE provisioning
    cleanup [distro --version|-v ver]       Unmount and remove ISO for a distro

Supported distros:
    almalinux, rocky, oraclelinux, centos-stream, rhel, ubuntu-lts, opensuse-leap

Version:
    The actual version number, e.g. 9, 10, 22.04, 24.04, 26.04, 15.5, 15.6"
}

# ====== HELPER FUNCTIONS ======

fn_is_distro_ready() {
    local distro="$1" ver="$2"
    mountpoint -q "/tux2lab-data/os-repos/${distro}/${ver}" 2>/dev/null
}

fn_has_golden_image() {
    local distro="$1" ver="$2"
    local ver_sanitized="${ver//\./-}"
    local image_name="${distro}-${ver_sanitized}-golden-image.${dnsbinder_domain}"
    # If golden image list was passed from KVM host, check that
    if [[ -n "${GOLDEN_IMAGES_ON_HOST:-}" ]]; then
        [[ ",${GOLDEN_IMAGES_ON_HOST}," == *",${image_name},"* ]]
    else
        [[ -f "${GOLDEN_IMAGE_DIR}/${image_name}.qcow2" ]]
    fi
}

fn_validate_distro() {
    local distro="$1"
    if [[ -z "${DISTRO_AVAILABLE_VERSIONS[$distro]+set}" ]]; then
        print_error "Unknown distro: ${distro}"
        print_info "Supported distros: ${DISTRO_KEYS[*]}"
        exit 1
    fi
}

fn_validate_version() {
    local distro="$1" version="$2"
    if ! fn_is_valid_version "$distro" "$version"; then
        print_error "Invalid version '${version}' for ${distro}."
        print_info "Available versions: ${DISTRO_AVAILABLE_VERSIONS[$distro]}"
        exit 1
    fi
}

fn_check_disk_space() {
    local target_dir="$1"
    local required_gb="$2"
    local available_kb
    available_kb=$(df --output=avail "$target_dir" 2>/dev/null | tail -1 | tr -d '[:space:]')
    local available_gb=$(( available_kb / 1024 / 1024 ))
    if [[ "$available_gb" -lt "$required_gb" ]]; then
        print_error "Insufficient disk space on $target_dir"
        print_info "Available: ${available_gb} GiB, Required: ${required_gb} GiB"
        exit 1
    fi
    print_info "Disk space check passed: ${available_gb} GiB available (${required_gb} GiB required)"
}

fn_download_checksum() {
    local checksum_url="$1"
    local checksum_file="$2"

    print_task "Downloading CHECKSUM file..."
    rm -f "$checksum_file"
    if ! wget --quiet --output-document="$checksum_file" "$checksum_url"; then
        print_task_fail
        print_error "Failed to download CHECKSUM from ${checksum_url}"
        rm -f "$checksum_file"
        return 1
    fi
    print_task_done
    return 0
}

fn_extract_expected_hash() {
    local iso_name="$1"
    local checksum_file="$2"
    local expected_hash
    # Try common checksum formats: "SHA256 (filename) = hash" or "hash  filename"
    expected_hash=$(grep -i "SHA256" "$checksum_file" | grep "$iso_name" | awk -F'= ' '{print $2}' | tr -d '[:space:]') || true
    if [[ -z "$expected_hash" ]]; then
        # Fallback: "hash  filename" format
        expected_hash=$(grep "$iso_name" "$checksum_file" | awk '{print $1}' | head -1 | tr -d '[:space:]') || true
    fi
    if [[ -z "$expected_hash" ]]; then
        print_error "Could not find SHA256 checksum for ${iso_name} in CHECKSUM file."
        print_info "The CHECKSUM file format may have changed. Please verify manually."
        return 1
    fi
    echo "$expected_hash"
}

fn_verify_iso() {
    local iso_path="$1"
    local expected_hash="$2"
    print_info "Calculating SHA256 checksum (this may take a few minutes)..."
    local actual_hash
    actual_hash=$(sha256sum "$iso_path" | awk '{print $1}')

    print_task "Comparing checksums"
    if [[ "$expected_hash" == "$actual_hash" ]]; then
        print_task_done
        print_success "Checksum matched. ISO file is valid."
        return 0
    else
        print_task_fail
        print_error "Checksum mismatch. ISO file is corrupt or incomplete!"
        print_info "Expected: ${expected_hash}"
        print_info "Actual:   ${actual_hash}"
        return 1
    fi
}

# ====== INTERACTIVE SELECTION ======

fn_select_distro() {
    local action_title="$1"

    while true; do
    local menu="Please select the OS distribution to ${action_title}:\n"
    for i in "${!DISTRO_KEYS[@]}"; do
        local key="${DISTRO_KEYS[$i]}"
        printf -v line "  %d)  %-32s (versions: %s)\n" $((i+1)) "${DISTRO_DISPLAY_NAMES[$key]}" "${DISTRO_AVAILABLE_VERSIONS[$key]}"
        menu+="${line}"
    done
    menu+="  q)  Quit"

    print_notify "$menu"
    echo -n "Enter option number: "
    read -r distro_choice

    if [[ "${distro_choice}" == "q" || "${distro_choice}" == "Q" ]]; then
        print_info "Operation cancelled by user."
        exit 130
    fi

    if [[ "${distro_choice}" =~ ^[0-9]+$ ]] && (( distro_choice >= 1 && distro_choice <= ${#DISTRO_KEYS[@]} )); then
        DISTRO="${DISTRO_KEYS[$((distro_choice-1))]}"
        break
    else
        print_error "Invalid option. Please try again."
        continue
    fi
    done
}

fn_select_version() {
    local distro="$1"
    local available_versions=(${DISTRO_AVAILABLE_VERSIONS[$distro]})

    while true; do
    local menu="Please select the version for ${DISTRO_DISPLAY_NAMES[$distro]}:\n"
    for i in "${!available_versions[@]}"; do
        local ver="${available_versions[$i]}"
        local status
        if fn_is_distro_ready "$distro" "$ver"; then
            status=$(print_green "[Ready]" nskip)
        else
            status=$(print_yellow "[not-yet-setup]" nskip)
        fi
        printf -v line "  %d)  %-12s %s\n" $((i+1)) "${ver}" "${status}"
        menu+="${line}"
    done
    menu+="  q)  Quit"

    print_notify "$menu"
    echo -n "Enter option number: "
    read -r version_choice

    if [[ "${version_choice}" == "q" || "${version_choice}" == "Q" ]]; then
        print_info "Operation cancelled by user."
        exit 130
    fi

    if [[ "${version_choice}" =~ ^[0-9]+$ ]] && (( version_choice >= 1 && version_choice <= ${#available_versions[@]} )); then
        VERSION="${available_versions[$((version_choice-1))]}"
        break
    else
        print_error "Invalid option. Please try again."
        continue
    fi
    done
}

# ====== LIST ======

fn_list_distros() {
    local col_distro=28 col_ver=12 col_pxe=15
    printf "\n  %-${col_distro}s %-${col_ver}s %-${col_pxe}s %s\n" "DISTRO" "VERSION" "PXE-READY" "GOLDEN-IMAGE"
    printf "  %-${col_distro}s %-${col_ver}s %-${col_pxe}s %s\n" "------" "-------" "---------" "------------"

    for distro in "${DISTRO_KEYS[@]}"; do
        for ver in ${DISTRO_AVAILABLE_VERSIONS[$distro]}; do
            local pxe_padded pxe_status golden_status
            if fn_is_distro_ready "$distro" "$ver"; then
                pxe_padded=$(printf "%-${col_pxe}s" "Ready")
                pxe_status=$(print_green "$pxe_padded" nskip)
            else
                pxe_padded=$(printf "%-${col_pxe}s" "not-yet-setup")
                pxe_status=$(print_yellow "$pxe_padded" nskip)
            fi
            if fn_has_golden_image "$distro" "$ver"; then
                golden_status=$(print_green "Available" nskip)
            else
                golden_status=$(print_yellow "not-yet-built" nskip)
            fi
            printf "  %-${col_distro}s %-${col_ver}s %s %s\n" "${DISTRO_DISPLAY_NAMES[$distro]}" "$ver" "$pxe_status" "$golden_status"
        done
    done
    echo
}

# ====== SETUP ======

fn_get_iso_url() {
    local distro="$1" version="$2"

    # RHEL requires manual download — prompt for URL or manual placement
    if [[ "$distro" == "rhel" ]]; then
        local iso_file="${ISO_FILENAMES[${distro}:${version}]:-}"
        local iso_path="${ISO_DIR}/${iso_file}"
        print_warning "Red Hat Enterprise Linux requires an active subscription to download."
        print_info "RHEL ISOs are not publicly downloadable. You have two options:"
        print_info "  1. Manually download the ISO from https://developers.redhat.com/products/rhel/download"
        print_info "     and place it at: ${iso_path}"
        print_info "  2. Paste a direct download URL below (from your Red Hat account)"
        echo
        read -rp "Paste direct ISO download URL, or press Enter if you placed the ISO manually: " iso_url
        if [[ -n "$iso_url" ]]; then
            echo "$iso_url"
        elif [[ -f "$iso_path" ]]; then
            print_success "Found manually placed ISO: ${iso_path}"
            echo ""
        else
            print_error "No ISO found at ${iso_path} and no download URL provided."
            exit 1
        fi
        return
    fi

    local url="${ISO_URLS[${distro}:${version}]:-}"
    if [[ -z "$url" ]]; then
        print_error "No ISO URL configured for ${distro} ${version}."
        exit 1
    fi
    echo "$url"
}

fn_setup_distro() {
    local distro="$1" version="$2"

    if fn_is_distro_ready "$distro" "$version"; then
        print_warning "Distro '${DISTRO_DISPLAY_NAMES[$distro]} ${version}' is already set up."
        print_info "To re-setup, run cleanup first: tux2lab distro cleanup ${distro} --version ${version}"
        exit 1
    fi

    local iso_file="${ISO_FILENAMES[${distro}:${version}]:-}"
    if [[ -z "$iso_file" ]]; then
        print_error "No ISO filename configured for ${distro} ${version}."
        exit 1
    fi

    local iso_url
    iso_url=$(fn_get_iso_url "$distro" "$version")

    local iso_path="${ISO_DIR}/${iso_file}"
    local mount_dir="/tux2lab-data/os-repos/${distro}/${version}"
    local distro_key="${distro}:${version}"
    local checksum_url="${CHECKSUM_URLS[$distro_key]:-}"
    local checksum_file="${ISO_DIR}/${distro}-${version}-CHECKSUM"

    # Ensure ISO directory exists
    print_task "Ensuring ISO directory exists..."
    sudo mkdir -p "$ISO_DIR"
    sudo chown "${mgmt_super_user}:${mgmt_super_user}" "$ISO_DIR"
    print_task_done

    # Download and parse checksum if available
    local has_checksum=false
    local expected_hash=""
    # Use the real filename from the download URL for checksum lookup
    # (e.g., ubuntu-24.04.4-live-server-amd64.iso vs the generic ISO_FILENAMES entry)
    local checksum_lookup_name
    if [[ -n "${iso_url:-}" ]]; then
        checksum_lookup_name=$(basename "$iso_url")
    else
        checksum_lookup_name="$iso_file"
    fi
    if [[ -n "$checksum_url" ]]; then
        if fn_download_checksum "$checksum_url" "$checksum_file"; then
            expected_hash=$(fn_extract_expected_hash "$checksum_lookup_name" "$checksum_file") || true
            if [[ -n "$expected_hash" ]]; then
                has_checksum=true
            else
                print_warning "Could not extract checksum. Will skip verification."
            fi
        else
            print_warning "Could not download checksum file. Will skip verification."
        fi
    else
        print_warning "No checksum URL configured for ${DISTRO_DISPLAY_NAMES[$distro]} ${version}. Skipping verification."
    fi

    # Check existing ISO — verify integrity if checksum available
    if [[ -f "$iso_path" ]]; then
        print_info "ISO file already exists at ${iso_path}"
        if [[ "$has_checksum" == true ]]; then
            print_info "Verifying existing ISO integrity..."
            if fn_verify_iso "$iso_path" "$expected_hash"; then
                print_info "Existing ISO is valid. Skipping download."
            else
                print_warning "Removing corrupt ISO and re-downloading..."
                sudo rm -f "$iso_path"
            fi
        else
            print_info "No checksum available to verify. Using existing ISO."
        fi
    fi

    # Download ISO if not present (or was removed due to corruption)
    if [[ ! -f "$iso_path" ]]; then
        # If ISO_URL is empty (RHEL manual placement), nothing to download
        if [[ -z "${iso_url:-}" ]]; then
            print_error "No ISO found and no download URL available."
            print_info "Please place the ISO at: ${iso_path}"
            exit 1
        fi

        fn_check_disk_space "$ISO_DIR" "$MIN_DISK_SPACE_GB"

        print_info "Downloading ${DISTRO_DISPLAY_NAMES[$distro]} ${version} ISO..."
        if ! wget --continue --output-document="$iso_path" "$iso_url"; then
            print_error "Failed to download ISO from ${iso_url}"
            print_info "Cleaning up partial download..."
            sudo rm -f "$iso_path"
            exit 1
        fi
        sudo chown "${mgmt_super_user}:${mgmt_super_user}" "$iso_path"
        print_success "Download complete."

        # Verify freshly downloaded ISO
        if [[ "$has_checksum" == true ]]; then
            if ! fn_verify_iso "$iso_path" "$expected_hash"; then
                print_error "Freshly downloaded ISO failed checksum verification!"
                print_info "Removing corrupt file. Please retry or download manually."
                sudo rm -f "$iso_path"
                exit 1
            fi
        else
            print_warning "Checksum verification skipped — no checksum available."
        fi
    fi

    # Create mount point
    print_task "Preparing mount point: ${mount_dir}"
    sudo mkdir -p "$mount_dir"
    # chown the distro parent dir and the version leaf dir
    # (mkdir -p creates intermediate dirs as root)
    sudo chown "${mgmt_super_user}:${mgmt_super_user}" "$(dirname "$mount_dir")" "$mount_dir"
    print_task_done

    # Add fstab entry
    local fstab_entry="${iso_path} ${mount_dir} iso9660 uid=${mgmt_super_user},gid=${mgmt_super_user} 0 0"
    if ! grep -qF "$fstab_entry" "$FSTAB"; then
        print_task "Adding mount entry to /etc/fstab..."
        if ! echo "$fstab_entry" | sudo tee -a "$FSTAB" >/dev/null; then
            print_task_fail
            print_error "Failed to add fstab entry. Cleaning up..."
            sudo rm -f "$iso_path"
            sudo rm -rf "$mount_dir"
            exit 1
        fi
        sudo systemctl daemon-reload
        print_task_done
    else
        print_info "fstab already contains ISO mount entry."
    fi

    # Mount ISO
    if ! mountpoint -q "$mount_dir"; then
        print_task "Mounting ISO to ${mount_dir}..."
        if ! sudo mount "$mount_dir" 2>/dev/null; then
            print_task_fail
            print_error "Failed to mount ISO at ${mount_dir}. Cleaning up..."
            sudo sed -i "\|${mount_dir}|d" "$FSTAB"
            sudo systemctl daemon-reload
            sudo rm -f "$iso_path"
            sudo rm -rf "$mount_dir"
            exit 1
        fi
        print_task_done
    else
        print_info "ISO already mounted."
    fi

    print_success "Setup complete for ${DISTRO_DISPLAY_NAMES[$distro]} ${version}."
}

# ====== CLEANUP ======

fn_cleanup_distro() {
    local distro="$1" version="$2"

    # Guard: refuse to clean up the distro that built the infra server
    local infra_distro="" infra_version=""
    if [[ -f /etc/environment ]]; then
        infra_distro=$(awk -F'"' '/^infra_server_distro=/{print $2}' /etc/environment)
        infra_version=$(awk -F'"' '/^infra_server_version=/{print $2}' /etc/environment)
    fi
    if [[ -n "$infra_distro" ]] && [[ "$distro" == "$infra_distro" ]] && [[ "$version" == "$infra_version" ]]; then
        print_error "${DISTRO_DISPLAY_NAMES[$distro]} ${version} is the distro used to build this infra server."
        print_error "Cleanup is blocked to prevent breaking the lab infrastructure."
        exit 1
    fi

    local iso_file="${ISO_FILENAMES[${distro}:${version}]:-}"
    if [[ -z "$iso_file" ]]; then
        print_error "No ISO filename configured for ${distro} ${version}."
        exit 1
    fi

    local iso_path="${ISO_DIR}/${iso_file}"
    local mount_dir="/tux2lab-data/os-repos/${distro}/${version}"

    if ! fn_is_distro_ready "$distro" "$version" && [[ ! -f "$iso_path" ]]; then
        print_info "Nothing to clean up for ${DISTRO_DISPLAY_NAMES[$distro]} ${version} (not set up)."
        exit 0
    fi

    print_warning "This will delete ISO and mount point for ${DISTRO_DISPLAY_NAMES[$distro]} ${version}."
    read -rp "Are you sure you want to continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_info "Cleanup aborted."
        exit 0
    fi

    # Identify loop device before unmounting (needed for cleanup after lazy unmount)
    local loop_dev=""
    if [[ -f "$iso_path" ]]; then
        loop_dev=$(losetup -j "$iso_path" 2>/dev/null | cut -d: -f1)
    fi

    # Unmount if mounted
    if [[ -d "$mount_dir" ]] && mountpoint -q "$mount_dir"; then
        print_task "Unmounting ${mount_dir}..."
        if sudo umount "$mount_dir" 2>/dev/null; then
            print_task_done
        else
            # Mount busy — flush NFS export cache to release kernel nfsd references
            print_task_skip
            print_warning "Mount busy. Flushing NFS export cache and retrying..."
            sudo exportfs -f 2>/dev/null || true
            sleep 1
            print_task "Unmounting ${mount_dir} (retry after NFS flush)..."
            if sudo umount "$mount_dir" 2>/dev/null; then
                print_task_done
            else
                # Last resort — lazy unmount detaches from namespace
                print_task_skip
                print_warning "Still busy. Falling back to lazy unmount..."
                print_task "Unmounting ${mount_dir} (lazy)..."
                if sudo umount -l "$mount_dir"; then
                    print_task_done
                else
                    print_task_fail
                    print_error "Failed to unmount ${mount_dir}. Please check if it's in use."
                    exit 1
                fi
            fi
        fi
    fi

    # Detach loop device to release ISO blocks
    if [[ -n "$loop_dev" ]] && [[ -b "$loop_dev" ]]; then
        print_task "Detaching loop device ${loop_dev}..."
        if sudo losetup -d "$loop_dev" 2>/dev/null; then
            print_task_done
        else
            print_task_skip
            print_warning "Loop device busy — space will be reclaimed after all references close."
        fi
    fi

    # Remove mount directory
    if [[ -d "$mount_dir" ]]; then
        sudo rm -rf "$mount_dir"
    fi

    # Remove ISO file
    if [[ -f "$iso_path" ]]; then
        print_task "Removing ISO file..."
        sudo rm -f "$iso_path"
        print_task_done
    fi

    # Clean fstab
    print_task "Cleaning /etc/fstab entries..."
    sudo sed -i "\|${distro}/${version}|d" "$FSTAB"
    sudo systemctl daemon-reexec
    print_task_done

    print_success "Cleanup complete for ${DISTRO_DISPLAY_NAMES[$distro]} ${version}."
    print_info "The local repo for this distro no longer exists. Any golden image built from it cannot be used to provision new VMs."
    print_info "To remove the golden image, run: tux2lab golden-image cleanup -f -d ${distro} -v ${version}"
}

# ====== ARG PARSING ======

if [[ $# -lt 1 ]]; then
    print_usage
    exit 1
fi

MODE="$1"
shift

case "$MODE" in
    -h|--help)
        print_usage
        exit 0
        ;;
    --list)
        fn_list_distros
        exit 0
        ;;
    --setup|--cleanup)
        ;;
    *)
        print_error "Invalid mode: ${MODE}"
        print_usage
        exit 1
        ;;
esac

# Parse distro and version from remaining args
DISTRO="${1:-}"
VERSION=""

if [[ -z "$DISTRO" ]]; then
    # Interactive mode — prompt for distro and version
    local_action="setup"
    [[ "$MODE" == "--cleanup" ]] && local_action="cleanup"
    fn_select_distro "$local_action"
    fn_select_version "$DISTRO"
else
    # Non-interactive mode — validate distro
    fn_validate_distro "$DISTRO"
    shift

    # Parse --version / -v
    if [[ $# -ge 2 && ( "$1" == "--version" || "$1" == "-v" ) ]]; then
        VERSION="$2"
        fn_validate_version "$DISTRO" "$VERSION"
    elif [[ $# -ge 1 ]]; then
        print_error "Unexpected parameter: $1"
        print_usage
        exit 1
    fi

    if [[ -z "$VERSION" ]]; then
        print_error "The --version option is required."
        print_info "Available versions for ${DISTRO}: ${DISTRO_AVAILABLE_VERSIONS[$DISTRO]}"
        exit 1
    fi
fi

# ====== DISPATCH ======

case "$MODE" in
    --setup)
        fn_setup_distro "$DISTRO" "$VERSION"
        ;;
    --cleanup)
        fn_cleanup_distro "$DISTRO" "$VERSION"
        ;;
esac
