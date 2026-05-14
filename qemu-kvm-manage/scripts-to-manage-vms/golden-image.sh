#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Script Name: golden-image.sh                                                           #
# Description: Manage golden image disks for OS provisioning                             #
# Invoked by : tux2lab golden-image {build|list|cleanup}                                #
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
    build [OPTIONS]         Build a golden image by installing a VM via PXE boot
    list                    List all available golden images
    cleanup                 Remove golden image(s)

BUILD OPTIONS:
    -d, --distro <distro>   Specify OS distribution
    -v, --version <ver>     Specify OS version number

CLEANUP OPTIONS:
    -d, --distro <distro>   Specify OS distribution to remove
    -v, --version <ver>     Specify OS version number to remove
    -f, --force             Skip confirmation prompt

OPTIONS:
    -h, --help              Show this help message

EXAMPLES:
    tux2lab golden-image list
    tux2lab golden-image build                             # Interactive mode
    tux2lab golden-image build -d almalinux -v 10          # Non-interactive mode
    tux2lab golden-image cleanup                            # Interactive cleanup
    tux2lab golden-image cleanup -d almalinux -v 10        # Remove specific golden image
    tux2lab golden-image cleanup -f -d rocky -v 9          # Remove without confirmation"
}

# ====== LIST ======

golden_image_list() {
    if [[ ! -d "$GOLDEN_IMAGE_DIR" ]] || ! ls "${GOLDEN_IMAGE_DIR}"/*.qcow2 &>/dev/null; then
        print_info "No golden images found."
        print_info "Create one with: tux2lab golden-image build"
        return 0
    fi

    printf "\n  %-20s %-12s %-22s %-30s\n" "DISTRO" "VERSION" "SIZE (DISK / VIRTUAL)" "CREATED"
    printf "  %-20s %-12s %-22s %-30s\n" "------" "-------" "---------------------" "-------"

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
        disk_size=$(sudo qemu-img info "$qcow2_file" 2>/dev/null | awk '/^disk size:/ {print $3, $4; exit}')
        disk_size="${disk_size:-?}"
        virtual_size=$(sudo qemu-img info "$qcow2_file" 2>/dev/null | awk '/^virtual size:/ {print $3, $4; exit}')
        virtual_size="${virtual_size:-?}"
        size="${disk_size} / ${virtual_size}"
        local created
        created=$(stat -c '%y' "$qcow2_file" 2>/dev/null | cut -d'.' -f1)
        created="${created:-unknown}"

        printf "  %-20s %-12s %-22s %-30s\n" "$display_name" "$version" "$size" "$created"
    done
    echo
}

# ====== CLEANUP ======

show_cleanup_help() {
    print_cyan "Usage: tux2lab golden-image cleanup [OPTIONS]
Description:
    Remove golden image disk(s) from the golden images disk store.
    Run without options for an interactive menu.

Options:
    -d, --distro <distro>   Specify OS distribution to remove
                                            (almalinux, rocky, oraclelinux, centos-stream, rhel, ubuntu-lts, opensuse-leap)
    -v, --version <ver>     Specify OS version number to remove
    -f, --force             Skip confirmation prompt
    -h, --help              Show this help message

Examples:
    tux2lab golden-image cleanup                            # Interactive cleanup
    tux2lab golden-image cleanup -d almalinux -v 10        # Remove specific golden image
    tux2lab golden-image cleanup -f -d rocky -v 9          # Remove without confirmation
"
}

golden_image_cleanup() {
    local cleanup_distro=""
    local cleanup_version=""
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--distro)
                if [[ -z "${2:-}" || "${2:-}" == -* ]]; then
                    print_error "--distro/-d requires a distribution name."
                    show_cleanup_help
                    exit 1
                fi
                cleanup_distro="$2"
                shift 2
                ;;
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
                print_error "'tux2lab golden-image cleanup' does not accept positional arguments."
                show_cleanup_help
                exit 1
                ;;
        esac
    done

    if [[ ! -d "$GOLDEN_IMAGE_DIR" ]] || ! ls "${GOLDEN_IMAGE_DIR}"/*.qcow2 &>/dev/null; then
        print_info "No golden images found. Nothing to clean up."
        return 0
    fi

    # Non-interactive mode: -d and -v specified
    if [[ -n "$cleanup_distro" ]]; then
        if [[ -z "${DISTRO_DISPLAY_NAMES[$cleanup_distro]:-}" ]]; then
            print_error "Unknown distribution: $cleanup_distro"
            print_info "Supported: almalinux, rocky, oraclelinux, centos-stream, rhel, ubuntu-lts, opensuse-leap"
            exit 1
        fi
        if [[ -z "$cleanup_version" ]]; then
            print_error "--version/-v is required when --distro/-d is specified."
            exit 1
        fi
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
            read -rp "Are you sure? (yes/no): " confirm
            if [[ "$confirm" != "yes" ]]; then
                print_info "Cleanup aborted."
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
        read -rp "Are you sure? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            print_info "Cleanup aborted."
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
    list)
        if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
            show_golden_image_help
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
