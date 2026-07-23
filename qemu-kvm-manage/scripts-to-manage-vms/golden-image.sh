#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: golden-image.sh                                                           #
# Description: Manage golden image disks for OS provisioning                             #
# Invoked by : tux2lab golden-image {build|rebuild|list|cleanup}                         #
# If you encounter any issues with this script, or have suggestions or feature requests, #
# please open an issue at: https://github.com/Muthukumar-Subramaniam/tux2lab/issues   #
#----------------------------------------------------------------------------------------#
set -euo pipefail

source /tux2lab/common-utils/color-functions.sh
source /tux2lab/qemu-kvm-manage/scripts-to-manage-vms/functions/defaults.sh
source /tux2lab/ks-manage/distro-versions.conf

readonly GOLDEN_IMAGE_DIR="/tux2lab-data/golden-images-disk-store"
readonly SCRIPT_DIR="/tux2lab/qemu-kvm-manage/scripts-to-manage-vms"

show_golden_image_help() {
    print_cyan "USAGE:
    tux2lab golden-image <subcommand> [options]

SUBCOMMANDS:
    build [distro] [OPTIONS]    Build a golden image by installing a VM via PXE boot
    rebuild [distro] [OPTIONS]  Remove and rebuild an existing golden image
    list                        List all available golden images
    cleanup [distro] [OPTIONS]  Remove golden image(s)

BUILD/REBUILD/CLEANUP OPTIONS:
    -v, --version <ver>     Specify OS version number

CLEANUP OPTIONS:
    -f, --force             Skip confirmation prompt

OPTIONS:
    -h, --help              Show this help message

EXAMPLES:
    tux2lab golden-image list
    tux2lab golden-image build                             # Interactive mode
    tux2lab golden-image build almalinux --version 10      # Non-interactive mode
    tux2lab golden-image build almalinux -v 10             # Short form
    tux2lab golden-image rebuild almalinux -v 9            # Rebuild existing golden image
    tux2lab golden-image cleanup                            # Interactive cleanup
    tux2lab golden-image cleanup almalinux --version 10    # Remove specific golden image
    tux2lab golden-image cleanup rocky -v 9 --force        # Remove without confirmation"
}

# ====== LIST ======

show_list_help() {
    print_cyan "Usage: tux2lab golden-image list

List all available golden images with their distro, version, size, and creation date.

Options:
    -h, --help           Show this help message

This command takes no other arguments.
"
}

