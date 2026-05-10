# lookup-previous-provision.sh
#
# Looks up previous provisioning data for a VM from ksmanager's provision-result.json
# Used during reimage to auto-detect distro and version when not specified on CLI
#
# Usage:
#   source /path/to/lookup-previous-provision.sh
#   lookup_previous_provision "vm-hostname"
#
# Sets global variables (only if lookup succeeds):
#   PREVIOUS_OS_DISTRO   - Previously provisioned OS distribution (e.g., "almalinux")
#   PREVIOUS_VERSION     - Previously provisioned version (e.g., "10", "24.04")
#
# Returns:
#   0 - Lookup succeeded, variables set
#   1 - Lookup failed (no previous provisioning data found)

lookup_previous_provision() {
    local vm_hostname="$1"

    if [[ -z "$vm_hostname" ]]; then
        return 1
    fi

    # Construct FQDN if bare hostname provided
    local fqdn="$vm_hostname"
    if [[ "$fqdn" != *.* ]]; then
        fqdn="${vm_hostname}.${lab_infra_domain_name}"
    fi

    local provision_json=""
    provision_json=$(curl -fsSL "http://${lab_infra_server_hostname}/ksmanager-hub/kickstarts/${fqdn}/provision-result.json" 2>/dev/null) || true

    if [[ -z "$provision_json" ]]; then
        return 1
    fi

    local distro version
    distro=$(printf '%s' "$provision_json" | jq -r '.os_distribution // empty')
    version=$(printf '%s' "$provision_json" | jq -r '.version // empty')

    if [[ -z "$distro" || -z "$version" ]]; then
        return 1
    fi

    PREVIOUS_OS_DISTRO="$distro"
    PREVIOUS_VERSION="$version"
    return 0
}
