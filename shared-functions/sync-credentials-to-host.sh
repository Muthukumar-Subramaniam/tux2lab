# Sync lab credentials (SSH keys, CA cert) to the KVM host.
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
            # Smart update authorized_keys: replace lab key by domain, preserve others
            local _auth_file="${_host_ssh_dir}/authorized_keys"
            touch "$_auth_file"
            sed -i "/ ${_lab_domain}$/d" "$_auth_file"
            cat "${_lab_config}/ssh-keys/tux2lab_id_rsa.pub" >> "$_auth_file"
            chown -R "${_admin_user}:$(id -g "$_admin_user")" "${_host_ssh_dir}"
            _changed=true
        fi
    fi

    # CA certificate
    if [[ -f "${_lab_config}/certs/tux2lab-nginx-selfsigned.crt" ]]; then
        local _host_cert=""
        if command -v update-ca-trust &>/dev/null; then
            _host_cert="/etc/pki/ca-trust/source/anchors/tux2lab-nginx-selfsigned.crt"
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
