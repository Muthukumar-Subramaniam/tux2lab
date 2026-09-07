#!/bin/sh

# Azure Linux 3's installer calls ping, but the stock initramfs omits it.
# Treat HTTP reachability as the equivalent readiness check for the PXE server.
for argument in "$@"; do
    server="$argument"
done

exec curl --fail --silent --show-error --connect-timeout 2 "http://${server}/" >/dev/null
