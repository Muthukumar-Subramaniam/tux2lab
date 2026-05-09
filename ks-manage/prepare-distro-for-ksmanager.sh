#!/bin/bash
#----------------------------------------------------------------------------------------#
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues      #
#----------------------------------------------------------------------------------------#

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/ks-manage/distro-versions.conf

if [[ "$USER" != "$mgmt_super_user" ]]; then
	print_error "Access denied. Only infra management super user '${mgmt_super_user}' is authorized to run this tool."
	print_error "Also if the user itself is ${mgmt_super_user}, Please do not elevate access again with sudo.\n"
    	exit 1
fi

set -euo pipefail

: "${dnsbinder_server_fqdn:?Must set dnsbinder_server_fqdn}"
: "${mgmt_super_user:?Must set mgmt_super_user}"

# Validate required commands are installed
REQUIRED_COMMANDS=("wget" "curl" "mountpoint" "sed" "awk" "grep")
MISSING_COMMANDS=()

for cmd in "${REQUIRED_COMMANDS[@]}"; do
  if ! command -v "$cmd" &> /dev/null; then
    MISSING_COMMANDS+=("$cmd")
  fi
done

if [[ ${#MISSING_COMMANDS[@]} -gt 0 ]]; then
  print_error "Missing required commands: ${MISSING_COMMANDS[*]}"
  print_info "Please install the missing tools before running this script."
  exit 1
fi

ISO_DIR="/${dnsbinder_server_fqdn}/iso-files"
FSTAB="/etc/fstab"

print_usage() {
  print_info "Usage:
    $(basename $0) --setup <distro> [--version <version>]
    $(basename $0) --cleanup <distro> [--version <version>]

Supported distros:
    almalinux, rocky, oraclelinux, centos-stream, rhel, ubuntu-lts, opensuse-leap

Version (optional, defaults to newest available):
    The actual version number, e.g. 9, 10, 22.04, 24.04, 15.5, 15.6"
}

fn_is_distro_ready() {
  local os_distribution="$1"
  local ver="$2"
  local mount_dir="/${dnsbinder_server_fqdn}/${os_distribution}/${ver}"
  
  if mountpoint -q "$mount_dir"; then
    return 0  # Ready
  else
    return 1  # Not Ready
  fi
}

fn_get_distro_status_display() {
  local os_distribution="$1"
  local ver="$2"
  
  if fn_is_distro_ready "$os_distribution" "$ver"; then
    print_green "[Ready]" nskip
  else
    print_yellow "[Not-Ready]" nskip
  fi
}

fn_select_os_distro() {
  local action_title="$1"
  
  local -a distro_keys=("almalinux" "rocky" "oraclelinux" "centos-stream" "rhel" "ubuntu-lts" "opensuse-leap")
  
  local menu="Please select the OS distribution to ${action_title}:\n"
  for i in "${!distro_keys[@]}"; do
    local key="${distro_keys[$i]}"
    local name="${DISTRO_DISPLAY_NAMES[$key]}"
    local versions="${DISTRO_AVAILABLE_VERSIONS[$key]}"
    printf -v line "  %d)  %-32s (versions: %s)\n" $((i+1)) "${name}" "${versions}"
    menu+="${line}"
  done
  menu+="  q)  Quit"
  
  print_notify "$menu"
  echo -n "Enter option number: "
  read os_distribution
  case "$os_distribution" in
    1 ) DISTRO="almalinux" ;;
    2 ) DISTRO="rocky" ;;
    3 ) DISTRO="oraclelinux" ;;
    4 ) DISTRO="centos-stream" ;;
    5 ) DISTRO="rhel" ;;
    6 ) DISTRO="ubuntu-lts" ;;
    7 ) DISTRO="opensuse-leap" ;;
    q | Q ) print_notify "Exiting the utility $(basename $0) !\n"; exit 0 ;;
    * ) print_error "Invalid option! Please try again."; fn_select_os_distro "$action_title" ;;
  esac
}

