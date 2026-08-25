run_ksmanager() {
    local hostname="$1"
    local ksmanager_options="$2"
    local cleanup_on_cancel="${3:-false}"

    # For --create-golden-image mode, hostname is not provided upfront
    if [[ "$ksmanager_options" != *"--create-golden-image"* ]]; then
        if [[ -z "$hostname" ]]; then
            print_error "run_ksmanager requires hostname"
            return 1
        fi
    fi

    # Execute ksmanager — output flows directly to terminal
    local ksmanager_exit_code=0
    if [[ -z "$hostname" ]]; then
        /tux2lab/ksmanager/ksmanager.sh ${ksmanager_options} || ksmanager_exit_code=$?
    else
        /tux2lab/ksmanager/ksmanager.sh "${hostname}" ${ksmanager_options} || ksmanager_exit_code=$?
    fi

    # Check if user cancelled (exit code 130)
    if [[ $ksmanager_exit_code -eq 130 ]]; then
        if [[ "$cleanup_on_cancel" == "true" ]] && [[ -n "$hostname" ]]; then
            print_info "Cleaning up resources for '${hostname}' due to cancellation..."
            /tux2lab/ksmanager/ksmanager.sh "${hostname}" --remove-host || true
            print_info "Cleanup completed for '${hostname}' due to cancellation.\n"
        fi
        return 1
    fi

    # Check for other failures
    if [[ $ksmanager_exit_code -ne 0 ]]; then
        print_error "ksmanager execution failed."
        return 1
    fi

    # Retrieve provision results from JSON sidecar via nginx (mode-agnostic)
    local provision_json=""

    if [[ "$ksmanager_options" == *"--create-golden-image"* ]]; then
        # For golden image creation, hostname is unknown — discover via MAC lookup in hosts.json
        local golden_mac=""
        golden_mac=$(printf '%s' "$ksmanager_options" | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}')

        if [[ -n "$golden_mac" ]]; then
            local hosts_json=""
            hosts_json=$(cat /tux2lab-data/ksmanager-hub/hosts.json 2>/dev/null) || true

            if [[ -n "$hosts_json" ]]; then
                EXTRACTED_HOSTNAME=$(printf '%s' "$hosts_json" | jq -r --arg mac "$golden_mac" '.[] | select(.mac_address == $mac) | .hostname // empty')
            fi
        fi

        if [[ -n "${EXTRACTED_HOSTNAME:-}" ]]; then
            provision_json=$(cat /tux2lab-data/ksmanager-hub/kickstarts/${EXTRACTED_HOSTNAME}/provision-result.json 2>/dev/null) || true
        fi
    else
        provision_json=$(cat /tux2lab-data/ksmanager-hub/kickstarts/${hostname}/provision-result.json 2>/dev/null) || true
    fi

    if [[ -n "$provision_json" ]]; then
        IPV4_ADDRESS=$(printf '%s' "$provision_json" | jq -r '.ipv4_address // empty')
        IPV6_ADDRESS=$(printf '%s' "$provision_json" | jq -r '.ipv6_address // empty')
        OS_DISTRO=$(printf '%s' "$provision_json" | jq -r '.os_distribution // empty')
        VERSION_TYPE=$(printf '%s' "$provision_json" | jq -r '.version // empty')
        EXTRACTED_HOSTNAME=$(printf '%s' "$provision_json" | jq -r '.hostname // empty')
        STACK_MODE=$(printf '%s' "$provision_json" | jq -r '.stack_mode // "dual"')
        PXE_BOOTSTRAP_HOSTNAME=$(printf '%s' "$provision_json" | jq -r '.pxe_bootstrap_hostname // empty')
    else
        IPV4_ADDRESS=""
        IPV6_ADDRESS=""
        OS_DISTRO=""
        VERSION_TYPE=""
        EXTRACTED_HOSTNAME="${EXTRACTED_HOSTNAME:-}"
        STACK_MODE="dual"
        PXE_BOOTSTRAP_HOSTNAME=""
    fi

    # Validate extracted values based on operation mode
    if [[ "$ksmanager_options" == *"--create-golden-image"* ]]; then
        if [[ -z "${EXTRACTED_HOSTNAME}" ]]; then
            print_error "Failed to extract hostname from ksmanager output."
            print_info "Please check the lab infrastructure container ${CONTAINER_NAME} for details."
            return 1
        fi
    else
        if [[ "${STACK_MODE}" != "ipv6" ]] && [[ -z "${IPV4_ADDRESS}" ]]; then
            print_error "Failed to extract IPv4 address from ksmanager output."
            print_info "Please check the lab infrastructure container ${CONTAINER_NAME} for details."
            return 1
        fi
        if [[ "${STACK_MODE}" != "ipv4" ]] && [[ -z "${IPV6_ADDRESS}" ]]; then
            print_error "Failed to extract IPv6 address from ksmanager output."
            print_info "Please check the lab infrastructure container ${CONTAINER_NAME} for details."
            return 1
        fi
    fi

    # OS_DISTRO is optional - only validate if it was expected (golden-image mode)
    if [[ "$ksmanager_options" == *"--golden-image"* && -z "${OS_DISTRO}" ]]; then
        print_error "Failed to extract OS distro from ksmanager output."
        print_info "Please check the lab infrastructure container ${CONTAINER_NAME} for details."
        return 1
    fi

    return 0
}
