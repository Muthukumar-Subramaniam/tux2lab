# Auto-setup distro for PXE boot if not already prepared.
# Called after validate_distro_version has confirmed the distro/version are valid.
# Usage: auto_setup_distro "$OS_DISTRO" "$VERSION_TYPE"
auto_setup_distro() {
    local distro="$1"
    local version="$2"

    # Skip if distro or version not specified (interactive mode — ksmanager will prompt)
    [[ -z "$distro" || -z "$version" ]] && return 0

    local distro_ready=false
    if [[ "$distro" == "debian" ]]; then
        [[ -f "/tux2lab-data/os-repos/${distro}/${version}-netboot/vmlinuz" ]] && distro_ready=true
    else
        mountpoint -q "/tux2lab-data/os-repos/${distro}/${version}" 2>/dev/null && distro_ready=true
    fi

    if [[ "$distro_ready" == "false" ]]; then
        print_info "${distro} ${version} is not prepared for PXE boot. Setting it up..."
        if ! /tux2lab/ks-manage/prepare-distro-for-ksmanager.sh --setup "$distro" -v "$version"; then
            print_error "Distro setup failed."
            return 1
        fi
    fi
}