golden_image_list() {
    if [[ ! -d "$GOLDEN_IMAGE_DIR" ]] || ! ls "${GOLDEN_IMAGE_DIR}"/*.qcow2 &>/dev/null; then
        print_info "No golden images found."
        print_info "Create one with: tux2lab golden-image build"
        return 0
    fi

    printf "\n  %-28s %-12s %-22s %-30s\n" "DISTRO" "VERSION" "SIZE (DISK / VIRTUAL)" "CREATED"
    printf "  %-28s %-12s %-22s %-30s\n" "------" "-------" "---------------------" "-------"

    for qcow2_file in "${GOLDEN_IMAGE_DIR}"/*.qcow2; do
        local filename
        filename=$(basename "$qcow2_file" .qcow2)

        # Parse: {distro}-{version}-golden-image.{domain}
        # Extract distro and version by matching against known distro keys
        local prefix distro version
        prefix="${filename%%-golden-image.*}"
        distro="$prefix"
        version="unknown"
        for known_distro in "${!DISTRO_DISPLAY_NAMES[@]}"; do
            if [[ "$prefix" == "${known_distro}-"* ]]; then
                distro="$known_distro"
                local version_raw="${prefix#${known_distro}-}"
                version="${version_raw//-/.}"
                break
            fi
        done

        local display_name="${DISTRO_DISPLAY_NAMES[$distro]:-$distro}"
        local disk_size virtual_size size
        disk_size=$(sudo qemu-img info "$qcow2_file" 2>/dev/null | awk '/^disk size:/ {print $3, $4; exit}' || true)
        disk_size="${disk_size:-?}"
        virtual_size=$(sudo qemu-img info "$qcow2_file" 2>/dev/null | awk '/^virtual size:/ {print $3, $4; exit}' || true)
        virtual_size="${virtual_size:-?}"
        size="${disk_size} / ${virtual_size}"
        local created
        created=$(stat -c '%y' "$qcow2_file" 2>/dev/null | cut -d'.' -f1)
        created="${created:-unknown}"

        printf "  %-28s %-12s %-22s %-30s\n" "$display_name" "$version" "$size" "$created"
    done
    echo
}

# ====== CLEANUP ======

show_cleanup_help() {
    print_cyan "Usage: tux2lab golden-image cleanup [distro] [OPTIONS]
Description:
    Remove golden image disk(s) from the golden images disk store.
    Run without options for an interactive menu.

Options:
    -v, --version <ver>     Specify OS version number to remove
    -f, --force             Skip confirmation prompt
    -h, --help              Show this help message

Examples:
    tux2lab golden-image cleanup                            # Interactive cleanup
    tux2lab golden-image cleanup almalinux --version 10     # Remove specific golden image
    tux2lab golden-image cleanup rocky -v 9 --force         # Remove without confirmation
"
}

golden_image_cleanup() {
    local cleanup_distro=""
    local cleanup_version=""
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--version)
                if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                    print_error "--version/-v requires a version number."
                    show_cleanup_help
                    exit 1
                fi
                cleanup_version="$2"
                shift 2
                ;;
            -f|--force)
                force=true
                shift
                ;;
            -h|--help)
                show_cleanup_help
                exit 0
                ;;
            -*)
                print_error "Unknown option: $1"
                show_cleanup_help
                exit 1
                ;;
            *)
                if [[ -z "$cleanup_distro" ]]; then
                    cleanup_distro="$1"
                else
                    print_error "Unexpected argument: $1"
                    show_cleanup_help
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate distro and version early before checking the store
    if [[ -n "$cleanup_distro" ]]; then
        if [[ -z "${DISTRO_DISPLAY_NAMES[$cleanup_distro]:-}" ]]; then
            print_error "Unknown distribution: $cleanup_distro"
            print_info "Supported: almalinux, rocky, oraclelinux, centos-stream, rhel, ubuntu-lts, debian, opensuse-leap"
            exit 1
        fi
        if [[ -z "$cleanup_version" ]]; then
            print_error "--version/-v is required when --distro/-d is specified."
            exit 1
        fi
        local valid_versions="${DISTRO_AVAILABLE_VERSIONS[$cleanup_distro]}"
        local ver_found=false
        for v in $valid_versions; do
            if [[ "$v" == "$cleanup_version" ]]; then
                ver_found=true
                break
            fi
        done
        if [[ "$ver_found" != true ]]; then
            print_error "Invalid version '$cleanup_version' for ${DISTRO_DISPLAY_NAMES[$cleanup_distro]}."
            print_info "Available versions: $valid_versions"
            exit 1
        fi
    fi

    if [[ ! -d "$GOLDEN_IMAGE_DIR" ]] || ! ls "${GOLDEN_IMAGE_DIR}"/*.qcow2 &>/dev/null; then
        print_info "No golden images found. Nothing to clean up."
        return 0
    fi

    # Non-interactive mode: -d and -v specified
    if [[ -n "$cleanup_distro" ]]; then
        local version_dashed="${cleanup_version//./-}"
        local pattern="${GOLDEN_IMAGE_DIR}/${cleanup_distro}-${version_dashed}-golden-image.*.qcow2"
        local -a matched_files=()
        for f in $pattern; do
            [[ -e "$f" ]] && matched_files+=("$f")
        done
        if [[ ${#matched_files[@]} -eq 0 ]]; then
            print_error "No golden image found for ${DISTRO_DISPLAY_NAMES[$cleanup_distro]} ${cleanup_version}"
            exit 1
        fi
        local -a files_to_remove=("${matched_files[@]}")
        if [[ "$force" != true ]]; then
            print_warning "The following golden image(s) will be permanently deleted:"
            for f in "${files_to_remove[@]}"; do
                print_info "  $(basename "$f")"
            done
            echo -n "Type YES to confirm deletion: "
            read -r confirm
            if [[ "$confirm" != "YES" ]]; then
                print_info "Operation cancelled."
                exit 0
            fi
        fi
        for f in "${files_to_remove[@]}"; do
            local base
            base=$(basename "$f" .qcow2)
            print_task "Removing ${base}..."
            sudo rm -f "$f"
            sudo rm -f "${GOLDEN_IMAGE_DIR}/${base}_VARS.fd"
            print_task_done
        done
        print_success "Golden image cleanup complete."
        return 0
    fi

    # Interactive mode
    local -a image_files=()
    local -a image_labels=()
    for qcow2_file in "${GOLDEN_IMAGE_DIR}"/*.qcow2; do
        local filename
        filename=$(basename "$qcow2_file" .qcow2)
        local prefix distro version
        prefix="${filename%%-golden-image.*}"
        distro="$prefix"
        version="unknown"
        for known_distro in "${!DISTRO_DISPLAY_NAMES[@]}"; do
            if [[ "$prefix" == "${known_distro}-"* ]]; then
                distro="$known_distro"
                local version_raw="${prefix#${known_distro}-}"
                version="${version_raw//-/.}"
                break
            fi
        done
        local display_name="${DISTRO_DISPLAY_NAMES[$distro]:-$distro}"

        image_files+=("$qcow2_file")
        image_labels+=("${display_name} ${version}")
    done

    local menu="Select golden image to remove:\n"
    for i in "${!image_labels[@]}"; do
        printf -v line "  %d)  %s\n" $((i+1)) "${image_labels[$i]}"
        menu+="${line}"
    done
    menu+="  a)  All golden images\n"
    menu+="  q)  Quit"

    print_notify "$menu"
    echo -n "Enter option number: "
    read -r choice

    if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
        print_info "Operation cancelled by user."
        exit 0
    fi

    local -a files_to_remove=()
    if [[ "$choice" == "a" || "$choice" == "A" ]]; then
        files_to_remove=("${image_files[@]}")
    elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#image_files[@]} )); then
        files_to_remove=("${image_files[$((choice-1))]}")
    else
        print_error "Invalid option."
        exit 1
    fi

    # Confirmation (unless -f)
    if [[ "$force" != true ]]; then
        print_warning "The following golden image(s) will be permanently deleted:"
        for f in "${files_to_remove[@]}"; do
            print_info "  $(basename "$f")"
        done
        echo -n "Type YES to confirm deletion: "
        read -r confirm
        if [[ "$confirm" != "YES" ]]; then
            print_info "Operation cancelled."
            exit 0
        fi
    fi

    for f in "${files_to_remove[@]}"; do
        local base
        base=$(basename "$f" .qcow2)
        print_task "Removing ${base}..."
        sudo rm -f "$f"
        sudo rm -f "${GOLDEN_IMAGE_DIR}/${base}_VARS.fd"
        print_task_done
    done

    print_success "Golden image cleanup complete."
}

# ====== REBUILD ======

show_rebuild_help() {
    print_cyan "Usage: tux2lab golden-image rebuild [distro] [OPTIONS]
Description:
    Remove an existing golden image and rebuild it from scratch.
    Equivalent to running cleanup --force followed by build.

Options:
    -v, --version <ver>     Specify OS version number
    -h, --help              Show this help message

Examples:
    tux2lab golden-image rebuild                           # Interactive (pick from existing images)
    tux2lab golden-image rebuild almalinux --version 9     # Rebuild specific golden image
    tux2lab golden-image rebuild rocky -v 10               # Short form
"
}

golden_image_rebuild() {
    local rebuild_distro=""
    local rebuild_version=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--version)
                if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                    print_error "--version/-v requires a version number."
                    show_rebuild_help
                    exit 1
                fi
                rebuild_version="$2"
                shift 2
                ;;
            -h|--help)
                show_rebuild_help
                exit 0
                ;;
            -*)
                print_error "Unknown option: $1"
                show_rebuild_help
                exit 1
                ;;
            *)
                if [[ -z "$rebuild_distro" ]]; then
                    rebuild_distro="$1"
                else
                    print_error "Unexpected argument: $1"
                    show_rebuild_help
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Non-interactive mode: distro and version specified
    if [[ -n "$rebuild_distro" ]]; then
        if [[ -z "${DISTRO_DISPLAY_NAMES[$rebuild_distro]:-}" ]]; then
            print_error "Unknown distribution: $rebuild_distro"
            print_info "Supported: almalinux, rocky, oraclelinux, centos-stream, rhel, ubuntu-lts, debian, opensuse-leap"
            exit 1
        fi
        if [[ -z "$rebuild_version" ]]; then
            print_error "--version/-v is required when distro is specified."
            show_rebuild_help
            exit 1
        fi
        local valid_versions="${DISTRO_AVAILABLE_VERSIONS[$rebuild_distro]}"
        local ver_found=false
        for v in $valid_versions; do
            if [[ "$v" == "$rebuild_version" ]]; then
                ver_found=true
                break
            fi
        done
        if [[ "$ver_found" != true ]]; then
            print_error "Invalid version '$rebuild_version' for ${DISTRO_DISPLAY_NAMES[$rebuild_distro]}."
            print_info "Available versions: $valid_versions"
            exit 1
        fi

        local version_dashed="${rebuild_version//./-}"
        local pattern="${GOLDEN_IMAGE_DIR}/${rebuild_distro}-${version_dashed}-golden-image.*.qcow2"
        local -a matched_files=()
        for f in $pattern; do
            [[ -e "$f" ]] && matched_files+=("$f")
        done
        if [[ ${#matched_files[@]} -eq 0 ]]; then
            print_info "No existing golden image for ${DISTRO_DISPLAY_NAMES[$rebuild_distro]} ${rebuild_version}. Building new one..."
            exec "${SCRIPT_DIR}/kvm-build-golden-image.sh" "$rebuild_distro" --version "$rebuild_version"
        fi

        print_info "Rebuilding golden image: ${DISTRO_DISPLAY_NAMES[$rebuild_distro]} ${rebuild_version}"
        for f in "${matched_files[@]}"; do
            local base
            base=$(basename "$f" .qcow2)
            print_task "Removing existing golden image: ${base}..."
            sudo rm -f "$f"
            sudo rm -f "${GOLDEN_IMAGE_DIR}/${base}_VARS.fd"
            print_task_done
        done

        exec "${SCRIPT_DIR}/kvm-build-golden-image.sh" "$rebuild_distro" --version "$rebuild_version"
    fi

    # Interactive mode: pick from existing images
    if [[ ! -d "$GOLDEN_IMAGE_DIR" ]] || ! ls "${GOLDEN_IMAGE_DIR}"/*.qcow2 &>/dev/null; then
        print_info "No golden images found. Nothing to rebuild."
        print_info "Use 'tux2lab golden-image build <distro> -v <version>' to create one."
        return 0
    fi

    local -a image_files=()
    local -a image_distros=()
    local -a image_versions=()
    local -a image_labels=()
    for qcow2_file in "${GOLDEN_IMAGE_DIR}"/*.qcow2; do
        local filename
        filename=$(basename "$qcow2_file" .qcow2)
        local prefix distro version
        prefix="${filename%%-golden-image.*}"
        distro="$prefix"
        version="unknown"
        for known_distro in "${!DISTRO_DISPLAY_NAMES[@]}"; do
            if [[ "$prefix" == "${known_distro}-"* ]]; then
                distro="$known_distro"
                local version_raw="${prefix#${known_distro}-}"
                version="${version_raw//-/.}"
                break
            fi
        done
        local display_name="${DISTRO_DISPLAY_NAMES[$distro]:-$distro}"

        image_files+=("$qcow2_file")
        image_distros+=("$distro")
        image_versions+=("$version")
        image_labels+=("${display_name} ${version}")
    done

    local menu="Select golden image to rebuild:\n"
    for i in "${!image_labels[@]}"; do
        printf -v line "  %d)  %s\n" $((i+1)) "${image_labels[$i]}"
        menu+="${line}"
    done
    menu+="  q)  Quit"

    print_notify "$menu"
    echo -n "Enter option number: "
    read -r choice

    if [[ "$choice" == "q" || "$choice" == "Q" ]]; then
        print_info "Operation cancelled by user."
        exit 0
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#image_files[@]} )); then
        local selected_file="${image_files[$((choice-1))]}"
        local selected_distro="${image_distros[$((choice-1))]}"
        local selected_version="${image_versions[$((choice-1))]}"
        local base
        base=$(basename "$selected_file" .qcow2)

        print_info "Rebuilding golden image: ${image_labels[$((choice-1))]}"
        print_task "Removing existing golden image: ${base}..."
        sudo rm -f "$selected_file"
        sudo rm -f "${GOLDEN_IMAGE_DIR}/${base}_VARS.fd"
        print_task_done

        exec "${SCRIPT_DIR}/kvm-build-golden-image.sh" "$selected_distro" --version "$selected_version"
    else
        print_error "Invalid option."
        exit 1
    fi
}

# ====== BUILD ======

golden_image_build() {
    exec "${SCRIPT_DIR}/kvm-build-golden-image.sh" "$@"
}

# ====== MAIN DISPATCH ======

if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_golden_image_help
    exit 0
fi

subcommand="$1"
shift

case "$subcommand" in
    build|create)
        golden_image_build "$@"
        ;;
    rebuild)
        golden_image_rebuild "$@"
        ;;
    list)
        if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
            show_list_help
            exit 0
        fi
        golden_image_list
        ;;
    cleanup)
        golden_image_cleanup "$@"
        ;;
    *)
        print_error "Unknown golden-image subcommand: $subcommand"
        echo
        show_golden_image_help
        exit 1
        ;;
esac
