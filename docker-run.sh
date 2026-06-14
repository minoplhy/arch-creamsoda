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

# Resolve the Git common directory (bare repository base database)
# When working with git worktrees, the actual .git files and databases are inside the bare repository
# which might lie outside of the active worktree workspace path. We must mount it as well.
# Respect GIT_BARE_DIR if already set in environment
GIT_BARE_DIR="${GIT_BARE_DIR:-}"

# If not in env, check if it's set in config.conf
if [ -z "${GIT_BARE_DIR}" ] && [ -f "${WORKSPACE_DIR}/config.conf" ]; then
  # Sourcing in a subshell to avoid polluting environment
  GIT_BARE_DIR=$(unset GIT_BARE_DIR; source "${WORKSPACE_DIR}/config.conf" &>/dev/null && echo "${GIT_BARE_DIR:-}")
fi

# If still not found, attempt auto-detection from git worktree
if [ -z "${GIT_BARE_DIR}" ]; then
  if git -C "${WORKSPACE_DIR}" rev-parse --git-dir &>/dev/null; then
    COMMON_DIR=$(git -C "${WORKSPACE_DIR}" rev-parse --git-common-dir)
    # Resolve to absolute path safely
    GIT_BARE_DIR="$(cd "${WORKSPACE_DIR}" && cd "${COMMON_DIR}" && pwd)"
  fi
fi

# Ensure GIT_BARE_DIR is absolute and exists if it is set
if [ -n "${GIT_BARE_DIR}" ]; then
  if [[ "${GIT_BARE_DIR}" != /* ]]; then
    GIT_BARE_DIR="${WORKSPACE_DIR}/${GIT_BARE_DIR}"
  fi
  mkdir -p "${GIT_BARE_DIR}"
  GIT_BARE_DIR="$(cd "${GIT_BARE_DIR}" && pwd)"
fi

EXTRA_MOUNTS=()
if [ -n "${GIT_BARE_DIR}" ] && [ "${GIT_BARE_DIR}" != "${WORKSPACE_DIR}" ] && [[ "${GIT_BARE_DIR}" != "${WORKSPACE_DIR}/"* ]]; then
  echo "Detected external bare Git directory at: ${GIT_BARE_DIR}"
  echo "Mounting Git directory to preserve worktree metadata..."
  EXTRA_MOUNTS+=("-v" "${GIT_BARE_DIR}:${GIT_BARE_DIR}")
fi

echo "--------------------------------------------------------------------------------"
echo "Starting container '${CONTAINER_NAME}' in privileged mode..."
echo "All files compiled will be owned by user '$(id -un)' ($(id -u):$(id -g))."
echo "--------------------------------------------------------------------------------"

# Run the docker container in privileged mode
# - Mounts the workspace to the identical absolute path inside the container to preserve git worktree links
# - Mounts the pacman package cache to /var/cache/pacman/pkg inside the container
# - Mounts the external bare Git repository directory if it lies outside the workspace
docker run --privileged -it --rm \
  --tmpfs /run \
  --tmpfs /tmp \
  -v "${WORKSPACE_DIR}:${WORKSPACE_DIR}" \
  -w "${WORKSPACE_DIR}" \
  -v "${WORKSPACE_DIR}/cache/packages:/var/cache/pacman/pkg" \
  "${EXTRA_MOUNTS[@]}" \
  -e GIT_BARE_DIR="${GIT_BARE_DIR}" \
  --name "${CONTAINER_NAME}" \
  "${IMAGE_NAME}"
