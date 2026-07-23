# Interactive distro and version selection.
# Sets SELECTED_DISTRO and SELECTED_VERSION variables.
# Skips prompts if values are already provided.
# Usage: select_distro_version "$OS_DISTRO" "$VERSION_TYPE"
#        OS_DISTRO="$SELECTED_DISTRO"
#        VERSION_TYPE="$SELECTED_VERSION"

select_distro_version() {
    SELECTED_DISTRO="${1:-}"
    SELECTED_VERSION="${2:-}"

    # Distro selection (if not provided)
    if [[ -z "$SELECTED_DISTRO" ]]; then
        local _distro_keys
        _distro_keys=$(bash -c "source /tux2lab/ks-manage/distro-versions.conf; echo \"\${DISTRO_KEYS[*]}\"")
        local _distro_arr=($_distro_keys)
        while true; do
            echo "Select the OS distribution:"
            for i in "${!_distro_arr[@]}"; do
                local _dk="${_distro_arr[$i]}"
                local _dn _dv
                _dn=$(bash -c "source /tux2lab/ks-manage/distro-versions.conf; echo \"\${DISTRO_DISPLAY_NAMES[$_dk]}\"")
                _dv=$(bash -c "source /tux2lab/ks-manage/distro-versions.conf; echo \"\${DISTRO_AVAILABLE_VERSIONS[$_dk]}\"")
                printf "  %d)  %-24s (versions: %s)\n" $((i+1)) "$_dn" "$_dv"
            done
            echo "  q)  Quit"
            echo -n "Enter option number: "
            read -r _distro_choice
            if [[ "$_distro_choice" == "q" || "$_distro_choice" == "Q" ]]; then
                exit 130
            fi
            if [[ "$_distro_choice" =~ ^[0-9]+$ ]] && (( _distro_choice >= 1 && _distro_choice <= ${#_distro_arr[@]} )); then
                SELECTED_DISTRO="${_distro_arr[$((_distro_choice-1))]}"
                break
            fi
            print_error "Invalid option. Please try again."
        done
    fi

    # Version selection (if not provided)
    if [[ -z "$SELECTED_VERSION" ]]; then
        local _ver_string _display_name
        _ver_string=$(bash -c "source /tux2lab/ks-manage/distro-versions.conf; echo \"\${DISTRO_AVAILABLE_VERSIONS[$SELECTED_DISTRO]:-}\"")
        _display_name=$(bash -c "source /tux2lab/ks-manage/distro-versions.conf; echo \"\${DISTRO_DISPLAY_NAMES[$SELECTED_DISTRO]:-$SELECTED_DISTRO}\"")
        local _versions=($_ver_string)
        while true; do
            echo "Available versions for ${_display_name}: ${_versions[*]}"
            echo -n "Enter the version: "
            read -r _ver_input
            if [[ "$_ver_input" == "q" || "$_ver_input" == "Q" ]]; then
                exit 130
            fi
            for v in "${_versions[@]}"; do
                if [[ "$v" == "$_ver_input" ]]; then
                    SELECTED_VERSION="$_ver_input"
                    break 2
                fi
            done
            print_error "Invalid version '${_ver_input}'. Please try again."
        done
    fi
}
