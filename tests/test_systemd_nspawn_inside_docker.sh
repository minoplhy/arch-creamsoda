#!/usr/bin/env bash
set -euo pipefail

# ANSI colors for visibility
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "=== Starting systemd-nspawn Integration Test ==="

# 1. Verify wrapper existence and path precedence
echo -e "\n1. Verifying systemd-nspawn wrapper installation..."
if [ ! -f /usr/local/bin/systemd-nspawn ]; then
  echo -e "${RED}[ERROR]${NC} systemd-nspawn wrapper does not exist at /usr/local/bin/systemd-nspawn!"
  exit 1
fi

# Check if /usr/local/bin takes precedence under sudo
sudo_path_check=$(sudo which systemd-nspawn)
if [ "$sudo_path_check" != "/usr/local/bin/systemd-nspawn" ]; then
  echo -e "${RED}[ERROR]${NC} sudo resolved systemd-nspawn to: ${sudo_path_check}"
  echo -e "Expected it to resolve to the wrapper: /usr/local/bin/systemd-nspawn"
  exit 1
fi

echo -e "${GREEN}[OK]${NC} Wrapper correctly installed and prioritized at: ${sudo_path_check}"

# 2. Check wrapper permissions and ownership
echo -e "\n2. Verifying wrapper permissions and ownership..."
wrapper_owner=$(stat -c '%U:%G' /usr/local/bin/systemd-nspawn)
wrapper_perms=$(stat -c '%a' /usr/local/bin/systemd-nspawn)

if [ "$wrapper_owner" != "root:root" ]; then
  echo -e "${RED}[ERROR]${NC} Wrapper owner is ${wrapper_owner}, expected root:root"
  exit 1
fi

if [ "$wrapper_perms" != "755" ]; then
  echo -e "${RED}[ERROR]${NC} Wrapper permissions are ${wrapper_perms}, expected 755"
  exit 1
fi

echo -e "${GREEN}[OK]${NC} Wrapper is securely configured (owner: ${wrapper_owner}, permissions: ${wrapper_perms})"

# 3. Perform a container execution test using systemd-nspawn
echo -e "\n3. Performing a container execution test using systemd-nspawn..."

# Ensure host has a valid /etc/machine-id which systemd-nspawn requires
if [ ! -s /etc/machine-id ]; then
  echo "Initializing host /etc/machine-id..."
  if command -v systemd-machine-id-setup >/dev/null 2>&1; then
    sudo systemd-machine-id-setup || true
  elif command -v dbus-uuidgen >/dev/null 2>&1; then
    sudo dbus-uuidgen --ensure=/etc/machine-id || true
  else
    echo "$(od -An -N16 -tx /dev/urandom | tr -d '[:space:]')" | sudo tee /etc/machine-id >/dev/null || true
  fi
fi

# Ensure D-Bus system message bus is running, which systemd-nspawn requires to avoid D-Bus socket errors
if [ ! -S /run/dbus/system_bus_socket ]; then
  echo "Starting D-Bus system message bus daemon..."
  sudo mkdir -p /run/dbus || true
  if command -v dbus-daemon >/dev/null 2>&1; then
    sudo dbus-daemon --system --fork || true
  fi
fi

TEST_DIR=$(mktemp -d /tmp/nspawn-test.XXXXXX)
cleanup() {
  echo "Cleaning up temporary rootfs..."
  sudo rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Construct a minimal rootfs for systemd-nspawn validation
mkdir -p "$TEST_DIR/usr/lib"
mkdir -p "$TEST_DIR/etc"
ln -sf usr/lib "$TEST_DIR/lib"
ln -sf usr/lib "$TEST_DIR/lib64"
touch "$TEST_DIR/usr/lib/os-release"

# Copy machine-id to target chroot
if [ -f /etc/machine-id ]; then
  sudo cp /etc/machine-id "$TEST_DIR/etc/machine-id"
fi

# Run a true command inside the container using systemd-nspawn
# Note: we run under sudo and do NOT specify --register=no.
# The wrapper in /usr/local/bin/systemd-nspawn must automatically intercept this
# and append --register=no to avoid the D-Bus systemd scope error.
echo "Invoking: sudo systemd-nspawn -D $TEST_DIR --bind=/usr /usr/bin/true"
if sudo systemd-nspawn -D "$TEST_DIR" --bind=/usr /usr/bin/true; then
  echo -e "\n${GREEN}[SUCCESS]${NC} systemd-nspawn executed successfully without any scope allocation errors!"
  exit 0
else
  echo -e "\n${RED}[FAILURE]${NC} systemd-nspawn execution failed!"
  exit 1
fi
