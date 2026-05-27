#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Function: validate_distro_version                                                      #
# Description: Validates OS distribution name and version against distro-versions.conf   #
# Usage: validate_distro_version "$distro" "$version"                                    #
# - Exits 1 with error message if distro is invalid                                     #
# - Exits 1 with error message if version is invalid for the given distro               #
# - Returns 0 silently if valid or if distro is empty                                   #
#----------------------------------------------------------------------------------------#

validate_distro_version() {
    local distro="$1"
    local version="${2:-}"

    [[ -z "$distro" ]] && return 0

    # Source distro-versions.conf if not already loaded
    if [[ -z "${DISTRO_AVAILABLE_VERSIONS[*]:-}" ]]; then
        source /tux2lab/ks-manage/distro-versions.conf
    fi

    if [[ -z "${DISTRO_AVAILABLE_VERSIONS[$distro]:-}" ]]; then
        print_error "Invalid distro: $distro"
        local valid_distros="${!DISTRO_AVAILABLE_VERSIONS[*]}"
        print_info "Valid options: ${valid_distros// /, }"
        exit 1
    fi

    if [[ -n "$version" ]]; then
        local valid_versions="${DISTRO_AVAILABLE_VERSIONS[$distro]}"
        local found=false
        for v in $valid_versions; do
            if [[ "$v" == "$version" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" != true ]]; then
            print_error "Invalid version '$version' for ${DISTRO_DISPLAY_NAMES[$distro]:-$distro}."
            print_info "Available versions: $valid_versions"
            exit 1
        fi
    fi
}
