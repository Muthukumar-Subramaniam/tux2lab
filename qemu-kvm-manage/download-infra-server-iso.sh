#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/ks-manage/distro-versions.conf
set -euo pipefail

# --- Constants ---
readonly ISO_DIR="/tux2lab-data/iso-files"
readonly INFRA_ISO_MARKER="${ISO_DIR}/infra-server-iso"
readonly INFRA_DISTRO_MARKER="${ISO_DIR}/infra-server-distro"
readonly MIN_DISK_SPACE_GB=12
readonly DEFAULT_DISTRO="almalinux"
# INFRA_SERVER_VERSION is defined in distro-versions.conf

# --- Pre-flight checks ---
if [[ "$EUID" -eq 0 ]]; then
    print_error "Running as root user is not allowed."
    print_info "This script should be run as a user with sudo privileges, not as root."
    exit 1
fi

for cmd in wget sha256sum awk grep; do
    if ! command -v "$cmd" &>/dev/null; then
        print_error "Required command '$cmd' not found. Please install it first."
        exit 1
    fi
done

# --- Usage ---
fn_show_usage() {
    print_cyan "Usage: $(basename "$0") [distro]

Download and verify version ${INFRA_SERVER_VERSION} ISO for the lab infra server.

Supported distros (RHEL-based only):
  almalinux        AlmaLinux (default)
  rocky            Rocky Linux
  oraclelinux      Oracle Linux
  centos-stream    CentOS Stream
  rhel             Red Hat Enterprise Linux

Options:
  -h, --help       Show this help message

Examples:
  $(basename "$0")              # Download AlmaLinux ${INFRA_SERVER_VERSION}
  $(basename "$0") rocky        # Download Rocky Linux ${INFRA_SERVER_VERSION}

Note: This RHEL-based restriction applies only to the lab infra server VM.
      Guest VM deployments also support Ubuntu Server LTS and openSUSE Leap.
"
}

# --- Helper functions ---
fn_is_rhel_based() {
    local distro="$1"
    local d
    for d in "${RHEL_BASED_DISTROS[@]}"; do
        [[ "$d" == "$distro" ]] && return 0
    done
    return 1
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
    # Fallback for 'latest' symlinks: mirrors list the real dated filename
    # e.g., URL has "CentOS-Stream-10-latest-x86_64-dvd1.iso" but checksum has "CentOS-Stream-10-20260513.0-x86_64-dvd1.iso"
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

# --- Parse arguments ---
distro=""
readonly version="${INFRA_SERVER_VERSION}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            fn_show_usage
            exit 0
            ;;
        -*)
            print_error "Unknown option: $1"
            fn_show_usage
            exit 1
            ;;
        *)
            distro="$1"
            shift
            ;;
    esac
done

# --- Prompt for distro if not provided on command line ---
if [[ -z "$distro" ]]; then
    print_cyan "
Available RHEL-based distros for the infra server (version ${version}):

  1) almalinux       - AlmaLinux
  2) rocky           - Rocky Linux
  3) oraclelinux     - Oracle Linux
  4) centos-stream   - CentOS Stream
  5) rhel            - Red Hat Enterprise Linux

Note: This applies only to the infra server ISO.
Guest VMs also support Debian-based (Ubuntu) and SUSE-based (openSUSE) via 'tux2lab distro'.
"
    read -rp "Select distro [1-5] [ default: AlmaLinux ${version} ]: " distro_input
    case "${distro_input}" in
        1|"") distro="almalinux" ;;
        2)    distro="rocky" ;;
        3)    distro="oraclelinux" ;;
        4)    distro="centos-stream" ;;
        5)    distro="rhel" ;;
        *)
            # Allow typing the distro name directly
            distro="${distro_input}"
            ;;
    esac
fi

# --- Validate distro ---
if ! fn_is_rhel_based "$distro"; then
    print_error "Unsupported distro: ${distro}"
    print_info "Only RHEL-based distros are supported for the infra server: ${RHEL_BASED_DISTROS[*]}"
    exit 1
fi

# --- Guard rail: warn if lab is already deployed ---
if [[ -f "/tux2lab-data/lab_environment_vars" ]]; then
    current_distro=""
    if [[ -f "$INFRA_DISTRO_MARKER" ]]; then
        current_distro=$(cat "$INFRA_DISTRO_MARKER")
    fi
    print_warning "A lab is already deployed."
    if [[ -n "$current_distro" && "$current_distro" != "$distro" ]]; then
        print_warning "Current infra server distro: ${current_distro}"
        print_warning "You are downloading: ${distro}"
        print_warning "Changing the ISO distro will affect the next rebuild/redeploy."
    fi
    read -rp "Continue downloading? [yes/NO]: " continue_choice
    if [[ "${continue_choice}" != "yes" ]]; then
        print_info "Download cancelled."
        exit 0
    fi
fi

# --- Resolve config from distro-versions.conf ---
distro_key="${distro}:${version}"
ISO_NAME="${ISO_FILENAMES[$distro_key]:-}"
ISO_URL="${ISO_URLS[$distro_key]:-}"
CHECKSUM_URL="${CHECKSUM_URLS[$distro_key]:-}"

