#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Build and push tux2lab-engine container image to both registries.
# Run from the project root: /tux2lab/container/build-and-push.sh
#----------------------------------------------------------------------------------------#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

VERSION=$(jq -r '.version' /tux2lab/project_version.json)
GHCR="ghcr.io/muthukumar-subramaniam/tux2lab-engine"
DOCKERHUB="docker.io/musubram/tux2lab-engine"

echo "Building tux2lab-engine:${VERSION}..."

# Remove only tux2lab-engine images
for img in $(sudo podman images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep "tux2lab-engine"); do
    sudo podman rmi -f "$img" 2>/dev/null || true
done
# Remove dangling images
sudo podman image prune -f &>/dev/null || true

# Build
sudo podman build --no-cache -t "${GHCR}:${VERSION}" -f Containerfile .

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
