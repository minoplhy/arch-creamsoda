#!/usr/bin/env bash
#
# docker-run.sh
# Helper script to build and run the Arch build server Docker container 
# with correct mount paths, cache persistence, and file permissions.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE_NAME="arch-build-server"
CONTAINER_NAME="arch-builder"

# Ensure cache directories exist on the host before running Docker to avoid them being created as root
mkdir -p "${WORKSPACE_DIR}/cache/packages"
mkdir -p "${WORKSPACE_DIR}/cache/sources"
mkdir -p "${WORKSPACE_DIR}/cache/chroot"

# Build the docker image matching the current host user's UID and GID
echo "Building docker image '${IMAGE_NAME}' matching host user UID=$(id -u) GID=$(id -g)..."
docker build \
  --build-arg UID="$(id -u)" \
  --build-arg GID="$(id -g)" \
  -t "${IMAGE_NAME}" \
  "${SCRIPT_DIR}"

echo "--------------------------------------------------------------------------------"
echo "Starting container '${CONTAINER_NAME}' in privileged mode..."
echo "All files compiled will be owned by user '$(id -un)' ($(id -u):$(id -g))."
echo "--------------------------------------------------------------------------------"

# Run the docker container in privileged mode
# - Mounts the workspace root to /workspace
# - Mounts the pacman package cache to /var/cache/pacman/pkg inside the container
docker run --privileged -it --rm \
  -v "${WORKSPACE_DIR}:/workspace" \
  -v "${WORKSPACE_DIR}/cache/packages:/var/cache/pacman/pkg" \
  --name "${CONTAINER_NAME}" \
  "${IMAGE_NAME}"
