#!/bin/sh

# Azure Linux 3's installer uses wget recursively, but the stock initramfs
# omits wget. Implement the specific recursive autoindex download it needs.
destination=""
source_url=""

for argument in "$@"; do
    case "$argument" in
        --directory-prefix=*)
            destination=${argument#--directory-prefix=}
            ;;
        -*)
            ;;
        *)
            source_url=$argument
            ;;
    esac
done

if [ -z "$destination" ] || [ -z "$source_url" ]; then
    echo "wget shim: missing directory prefix or source URL" >&2
    exit 2
fi

download_directory() {
    remote_url=${1%/}/
    local_dir=$2
    listing_file="${local_dir}/.index.html"

    mkdir -p "$local_dir"
    if ! curl --fail --silent --show-error --location "$remote_url" -o "$listing_file"; then
        rm -f "$listing_file"
        return 1
    fi

    grep -o 'href="[^"]*"' "$listing_file" |
        cut -d'"' -f2 |
        while IFS= read -r entry; do
            case "$entry" in
                ../|/*|\?*|http://*|https://*|"")
                    continue
                    ;;
                */)
                    (download_directory "${remote_url}${entry}" "${local_dir}/${entry%/}") || exit 1
                    ;;
                *)
                    curl --fail --silent --show-error --location \
                        "${remote_url}${entry}" -o "${local_dir}/${entry}" || exit 1
                    ;;
            esac
        done
    status=$?

    rm -f "$listing_file"
    return "$status"
}

download_directory "$source_url" "$destination"
