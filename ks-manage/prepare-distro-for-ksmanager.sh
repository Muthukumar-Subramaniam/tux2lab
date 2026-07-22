#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name : prepare-distro-for-ksmanager.sh
# Description : Manage OS distribution ISOs for PXE provisioning
# Invoked by  : tux2lab distro {list|setup|cleanup} [distro] [--version ver]
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/ks-manage/distro-versions.conf


# ============================================================================
# GUEST VM DISTRO MANAGEMENT (setup/cleanup/list)
# Runs on the infra server — requires infra server environment variables.
# ============================================================================

# Source lab environment
if [[ -f /tux2lab-data/lab_environment_vars ]]; then
    source /tux2lab-data/lab_environment_vars
fi
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
readonly ISO_MOUNTS_CONF="/tux2lab-data/iso-mounts.conf"
readonly GOLDEN_IMAGE_DIR="/tux2lab-data/golden-images-disk-store"
readonly MIN_DISK_SPACE_RHEL_GB=5
readonly MIN_DISK_SPACE_OTHER_GB=5

# ====== DEPENDENCY CHECK ======
MISSING_COMMANDS=()
for cmd in curl mountpoint sed awk grep sha256sum; do
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
    almalinux, rocky, oraclelinux, centos-stream, rhel, ubuntu-lts, debian, opensuse-leap, azurelinux

Version:
    The actual version number, e.g. 9, 10, 22.04, 24.04, 26.04, 11, 12, 13, 15.5, 15.6, 4"
}

# ====== HELPER FUNCTIONS ======

fn_is_distro_ready() {
    local distro="$1" ver="$2"
    # Debian uses netboot-only (no ISO mount) — check for netboot files instead
    if [[ "$distro" == "debian" ]]; then
        [[ -f "/tux2lab-data/os-repos/${distro}/${ver}-netboot/vmlinuz" ]] && \
        [[ -f "/tux2lab-data/os-repos/${distro}/${ver}-netboot/initrd.gz" ]]
    else
        mountpoint -q "/tux2lab-data/os-repos/${distro}/${ver}" 2>/dev/null
    fi
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
        print_info "Available: ${available_gb} GiB, Minimum required: ${required_gb} GiB"
        exit 1
    fi
    print_info "Disk space check passed: ${available_gb} GiB available (minimum ${required_gb} GiB)"
}

fn_download_checksum() {
    local checksum_url="$1"
    local checksum_file="$2"

    print_task "Downloading CHECKSUM file..."
    rm -f "$checksum_file"
    if ! curl --silent --location --retry 3 --retry-delay 2 --output "$checksum_file" "$checksum_url"; then
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
    expected_hash=$(grep -i "SHA256" "$checksum_file" | grep -i "$iso_name" | awk -F'= ' '{print $2}' | tr -d '[:space:]') || true
    if [[ -z "$expected_hash" ]]; then
        # Fallback: "hash  filename" format (case-insensitive match)
        expected_hash=$(grep -i "$iso_name" "$checksum_file" | awk '{print $1}' | head -1 | tr -d '[:space:]') || true
    fi
    # Fallback for 'latest' symlinks: mirrors list the real dated filename
    # e.g., URL has "CentOS-Stream-10-latest-x86_64-boot.iso" but checksum has "CentOS-Stream-10-20260513.0-x86_64-boot.iso"
    if [[ -z "$expected_hash" && "$iso_name" == *"latest"* ]]; then
        local pattern="${iso_name//latest/[A-Za-z0-9][^ )]*}"
        expected_hash=$(grep -i "SHA256" "$checksum_file" | grep -E "$pattern" | awk -F'= ' '{print $2}' | tr -d '[:space:]' | head -1) || true
        if [[ -z "$expected_hash" ]]; then
            expected_hash=$(grep -E "$pattern" "$checksum_file" | awk '{print $1}' | head -1 | tr -d '[:space:]') || true
        fi
    fi
    if [[ -z "$expected_hash" ]]; then
        print_error "Could not find SHA256 checksum for ${iso_name} in CHECKSUM file." >&2
        print_info "The CHECKSUM file format may have changed. Please verify manually." >&2
        return 1
    fi
    echo "$expected_hash"
}

