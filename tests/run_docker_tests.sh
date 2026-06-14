#!/usr/bin/env bash
#
# run_docker_tests.sh
# Host-side driver script to build and execute the systemd-nspawn 
# clean chroot integration test suite within the Docker build container.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE_NAME="arch-build-server-test"
CONTAINER_NAME="arch-builder-test"

# Make sure the container-side test script is executable before copying/mounting
chmod +x "${SCRIPT_DIR}/test_systemd_nspawn_inside_docker.sh"

echo "================================================================================"
echo "Building test Docker image '${IMAGE_NAME}'..."
echo "================================================================================"
docker build \
  --build-arg UID="$(id -u)" \
  --build-arg GID="$(id -g)" \
  -t "${IMAGE_NAME}" \
  "${WORKSPACE_DIR}"

echo -e "\n================================================================================"
echo "Running systemd-nspawn integration tests inside privileged container..."
echo "================================================================================"

# Run the integration tests inside the container in privileged mode (required for systemd-nspawn/chroots)
# Mounts the workspace to match the structure in docker-run.sh
docker run --privileged --rm \
  --tmpfs /run \
  --tmpfs /tmp \
  -v "${WORKSPACE_DIR}:${WORKSPACE_DIR}" \
  -w "${WORKSPACE_DIR}" \
  -e WORKSPACE_DIR="${WORKSPACE_DIR}" \
  --name "${CONTAINER_NAME}" \
  "${IMAGE_NAME}" \
  "${WORKSPACE_DIR}/tests/test_systemd_nspawn_inside_docker.sh"