fn_select_version() {
  local distro="$1"
  local available_versions=(${DISTRO_AVAILABLE_VERSIONS[$distro]})
  
  local menu="Please select the version for ${DISTRO_DISPLAY_NAMES[$distro]}:\n"
  for i in "${!available_versions[@]}"; do
    local ver="${available_versions[$i]}"
    local status=$(fn_get_distro_status_display "$distro" "$ver")
    printf -v line "  %d)  %-12s %s\n" $((i+1)) "${ver}" "${status}"
    menu+="${line}"
  done
  menu+="  q)  Quit"
  
  print_notify "$menu"
  echo -n "Enter option number: "
  read version_choice

  if [[ "${version_choice}" == "q" || "${version_choice}" == "Q" ]]; then
    print_notify "Exiting the utility $(basename $0) !\n"; exit 0
  elif [[ "${version_choice}" =~ ^[0-9]+$ ]] && (( version_choice >= 1 && version_choice <= ${#available_versions[@]} )); then
    VERSION="${available_versions[$((version_choice-1))]}"
  else
    print_error "Invalid option. Please try again."
    fn_select_version "$distro"
  fi
}

prepare_iso() {
  local distro="$1" iso_file="$2" iso_url="$3"
  local mount_dir="/${dnsbinder_server_fqdn}/${distro}/${VERSION}"
  local iso_path="${ISO_DIR}/${iso_file}"

  print_info "Ensuring ISO directory exists..."
  sudo mkdir -p "$ISO_DIR"
  sudo chown "${mgmt_super_user}:${mgmt_super_user}" "$ISO_DIR"

  if [[ -f "$iso_path" ]]; then
    print_info "ISO already exists: $iso_path\n"
  else
    print_info "Downloading ISO from $iso_url\n"
    if ! wget --continue --output-document="$iso_path" "$iso_url"; then
      print_error "Failed to download ISO from $iso_url"
      print_info "Cleaning up partial download..."
      sudo rm -f "$iso_path"
      exit 1
    fi
    sudo chown "${mgmt_super_user}:${mgmt_super_user}" "$iso_path"
    print_success "Download complete and ownership set.\n"
  fi

  print_info "Preparing mount point: $mount_dir"
  sudo mkdir -p "$mount_dir"
  sudo chown "${mgmt_super_user}:${mgmt_super_user}" "$mount_dir"
  local fstab_entry="$iso_path $mount_dir iso9660 uid=${mgmt_super_user},gid=${mgmt_super_user} 0 0"
  if ! grep -qF "$fstab_entry" "$FSTAB"; then
    print_info "Adding mount entry to /etc/fstab\n"
    if ! echo "$fstab_entry" | sudo tee -a "$FSTAB" > /dev/null; then
      print_error "Failed to add fstab entry"
      print_info "Cleaning up ISO file..."
      sudo rm -f "$iso_path"
      exit 1
    fi
    sudo systemctl daemon-reload
  else
    print_info "fstab already contains ISO mount entry.\n"
  fi

  if ! mountpoint -q "$mount_dir"; then
    print_info "Mounting ISO to $mount_dir\n"
    if ! sudo mount "$mount_dir"; then
      print_error "Failed to mount ISO at $mount_dir"
      print_info "Cleaning up..."
      sudo sed -i "\|${mount_dir}|d" "$FSTAB"
      sudo systemctl daemon-reload
      sudo rm -f "$iso_path"
      sudo rm -rf "$mount_dir"
      exit 1
    fi
    print_success "ISO mounted.\n"
  else
    print_info "ISO already mounted.\n"
  fi

  print_success "All done for $distro ${VERSION}.\n"
}

prepare_rhel() {
  local distro="rhel"
  
  print_info "Login from a browser with your Red Hat Developer Subscription!"
  read -rp "Enter the link to download RHEL ${VERSION} ISO : " iso_url

  prepare_iso "$distro" "${ISO_FILENAMES[rhel:${VERSION}]}" "$iso_url"
}

prepare_ubuntu() {
  local distro="ubuntu-lts"
  prepare_iso "$distro" "${ISO_FILENAMES[ubuntu-lts:${VERSION}]}" "${ISO_URLS[ubuntu-lts:${VERSION}]}"
}

prepare_oraclelinux() {
  local distro="oraclelinux"
  prepare_iso "$distro" "${ISO_FILENAMES[oraclelinux:${VERSION}]}" "${ISO_URLS[oraclelinux:${VERSION}]}"
}

cleanup_distro() {
  local distro="$1"
  local iso_file="$2"
  local iso_path="${ISO_DIR}/${iso_file}"
  local mount_dir="/${dnsbinder_server_fqdn}/${distro}/${VERSION}"

  print_warning "This will delete ISO and mount point for $distro ${VERSION}."
  read -p "Are you sure you want to continue? (yes/no): " confirm
  if [[ "$confirm" != "yes" ]]; then
    print_error "Cleanup aborted."
    exit 1
  fi

  sudo rm -f $iso_path

  if [[ -n "$mount_dir" && -d "$mount_dir" ]]; then
    if mountpoint -q "$mount_dir"; then
      print_task "Unmounting $mount_dir..."
      if sudo umount "$mount_dir"; then
        print_task_done
      else
        print_task_fail
        print_error "Failed to unmount $mount_dir. Please check if it's in use."
        exit 1
      fi
    fi
    sudo rm -rf "$mount_dir"
  fi

  print_info "Cleaning up /etc/fstab entries for '${distro}/${VERSION}'"
  sudo sed -i "\|${distro}/${VERSION}|d" "$FSTAB"
  sudo systemctl daemon-reexec

  print_success "Cleanup completed for $distro ${VERSION}.\n"
}

# Menu mode when no args
if [[ $# -lt 1 ]]; then
  print_info "No arguments provided. Launching interactive mode.
What would you like to do?
  1) Setup Distro
  2) Cleanup Distro
  q) Quit"
  echo -n "Enter option (default: 1): "
  read action
  case "$action" in
    1 | "" ) MODE="--setup" ; MENU_TITLE="setup" ;;
    2 ) MODE="--cleanup" ; MENU_TITLE="cleanup" ;;
    q | Q ) print_notify "Exiting the utility $(basename $0) !\n"; exit 0 ;;
    * ) print_error "Invalid choice. Exiting."; exit 1 ;;
  esac
  
  fn_select_os_distro "$MENU_TITLE"
  fn_select_version "$DISTRO"
