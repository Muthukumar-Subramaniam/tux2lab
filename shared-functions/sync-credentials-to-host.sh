# Sync lab credentials (SSH keys, CA cert, SSH client config) to the KVM host.
# Compares lab-config with host files — only updates if different.
# Usage: source this file, then call sync_credentials_to_host

sync_credentials_to_host() {
    local _lab_config="/tux2lab-data/lab-config"
    local _lab_env="/tux2lab-data/lab-config/lab_environment.json"
    local _admin_user _lab_domain
    _admin_user=$(jq -r '.admin.username' "$_lab_env")
    _lab_domain=$(jq -r '.lab.domain' "$_lab_env")
    local _host_ssh_dir="/home/${_admin_user}/.ssh"
    local _changed=false

    mkdir -p "$_host_ssh_dir"

    # SSH keys
    if [[ -f "${_lab_config}/ssh-keys/tux2lab_id_rsa" ]]; then
        if ! diff -q "${_lab_config}/ssh-keys/tux2lab_id_rsa" "${_host_ssh_dir}/tux2lab_id_rsa" &>/dev/null; then
            cp "${_lab_config}/ssh-keys/tux2lab_id_rsa" "${_host_ssh_dir}/"
            cp "${_lab_config}/ssh-keys/tux2lab_id_rsa.pub" "${_host_ssh_dir}/"
            chmod 600 "${_host_ssh_dir}/tux2lab_id_rsa"
            chmod 644 "${_host_ssh_dir}/tux2lab_id_rsa.pub"
            chown -R "${_admin_user}:$(id -g "$_admin_user")" "${_host_ssh_dir}"
            _changed=true
        fi
    fi

    # The lab key is published over HTTP for provisioning, so it is never authorized on
    # the host. Checked on every sync so "tux2lab rebuild" clears older deployments.
    local _auth_file="${_host_ssh_dir}/authorized_keys"
    if [[ -f "$_auth_file" ]] && grep -q " ${_lab_domain}$" "$_auth_file"; then
        sed -i "/ ${_lab_domain}$/d" "$_auth_file"
        chown "${_admin_user}:$(id -g "$_admin_user")" "$_auth_file"
        _changed=true
    fi

    # SSH client config (marker-based block in ~/.ssh/config.custom)
    local _ssh_custom="${_host_ssh_dir}/config.custom"
    local _marker_begin="# BEGIN tux2lab"
    local _marker_end="# END tux2lab"
    local _ipv4_network _ipv4_broadcast _ipv6_prefix_base
    local _ssh_host_patterns="*.${_lab_domain}"
    _ipv4_network=$(jq -r '.network.ipv4.network' "$_lab_env")
    _ipv4_broadcast=$(jq -r '.network.ipv4.broadcast' "$_lab_env")
    _ipv6_prefix_base=$(jq -r '.network.ipv6.prefix_base' "$_lab_env")
    local _n1 _n2 _n3 _dummy _b3
    IFS=. read -r _n1 _n2 _n3 _dummy <<< "$_ipv4_network"
    IFS=. read -r _dummy _dummy _b3 _dummy <<< "$_ipv4_broadcast"
    for _octet3 in $(seq "$_n3" "$_b3"); do
        _ssh_host_patterns+=" ${_n1}.${_n2}.${_octet3}.*"
    done
    _ssh_host_patterns+=" ${_ipv6_prefix_base}:*"

    local _expected_block
    _expected_block=$(cat <<EOF
Host ${_ssh_host_patterns}
  IdentityFile ~/.ssh/tux2lab_id_rsa
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel QUIET
EOF
    )

    # Extract current block content (without markers) and compare
    local _current_block=""
    if grep -q "$_marker_begin" "$_ssh_custom" 2>/dev/null; then
        _current_block=$(sed -n "/${_marker_begin}/,/${_marker_end}/{ /${_marker_begin}/d; /${_marker_end}/d; p; }" "$_ssh_custom")
    fi

    if [[ "$_current_block" != "$_expected_block" ]]; then
        # Remove existing block if present
        if grep -q "$_marker_begin" "$_ssh_custom" 2>/dev/null; then
            sed -i "/${_marker_begin}/,/${_marker_end}/d" "$_ssh_custom"
        fi
        cat >> "$_ssh_custom" <<EOF

${_marker_begin}
${_expected_block}
${_marker_end}
EOF
        chmod 644 "$_ssh_custom"
        chown "${_admin_user}:$(id -g "$_admin_user")" "$_ssh_custom"
        _changed=true
    fi

    # CA certificate
    if [[ -f "${_lab_config}/certs/tux2lab-nginx-selfsigned.crt" ]]; then
        local _host_cert=""
        if command -v update-ca-trust &>/dev/null; then
            _host_cert="/etc/pki/ca-trust/source/anchors/tux2lab-nginx-selfsigned.crt"
        elif [[ -d /etc/pki/trust/anchors ]]; then
            _host_cert="/etc/pki/trust/anchors/tux2lab-nginx-selfsigned.crt"
        elif command -v update-ca-certificates &>/dev/null; then
            _host_cert="/usr/local/share/ca-certificates/tux2lab-nginx-selfsigned.crt"
        fi
        if [[ -n "$_host_cert" ]] && ! diff -q "${_lab_config}/certs/tux2lab-nginx-selfsigned.crt" "$_host_cert" &>/dev/null; then
            sudo cp "${_lab_config}/certs/tux2lab-nginx-selfsigned.crt" "$_host_cert"
            if command -v update-ca-trust &>/dev/null; then
                sudo update-ca-trust 2>/dev/null || true
            else
                sudo update-ca-certificates 2>/dev/null || true
            fi
            _changed=true
        fi
    fi

    if $_changed; then
        return 0  # changes applied
    else
        return 1  # no changes
    fi
}