fn_verify_iso() {
    local iso_path="$1"
    local expected_hash="$2"

    # Detect hash algorithm from expected hash length
    local hash_cmd="sha256sum"
    local hash_name="SHA256"
    if [[ ${#expected_hash} -ge 128 ]]; then
        hash_cmd="sha512sum"
        hash_name="SHA512"
    fi

    print_info "Calculating ${hash_name} checksum (this may take a few minutes)..."
    local actual_hash
    actual_hash=$($hash_cmd "$iso_path" | awk '{print $1}')

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

    local first_group=true
    for distro in "${DISTRO_KEYS[@]}"; do
        # Add blank line separator between distro groups
        if [[ "$first_group" == true ]]; then
            first_group=false
        else
            echo
        fi
        local first_ver=true
        for ver in ${DISTRO_AVAILABLE_VERSIONS[$distro]}; do
            local pxe_padded pxe_status golden_status distro_label
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
            # Show distro name only on the first version row
            if [[ "$first_ver" == true ]]; then
                distro_label="${DISTRO_DISPLAY_NAMES[$distro]}"
                first_ver=false
            else
                distro_label=""
            fi
            printf "  %-${col_distro}s %-${col_ver}s %s %s\n" "$distro_label" "$ver" "$pxe_status" "$golden_status"
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
        print_info "  1. Log in at https://access.redhat.com/downloads/content/rhel"
        print_info "     (a free Red Hat Developer subscription is sufficient)"
        print_info "     Download the Boot ISO and place it at: ${iso_path}"
        print_info "  2. Paste a direct download URL below (from your Red Hat account)"
        echo
        read -rp "Paste direct ISO download URL, or press Enter if you placed the ISO manually: " iso_url
        if [[ -n "$iso_url" ]]; then
            # Validate the URL filename matches expected distro, version, and type
            local url_basename
            url_basename=$(basename "${iso_url%%\?*}")
            if [[ "$url_basename" != *boot* ]]; then
                print_error "The URL points to '${url_basename}' which is not a Boot ISO."
                print_info "A Boot ISO is required (filename must contain 'boot')."
                exit 1
            fi
            if [[ "$url_basename" != rhel-${version}* ]]; then
                print_error "The URL points to '${url_basename}' which does not match RHEL ${version}."
                print_info "You selected RHEL ${version}, but the URL points to a different version."
                print_info "Expected a filename starting with 'rhel-${version}' (e.g., rhel-${version}.1-x86_64-boot.iso)."
                exit 1
            fi
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
        print_error "No ISO URL configured for ${distro} ${version}." >&2
        exit 1
    fi

    # Ubuntu URLs point to a directory — resolve the actual ISO filename dynamically
    if [[ "$distro" == "ubuntu-lts" ]]; then
        local resolved_filename
        resolved_filename=$(curl -sL "$url" | grep -oP "ubuntu-${version}(\\.[0-9]+)?-live-server-amd64\\.iso" | sort -V | tail -1)
        if [[ -z "$resolved_filename" ]]; then
            print_error "Could not detect Ubuntu ${version} ISO filename from ${url}" >&2
            print_info "The Ubuntu releases page may be temporarily unavailable." >&2
            exit 1
        fi
        print_info "Resolved ISO filename: ${resolved_filename}" >&2
        echo "${url}${resolved_filename}"
        return
    fi

    echo "$url"
}

# Debian uses netboot-only PXE install — no ISO needed.
# The netboot kernel/initrd are downloaded from deb.debian.org and served locally via HTTP.
# Packages are installed from deb.debian.org during the PXE install (internet required).
fn_setup_debian_netboot() {
    local distro="$1" version="$2"
    local netboot_dir="/tux2lab-data/os-repos/${distro}/${version}-netboot"
    local debian_codename="${DEBIAN_CODENAMES[${version}]:-}"

    if [[ -z "$debian_codename" ]]; then
        print_error "No codename configured for Debian ${version}."
        exit 1
    fi

    local netboot_base="https://deb.debian.org/debian/dists/${debian_codename}/main/installer-amd64/current/images/netboot/debian-installer/amd64"

    print_task "Creating netboot directory..."
    sudo mkdir -p "$netboot_dir"
    print_task_done

    print_task "Downloading Debian ${version} (${debian_codename}) netboot kernel..."
    if sudo curl -fsSL "${netboot_base}/linux" -o "${netboot_dir}/vmlinuz"; then
        print_task_done
    else
        print_task_fail
        print_error "Failed to download netboot kernel for Debian ${version}."
        print_info "URL: ${netboot_base}/linux"
        sudo rm -rf "$netboot_dir"
        exit 1
    fi

    print_task "Downloading Debian ${version} (${debian_codename}) netboot initrd..."
    if sudo curl -fsSL "${netboot_base}/initrd.gz" -o "${netboot_dir}/initrd.gz"; then
        print_task_done
    else
        print_task_fail
        print_error "Failed to download netboot initrd for Debian ${version}."
        print_info "URL: ${netboot_base}/initrd.gz"
        sudo rm -rf "$netboot_dir"
        exit 1
    fi

    print_success "Debian ${version} (${debian_codename}) is ready for PXE provisioning."
    print_info "Netboot files: ${netboot_dir}"
    print_info "Packages will be installed from deb.debian.org during PXE install."
}

fn_setup_distro() {
    local distro="$1" version="$2"

    if fn_is_distro_ready "$distro" "$version"; then
        print_warning "Distro '${DISTRO_DISPLAY_NAMES[$distro]} ${version}' is already set up."
        print_info "To re-setup, run cleanup first: tux2lab distro cleanup ${distro} --version ${version}"
        exit 1
    fi

    # Debian uses netboot-only PXE install — no ISO needed
    if [[ "$distro" == "debian" ]]; then
        fn_setup_debian_netboot "$distro" "$version"
        return
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
    sudo chown "${mgmt_super_user}:$(id -g "${mgmt_super_user}")" "$ISO_DIR"
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
        if [[ -f "$checksum_file" ]] && [[ -f "$iso_path" ]]; then
            # Use existing local checksum for verification
            print_info "Using existing local CHECKSUM file for verification."
            expected_hash=$(fn_extract_expected_hash "$checksum_lookup_name" "$checksum_file") || true
            if [[ -n "$expected_hash" ]]; then
                has_checksum=true
            else
                print_warning "Could not extract checksum from local file. Re-downloading..."
                if fn_download_checksum "$checksum_url" "$checksum_file"; then
                    expected_hash=$(fn_extract_expected_hash "$checksum_lookup_name" "$checksum_file") || true
                    [[ -n "$expected_hash" ]] && has_checksum=true
                fi
            fi
        else
            # No local checksum file or no ISO — download fresh
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

        local min_space_gb="$MIN_DISK_SPACE_OTHER_GB"
        local d
        for d in "${RHEL_BASED_DISTROS[@]}"; do
            [[ "$d" == "$distro" ]] && { min_space_gb="$MIN_DISK_SPACE_RHEL_GB"; break; }
        done
        fn_check_disk_space "$ISO_DIR" "$min_space_gb"

        print_info "Downloading ${DISTRO_DISPLAY_NAMES[$distro]} ${version} Boot ISO..."
        if ! curl --location --continue-at - --retry 10 --retry-delay 3 --output "$iso_path" "$iso_url"; then
            print_error "Failed to download ISO from ${iso_url}"
            print_info "Cleaning up partial download..."
            sudo rm -f "$iso_path"
            exit 1
        fi

        # Sanity check: an ISO must be at least 100MB
        downloaded_size=$(stat --format='%s' "$iso_path" 2>/dev/null || echo 0)
        if (( downloaded_size < 104857600 )); then
            print_error "Downloaded file is only $(( downloaded_size / 1024 )) KB — clearly not a valid ISO."
            print_info "This usually means the URL requires authentication (e.g., Red Hat SSO)."
            print_info "Download the ISO from an authenticated session and place it at: ${iso_path}"
            sudo rm -f "$iso_path"
            exit 1
        fi

        sudo chown "${mgmt_super_user}:$(id -g "${mgmt_super_user}")" "$iso_path"
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
    sudo chown "${mgmt_super_user}:$(id -g "${mgmt_super_user}")" "$(dirname "$mount_dir")" "$mount_dir"
    print_task_done

    # Add entry to iso-mounts config
    local config_entry="${iso_file} ${distro} ${version}"
    if ! grep -qF "$config_entry" "$ISO_MOUNTS_CONF" 2>/dev/null; then
        print_task "Adding entry to iso-mounts config..."
        if ! echo "$config_entry" | sudo tee -a "$ISO_MOUNTS_CONF" >/dev/null; then
            print_task_fail
            print_error "Failed to add config entry. Cleaning up..."
            sudo rm -f "$iso_path"
            sudo rm -rf "$mount_dir"
            exit 1
        fi
        print_task_done
    else
        print_info "ISO already registered in iso-mounts config."
    fi

    # Mount ISO
    if ! mountpoint -q "$mount_dir"; then
        print_task "Mounting ISO to ${mount_dir}..."
        if ! sudo mount -o loop,ro "$iso_path" "$mount_dir" 2>/dev/null; then
            print_task_fail
            print_error "Failed to mount ISO at ${mount_dir}. Cleaning up..."
            sudo sed -i "\|${iso_file}.*${distro}.*${version}|d" "$ISO_MOUNTS_CONF"
            sudo rm -f "$iso_path"
            sudo rm -rf "$mount_dir"
            exit 1
        fi
        print_task_done
    else
        print_info "ISO already mounted."
    fi

    # Ensure the iso-mounts service is enabled
    if ! systemctl is-enabled tux2lab-iso-mounts.service &>/dev/null; then
        print_task "Enabling tux2lab-iso-mounts service..."
        sudo cp /tux2lab/common-utils/tux2lab-iso-mounts.service /etc/systemd/system/
        sudo chmod 644 /etc/systemd/system/tux2lab-iso-mounts.service
        sudo systemctl daemon-reload
        sudo systemctl enable tux2lab-iso-mounts.service &>/dev/null
        print_task_done
    fi

    # Azure Linux: patch squashfs to support HTTP kickstart URLs
    if [[ "$distro" == "azurelinux" ]]; then
        local patched_squashfs_dir="/tux2lab-data/os-repos/${distro}/${version}-live"
        local patched_squashfs="${patched_squashfs_dir}/squashfs.img"
        local original_squashfs="${mount_dir}/LiveOS/squashfs.img"

        if [[ -f "$patched_squashfs" ]]; then
            print_info "Patched squashfs already exists. Skipping."
        elif [[ ! -f "$original_squashfs" ]]; then
            print_warning "No LiveOS/squashfs.img found in ISO. Skipping squashfs patching."
        else
            local squash_tmp="/tmp/azl-squash-patch-$$"
            local rootfs_mnt="/tmp/azl-rootfs-$$"

            print_task "Extracting squashfs image..."
            if sudo unsquashfs -d "$squash_tmp" "$original_squashfs" >/dev/null 2>&1; then
                print_task_done
            else
                print_task_fail
                print_warning "Failed to unsquash. Ensure 'squashfs-tools' is installed."
                sudo rm -rf "$squash_tmp"
                return
            fi

            # The squashfs contains LiveOS/rootfs.img — mount it to patch files inside
            local rootfs_img="${squash_tmp}/LiveOS/rootfs.img"
            if sudo test -f "$rootfs_img"; then
                print_task "Mounting rootfs image for patching..."
                sudo mkdir -p "$rootfs_mnt"
                if sudo mount -o loop,rw "$rootfs_img" "$rootfs_mnt"; then
                    print_task_done

                    print_task "Patching installer for HTTP kickstart support..."
                    local install_script="${rootfs_mnt}/usr/local/bin/anaconda-launcher.sh"
                    if ! sudo test -f "$install_script"; then
                        install_script="${rootfs_mnt}/usr/local/sbin/install-azl"
                    fi
                    if sudo test -f "$install_script"; then
                        local patch_script="/tmp/azl-patch-$$.sh"
                        cat > "$patch_script" << 'PATCHEOF'
#!/bin/bash
TARGET="$1"
TMPFILE="${TARGET}.patched"
sudo awk '
/CUSTOM_KS=\$\(grep -o/ {
    print
    print "    # Support HTTP/HTTPS kickstart URLs for PXE-based deployments"
    print "    if [[ \"$CUSTOM_KS\" == http* ]]; then"
    print "        echo \"  Downloading kickstart from: $CUSTOM_KS\""
    print "        if curl --retry 10 --retry-delay 2 --retry-connrefused -sf -o /tmp/ks.cfg \"$CUSTOM_KS\"; then"
    print "            CUSTOM_KS=\"/tmp/ks.cfg\""
    print "        else"
    print "            echo \"  ERROR: Failed to download kickstart from $CUSTOM_KS\""
    print "            exec /bin/bash"
    print "        fi"
    print "    fi"
    next
}
{print}
' "$TARGET" | sudo tee "$TMPFILE" > /dev/null
sudo mv "$TMPFILE" "$TARGET"
sudo chmod +x "$TARGET"
PATCHEOF
                        chmod +x "$patch_script"
                        bash "$patch_script" "$install_script"
                        rm -f "$patch_script"
                        print_task_done
                    else
                        print_task_fail
                        print_warning "install-azl/anaconda-launcher.sh not found in rootfs."
                    fi

                    # Install xfsprogs into the live rootfs so Anaconda can create XFS filesystems
                    # Also add it to the offline repo so Anaconda can resolve the package dependency
                    print_task "Installing xfsprogs into live image for XFS support..."
                    local rpm_tmp="/tmp/azl-xfs-rpms-$$"
                    mkdir -p "$rpm_tmp"
                    # Determine repo channel (prod if available, else beta)
                    local azl_repo_base="https://packages.microsoft.com/azurelinux/4.0"
                    local azl_repo_url="${azl_repo_base}/prod/base/x86_64"
                    if ! curl -sf "${azl_repo_url}/repodata/repomd.xml" -o /dev/null 2>/dev/null; then
                        azl_repo_url="${azl_repo_base}/beta/base/x86_64"
                    fi
                    if sudo dnf download --destdir="$rpm_tmp" --repofrompath="azl-tmp,$azl_repo_url" --repo=azl-tmp xfsprogs inih userspace-rcu >/dev/null 2>&1; then
                        local xfs_ok=true
                        # Extract xfsprogs binaries into live rootfs (provides mkfs.xfs for formatting)
                        if ! (cd "$rootfs_mnt" && sudo rpm2cpio "$rpm_tmp"/xfsprogs-*.rpm | sudo cpio -idmu 2>/dev/null); then
                            xfs_ok=false
                        fi
                        # Add all RPMs (xfsprogs + deps) to offline repo so Anaconda can resolve them
                        local offline_repo="$rootfs_mnt/opt/azl-offline-repo"
                        if sudo test -d "$offline_repo"; then
                            sudo cp "$rpm_tmp"/*.rpm "$offline_repo/"
                            # Regenerate repo metadata
                            if sudo chroot "$rootfs_mnt" createrepo_c /opt/azl-offline-repo >/dev/null 2>&1 \
                               || sudo createrepo_c "$offline_repo" >/dev/null 2>&1; then
                                :
                            else
                                # Fallback: update repodata with modifyrepo or simple re-index
                                print_warning "Could not regenerate repo metadata. Trying rpm-based approach..."
                                sudo chroot "$rootfs_mnt" rpm -ivh --justdb /opt/azl-offline-repo/xfsprogs*.rpm 2>/dev/null || true
                            fi
                        else
                            xfs_ok=false
                            print_warning "Offline repo not found at /opt/azl-offline-repo/"
                        fi
                        if $xfs_ok; then
                            print_task_done
                        else
                            print_task_fail
                            print_warning "Failed to install xfsprogs RPMs. XFS will not be available during install."
                        fi
                    else
                        print_task_fail
                        print_warning "Failed to download xfsprogs. XFS will not be available during install."
                    fi
                    rm -rf "$rpm_tmp"

                    sudo umount "$rootfs_mnt"
                else
                    print_task_fail
                    print_warning "Failed to mount rootfs.img."
                fi
            fi

            print_task "Rebuilding patched squashfs (this may take a few minutes)..."
            sudo mkdir -p "$patched_squashfs_dir"
            if sudo mksquashfs "$squash_tmp" "$patched_squashfs" -noappend -comp zstd -quiet -no-progress; then
                sudo chown "${mgmt_super_user}:$(id -g "${mgmt_super_user}")" "$patched_squashfs_dir" "$patched_squashfs"
                print_task_done
            else
                print_task_fail
                print_warning "Failed to create patched squashfs. PXE kickstart automation will not work."
            fi

            sudo rm -rf "$squash_tmp" "$rootfs_mnt"
        fi
    fi

    print_success "Setup complete for ${DISTRO_DISPLAY_NAMES[$distro]} ${version}."
}

# ====== CLEANUP ======

fn_cleanup_distro() {
    local distro="$1" version="$2"

    # Debian uses netboot-only (no ISO) — just remove netboot files
    if [[ "$distro" == "debian" ]]; then
        local netboot_dir="/tux2lab-data/os-repos/${distro}/${version}-netboot"
        if [[ ! -d "$netboot_dir" ]]; then
            print_info "Nothing to clean up for ${DISTRO_DISPLAY_NAMES[$distro]} ${version} (not set up)."
            exit 0
        fi
        print_warning "This will remove netboot files for ${DISTRO_DISPLAY_NAMES[$distro]} ${version}."
        read -rp "Are you sure you want to continue? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            print_info "Cleanup aborted."
            exit 0
        fi
        print_task "Removing netboot files..."
        sudo rm -rf "$netboot_dir"
        print_task_done
        print_success "Cleanup complete for ${DISTRO_DISPLAY_NAMES[$distro]} ${version}."
        return
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

    # Remove patched squashfs (Azure Linux)
    local patched_squashfs_dir="/tux2lab-data/os-repos/${distro}/${version}-live"
    if [[ -d "$patched_squashfs_dir" ]]; then
        print_task "Removing patched squashfs..."
        sudo rm -rf "$patched_squashfs_dir"
        print_task_done
    fi

    # Remove ISO file
    if [[ -f "$iso_path" ]]; then
        print_task "Removing ISO file..."
        sudo rm -f "$iso_path"
        print_task_done
    fi

    # Remove checksum file
    local checksum_file="${ISO_DIR}/${distro}-${version}-CHECKSUM"
    if [[ -f "$checksum_file" ]]; then
        sudo rm -f "$checksum_file"
    fi

    # Clean iso-mounts config
    print_task "Removing entry from iso-mounts config..."
    sudo sed -i "\|${iso_file}.*${distro}.*${version}|d" "$ISO_MOUNTS_CONF" 2>/dev/null || true
    print_task_done

    print_success "Cleanup complete for ${DISTRO_DISPLAY_NAMES[$distro]} ${version}."
    print_info "The local repo for this distro no longer exists. Any golden image built from it cannot be used to provision new VMs."
    print_info "To remove the golden image, run: tux2lab golden-image cleanup ${distro} -v ${version} --force"
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

# Acquire per-distro-version singleton lock (fail-fast if another operation is running)
DISTRO_SETUP_LOCK_DIR="/tux2lab-data/.distro-setup-${DISTRO}-${VERSION//\./-}.lock"

if ! mkdir "${DISTRO_SETUP_LOCK_DIR}" 2>/dev/null; then
    if [[ -f "${DISTRO_SETUP_LOCK_DIR}/pid" ]]; then
        existing_pid=$(cat "${DISTRO_SETUP_LOCK_DIR}/pid" 2>/dev/null)
        if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
            print_error "Another distro operation for ${DISTRO_DISPLAY_NAMES[$DISTRO]} ${VERSION} is already in progress (PID ${existing_pid})."
            exit 1
        fi
        # Stale lock from a dead process — reclaim it
        rm -f "${DISTRO_SETUP_LOCK_DIR}/pid"
        rmdir "${DISTRO_SETUP_LOCK_DIR}" 2>/dev/null || true
    fi
    if ! mkdir "${DISTRO_SETUP_LOCK_DIR}" 2>/dev/null; then
        print_error "Cannot acquire distro setup lock. Please retry."
        exit 1
    fi
fi

printf '%s\n' "$$" > "${DISTRO_SETUP_LOCK_DIR}/pid"
fn_release_distro_setup_lock() {
    rm -f "${DISTRO_SETUP_LOCK_DIR}/pid" 2>/dev/null
    rmdir "${DISTRO_SETUP_LOCK_DIR}" 2>/dev/null || true
}
trap 'fn_release_distro_setup_lock' EXIT
trap 'fn_release_distro_setup_lock; trap - INT; kill -s INT $$' INT
trap 'fn_release_distro_setup_lock; trap - TERM; kill -s TERM $$' TERM

case "$MODE" in
    --setup)
        fn_setup_distro "$DISTRO" "$VERSION"
        ;;
    --cleanup)
        fn_cleanup_distro "$DISTRO" "$VERSION"
        ;;
esac