else
  MODE="$1"
  DISTRO="${2:-}"

  if [[ "$MODE" == "-h" || "$MODE" == "--help" ]]; then
    print_usage
    exit 0
  fi

  if [[ "$MODE" != "--setup" && "$MODE" != "--cleanup" ]]; then
    print_error "Invalid mode: $MODE"
    print_usage
    exit 1
  fi

  if [[ -z "$DISTRO" ]]; then
    print_error "Missing distro argument for $MODE."
    print_usage
    exit 1
  fi

  # Parse --version parameter (optional, defaults to newest)
  VERSION=""
  if [[ $# -ge 3 ]]; then
    if [[ "$3" == "--version" && -n "${4:-}" ]]; then
      VERSION="$4"
      if ! fn_is_valid_version "$DISTRO" "$VERSION"; then
        print_error "Invalid version '${VERSION}' for ${DISTRO}."
        print_info "Available versions: ${DISTRO_AVAILABLE_VERSIONS[$DISTRO]}"
        exit 1
      fi
    else
      print_error "Invalid parameter: $3"
      print_usage
      exit 1
    fi
  fi

  # Require explicit version when using non-interactive mode
  if [[ -z "$VERSION" ]]; then
    print_error "The --version option is required when --distro is specified."
    print_info "Available versions for ${DISTRO}: ${DISTRO_AVAILABLE_VERSIONS[$DISTRO]}"
    print_usage
    exit 1
  fi
fi

# Main logic
case "$MODE" in
  --setup)
    if fn_is_distro_ready "$DISTRO" "$VERSION"; then
      print_warning "Distro '${DISTRO} ${VERSION}' already appears to be prepared."
      print_info "Please cleanup first using: $(basename $0) --cleanup ${DISTRO} --version ${VERSION}"
      exit 1
    fi

    case "$DISTRO" in
      almalinux)
        prepare_iso "almalinux" "${ISO_FILENAMES[almalinux:${VERSION}]}" \
          "${ISO_URLS[almalinux:${VERSION}]}"
        ;;
      rocky)
        prepare_iso "rocky" "${ISO_FILENAMES[rocky:${VERSION}]}" \
          "${ISO_URLS[rocky:${VERSION}]}"
        ;;
      oraclelinux)
        prepare_oraclelinux
        ;;
      centos-stream)
        prepare_iso "centos-stream" "${ISO_FILENAMES[centos-stream:${VERSION}]}" \
          "${ISO_URLS[centos-stream:${VERSION}]}"
        ;;
      rhel)
        prepare_rhel
        ;;
      ubuntu-lts)
        prepare_ubuntu
        ;;
      opensuse-leap)
        prepare_iso "opensuse-leap" "${ISO_FILENAMES[opensuse-leap:${VERSION}]}" \
          "${ISO_URLS[opensuse-leap:${VERSION}]}"
        ;;
      *)
        print_error "Unknown distro: $DISTRO"
        exit 1
        ;;
    esac
    ;;
  --cleanup)
    case "$DISTRO" in
      almalinux)       cleanup_distro "almalinux" "${ISO_FILENAMES[almalinux:${VERSION}]}" ;;
      rocky)           cleanup_distro "rocky" "${ISO_FILENAMES[rocky:${VERSION}]}" ;;
      oraclelinux)     cleanup_distro "oraclelinux" "${ISO_FILENAMES[oraclelinux:${VERSION}]}" ;;
      centos-stream)   cleanup_distro "centos-stream" "${ISO_FILENAMES[centos-stream:${VERSION}]}" ;;
      rhel)            cleanup_distro "rhel" "${ISO_FILENAMES[rhel:${VERSION}]}" ;;
      ubuntu-lts)      cleanup_distro "ubuntu-lts" "${ISO_FILENAMES[ubuntu-lts:${VERSION}]}" ;;
      opensuse-leap)   cleanup_distro "opensuse-leap" "${ISO_FILENAMES[opensuse-leap:${VERSION}]}" ;;
      *)
        print_error "Unknown distro: $DISTRO"
        exit 1
        ;;
    esac
    ;;
  *)
    print_usage
    exit 1
    ;;
esac