if [[ -z "$ISO_NAME" ]]; then
    print_error "No ISO configuration found for ${DISTRO_DISPLAY_NAMES[$distro]} ${version}."
    exit 1
fi

if [[ -z "$ISO_URL" && "$distro" != "rhel" ]]; then
    print_error "No download URL configured for ${DISTRO_DISPLAY_NAMES[$distro]} ${version}."
    exit 1
fi

readonly ISO_PATH="${ISO_DIR}/${ISO_NAME}"
readonly CHECKSUM_FILE="${ISO_DIR}/${distro}-${version}-CHECKSUM"

print_info "Preparing to download ${DISTRO_DISPLAY_NAMES[$distro]} ${version} ISO"
print_info "ISO: ${ISO_NAME}"

# --- RHEL special handling ---
if [[ "$distro" == "rhel" ]]; then
    print_warning "Red Hat Enterprise Linux requires an active subscription to download."
    print_info "RHEL ISOs are not publicly downloadable. You have two options:"
    print_info "  1. Manually download the ISO from https://developers.redhat.com/products/rhel/download"
    print_info "     and place it at: ${ISO_DIR}/${ISO_NAME}"
    print_info "  2. Paste a direct download URL below (from your Red Hat account)"
    echo
    read -rp "Paste direct ISO download URL, or press Enter if you placed the ISO manually: " user_url
    if [[ -n "$user_url" ]]; then
        ISO_URL="$user_url"
    elif [[ -f "${ISO_DIR}/${ISO_NAME}" ]]; then
        print_success "Found manually placed ISO: ${ISO_DIR}/${ISO_NAME}"
        ISO_URL=""
    else
        print_error "No ISO found at ${ISO_DIR}/${ISO_NAME} and no download URL provided."
        print_info "Please download the RHEL ISO manually and place it in ${ISO_DIR}/"
        exit 1
    fi
fi

# --- Main ---
sudo mkdir -p "${ISO_DIR}"
sudo chown -R "$USER":"$(id -g)" "${ISO_DIR}"

# Download and verify checksum if available
has_checksum=false
# Use the real filename from the download URL for checksum lookup
# (e.g., OracleLinux-R10-U1-x86_64-dvd.iso vs the generic ISO_FILENAMES "latest" entry)
local_checksum_lookup_name="$ISO_NAME"
if [[ -n "${ISO_URL:-}" ]]; then
    local_checksum_lookup_name=$(basename "$ISO_URL")
fi

if [[ -n "$CHECKSUM_URL" ]]; then
    if fn_download_checksum "$CHECKSUM_URL" "$CHECKSUM_FILE"; then
        EXPECTED_HASH=$(fn_extract_expected_hash "$local_checksum_lookup_name" "$CHECKSUM_FILE") || true
        if [[ -n "${EXPECTED_HASH:-}" ]]; then
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

# Check existing ISO
if [[ -f "$ISO_PATH" ]]; then
    print_info "ISO file already exists at ${ISO_PATH}"
    if [[ "$has_checksum" == true ]]; then
        print_info "Verifying existing ISO integrity..."
        if fn_verify_iso "$ISO_PATH" "$EXPECTED_HASH"; then
            echo "$ISO_NAME" > "$INFRA_ISO_MARKER"
            echo "$distro" > "$INFRA_DISTRO_MARKER"
            exit 0
        fi
        print_warning "Removing corrupt ISO and re-downloading..."
        rm -f "$ISO_PATH"
    else
        print_info "No checksum available to verify. Using existing ISO."
        echo "$ISO_NAME" > "$INFRA_ISO_MARKER"
        echo "$distro" > "$INFRA_DISTRO_MARKER"
        exit 0
    fi
fi

# If ISO_URL is empty (RHEL manual placement), nothing to download
if [[ -z "${ISO_URL:-}" ]]; then
    print_error "No ISO found and no download URL available."
    print_info "Please place the ISO at: ${ISO_PATH}"
    exit 1
fi

# Check disk space before downloading
fn_check_disk_space "${ISO_DIR}" "${MIN_DISK_SPACE_GB}"

print_info "Downloading ${DISTRO_DISPLAY_NAMES[$distro]} ${version} ISO..."
if ! wget --continue --output-document="$ISO_PATH" "$ISO_URL"; then
    print_error "Failed to download ISO from ${ISO_URL}"
    rm -f "$ISO_PATH"
    exit 1
fi

print_success "ISO downloaded successfully!"
print_info "ISO File Path: ${ISO_PATH}"

# Verify freshly downloaded ISO
if [[ "$has_checksum" == true ]]; then
    if ! fn_verify_iso "$ISO_PATH" "$EXPECTED_HASH"; then
        print_error "Freshly downloaded ISO failed checksum verification!"
        print_info "Removing corrupt file. Please retry or download manually."
        rm -f "$ISO_PATH"
        exit 1
    fi
else
    print_warning "Checksum verification skipped — no checksum available."
fi

# Record the selected ISO and distro for deploy script
echo "$ISO_NAME" > "$INFRA_ISO_MARKER"
echo "$distro" > "$INFRA_DISTRO_MARKER"
print_info "Infra server ISO set to: ${ISO_NAME} (${distro} ${version})"
