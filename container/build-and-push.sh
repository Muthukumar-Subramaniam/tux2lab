#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Build and push tux2lab-engine container image to both registries.
# Run from the project root: /tux2lab/container/build-and-push.sh
#----------------------------------------------------------------------------------------#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

VERSION=$(jq -r '.version' /tux2lab/project_version.json)
GHCR="ghcr.io/muthukumar-subramaniam/tux2lab-engine"
DOCKERHUB="docker.io/musubram/tux2lab-engine"

# Root's credentials live on tmpfs and are lost on reboot, so check before the
# build rather than discovering it after a full rebuild.
for registry in ghcr.io docker.io; do
    if ! sudo podman login --get-login "${registry}" &>/dev/null; then
        echo "Not logged in to ${registry}."
        echo "Run: sudo podman login ${registry}"
        exit 1
    fi
done

echo "Building tux2lab-engine:${VERSION}..."

# Remove only tux2lab-engine images
for img in $(sudo podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep "tux2lab-engine"); do
    sudo podman rmi -f "$img" 2>/dev/null || true
done
# Remove dangling images
sudo podman image prune -f &>/dev/null || true

# Build
# --network=host avoids podman creating a throwaway bridge just for the apk step
sudo podman build --no-cache --network=host -t "${GHCR}:${VERSION}" -f container/Containerfile .

# Tag
sudo podman tag "${GHCR}:${VERSION}" "${GHCR}:latest"
sudo podman tag "${GHCR}:${VERSION}" "${DOCKERHUB}:${VERSION}"
sudo podman tag "${GHCR}:${VERSION}" "${DOCKERHUB}:latest"

# Push
echo "Pushing to GHCR..."
sudo podman push "${GHCR}:${VERSION}"
sudo podman push "${GHCR}:latest"

echo "Pushing to Docker Hub..."
sudo podman push "${DOCKERHUB}:${VERSION}"
sudo podman push "${DOCKERHUB}:latest"

echo "Done. Image: tux2lab-engine:${VERSION}"
