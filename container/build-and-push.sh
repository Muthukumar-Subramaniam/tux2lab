#!/usr/bin/env bash
#----------------------------------------------------------------------------------------#
# Build and push tux2lab-engine container image to both registries.
# Run from the project root: /tux2lab/container/build-and-push.sh
#----------------------------------------------------------------------------------------#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! VERSION=$(jq -ers '
    select(length == 1) | .[0] | objects | .version | strings
    | select(test("\\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\\z"))
' project_version.json); then
    echo "project_version.json must contain exactly one object with a non-empty version string usable as an image tag." >&2
    exit 1
fi
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

BUILD_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tux2lab-build.XXXXXXXX")
trap 'rm -f "${BUILD_TMP_DIR}/image-id"; rmdir "${BUILD_TMP_DIR}"' EXIT

# Build
# --network=host avoids podman creating a throwaway bridge just for the apk step
sudo podman build --no-cache --pull=always --network=host \
    --iidfile "${BUILD_TMP_DIR}/image-id" \
    -t "${GHCR}:${VERSION}" -f container/Containerfile .

if [[ ! -s "${BUILD_TMP_DIR}/image-id" ]]; then
    echo "Build completed without an image ID; refusing to tag or push." >&2
    exit 1
fi
IMAGE_ID=$(sudo cat "${BUILD_TMP_DIR}/image-id")

# Tag
sudo podman tag "${IMAGE_ID}" "${GHCR}:latest"
sudo podman tag "${IMAGE_ID}" "${DOCKERHUB}:${VERSION}"
sudo podman tag "${IMAGE_ID}" "${DOCKERHUB}:latest"

# Push
for tag in "${VERSION}" latest; do
    for repository in "${GHCR}" "${DOCKERHUB}"; do
        echo "Pushing ${repository}:${tag}..."
        sudo podman push "${IMAGE_ID}" "docker://${repository}:${tag}"
    done
done

echo "Done. Image: tux2lab-engine:${VERSION}"
