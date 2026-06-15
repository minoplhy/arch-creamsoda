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

# 4. Verify Docker cache configuration and permissions
echo -e "\n4. Verifying Docker cache configuration and permissions..."
if [ ! -d /var/cache/sources ]; then
  echo -e "${RED}[ERROR]${NC} /var/cache/sources directory does not exist!"
  exit 1
fi

sources_perms=$(stat -c '%a' /var/cache/sources)
if [ "$sources_perms" != "777" ]; then
  echo -e "${RED}[ERROR]${NC} /var/cache/sources permissions are ${sources_perms}, expected 777"
  exit 1
fi
echo -e "${GREEN}[OK]${NC} /var/cache/sources directory is globally writable (777)"

if [ ! -d /var/cache/ccache ]; then
  echo -e "${RED}[ERROR]${NC} /var/cache/ccache directory does not exist!"
  exit 1
fi

ccache_perms=$(stat -c '%a' /var/cache/ccache)
if [ "$ccache_perms" != "777" ]; then
  echo -e "${RED}[ERROR]${NC} /var/cache/ccache permissions are ${ccache_perms}, expected 777"
  exit 1
fi
echo -e "${GREEN}[OK]${NC} /var/cache/ccache directory is globally writable (777)"

# Check etc makepkg.conf
etc_srcdest=$(grep "^SRCDEST=" /etc/makepkg.conf | cut -d= -f2 | tr -d '"' || true)
if [ "$etc_srcdest" != "/var/cache/sources" ]; then
  echo -e "${RED}[ERROR]${NC} /etc/makepkg.conf SRCDEST is '${etc_srcdest}', expected '/var/cache/sources'"
  exit 1
fi
echo -e "${GREEN}[OK]${NC} /etc/makepkg.conf SRCDEST is correctly set to /var/cache/sources"

if ! grep -q 'if \[ -f /.dockerenv \]; then export GNUPGHOME="${WORKSPACE_DIR:-/workspace}/.gnupg"; fi' /etc/makepkg.conf; then
  echo -e "${RED}[ERROR]${NC} /etc/makepkg.conf does not set GNUPGHOME conditionally!"
  exit 1
fi
echo -e "${GREEN}[OK]${NC} /etc/makepkg.conf GNUPGHOME is correctly set conditionally"

# Check makepkg ccache/MAKEFLAGS options
if grep -E "^(BUILDENV|OPTIONS)=" /etc/makepkg.conf | grep -q "!ccache"; then
  echo -e "${RED}[ERROR]${NC} /etc/makepkg.conf has ccache disabled via '!ccache'!"
  exit 1
fi
if ! grep -E "^(BUILDENV|OPTIONS)=" /etc/makepkg.conf | grep -q "ccache"; then
  echo -e "${RED}[ERROR]${NC} /etc/makepkg.conf does not enable 'ccache' in BUILDENV or OPTIONS!"
  exit 1
fi
if ! grep -q 'CCACHE_DIR="/var/cache/ccache"' /etc/makepkg.conf; then
  echo -e "${RED}[ERROR]${NC} /etc/makepkg.conf CCACHE_DIR is not set to /var/cache/ccache!"
  exit 1
fi
if ! grep -q 'MAKEFLAGS="-j$(($(nproc) > 1 ? $(nproc) - 1 : 1))"' /etc/makepkg.conf; then
  echo -e "${RED}[ERROR]${NC} /etc/makepkg.conf MAKEFLAGS is not configured with dynamic core formula!"
  exit 1
fi
echo -e "${GREEN}[OK]${NC} /etc/makepkg.conf ccache and MAKEFLAGS are correctly configured"

# Check devtools makepkg.conf
if [ -f /usr/share/devtools/makepkg-x86_64.conf ]; then
  devtools_srcdest=$(grep "^SRCDEST=" /usr/share/devtools/makepkg-x86_64.conf | cut -d= -f2 | tr -d '"' || true)
  if [ "$devtools_srcdest" != "/var/cache/sources" ]; then
    echo -e "${RED}[ERROR]${NC} /usr/share/devtools/makepkg-x86_64.conf SRCDEST is '${devtools_srcdest}', expected '/var/cache/sources'"
    exit 1
  fi
  echo -e "${GREEN}[OK]${NC} /usr/share/devtools/makepkg-x86_64.conf SRCDEST is correctly set to /var/cache/sources"
  
  if ! grep -q 'if \[ -f /.dockerenv \]; then export GNUPGHOME="${WORKSPACE_DIR:-/workspace}/.gnupg"; fi' /usr/share/devtools/makepkg-x86_64.conf; then
    echo -e "${RED}[ERROR]${NC} /usr/share/devtools/makepkg-x86_64.conf does not set GNUPGHOME conditionally!"
    exit 1
  fi
  echo -e "${GREEN}[OK]${NC} /usr/share/devtools/makepkg-x86_64.conf GNUPGHOME is correctly set conditionally"

  if grep -E "^(BUILDENV|OPTIONS)=" /usr/share/devtools/makepkg-x86_64.conf | grep -q "!ccache"; then
    echo -e "${RED}[ERROR]${NC} /usr/share/devtools/makepkg-x86_64.conf has ccache disabled via '!ccache'!"
    exit 1
  fi
  if ! grep -E "^(BUILDENV|OPTIONS)=" /usr/share/devtools/makepkg-x86_64.conf | grep -q "ccache"; then
    echo -e "${RED}[ERROR]${NC} /usr/share/devtools/makepkg-x86_64.conf does not enable 'ccache' in BUILDENV or OPTIONS!"
    exit 1
  fi
  if ! grep -q 'CCACHE_DIR="/var/cache/ccache"' /usr/share/devtools/makepkg-x86_64.conf; then
    echo -e "${RED}[ERROR]${NC} /usr/share/devtools/makepkg-x86_64.conf CCACHE_DIR is not set to /var/cache/ccache!"
    exit 1
  fi
  if ! grep -q 'MAKEFLAGS="-j$(($(nproc) > 1 ? $(nproc) - 1 : 1))"' /usr/share/devtools/makepkg-x86_64.conf; then
    echo -e "${RED}[ERROR]${NC} /usr/share/devtools/makepkg-x86_64.conf MAKEFLAGS is not configured with dynamic core formula!"
    exit 1
  fi
  echo -e "${GREEN}[OK]${NC} /usr/share/devtools/makepkg-x86_64.conf ccache and MAKEFLAGS are correctly configured"
fi

# Run a true command inside the container using systemd-nspawn
# Note: we run under sudo and do NOT specify --register=no.
# The wrapper in /usr/local/bin/systemd-nspawn must automatically intercept this
# and append --register=no to avoid the D-Bus systemd scope error.
echo "Invoking: sudo systemd-nspawn -D $TEST_DIR --bind=/usr /usr/bin/true"
if sudo systemd-nspawn -D "$TEST_DIR" --bind=/usr /usr/bin/true; then
  echo -e "\n${GREEN}[SUCCESS]${NC} systemd-nspawn executed successfully without any scope allocation errors!"
else
  echo -e "\n${RED}[FAILURE]${NC} systemd-nspawn execution failed!"
  exit 1
fi

# 5. Verify the actual system extra-x86_64-build / archbuild option parsing behavior
echo -e "\n5. Verifying system archbuild / makechrootpkg argument flow..."
archbuild_path=$(which archbuild 2>/dev/null || which extra-x86_64-build 2>/dev/null || echo "/usr/bin/archbuild")

if [ -f "$archbuild_path" ]; then
  # Verify that the usage line defines passing makechrootpkg args after the first double-dash
  usage_line=$(grep "Usage:.*--" "$archbuild_path" || true)
  optind_line=$(grep "OPTIND" "$archbuild_path" || true)
  
  if [ -n "$usage_line" ] && [ -n "$optind_line" ]; then
    echo "Found usage line: ${usage_line}"
    echo "Found OPTIND line: ${optind_line}"
    echo -e "${GREEN}[OK]${NC} The system devtools script correctly expects makechrootpkg arguments after the '--' separator."
  else
    echo -e "${RED}[ERROR]${NC} Could not verify option forwarding pattern in ${archbuild_path}"
    exit 1
  fi
else
  echo -e "${RED}[ERROR]${NC} devtools archbuild script not found at ${archbuild_path}!"
  exit 1
fi

echo -e "\n${GREEN}=== All systemd-nspawn and devtools integration tests passed successfully! ===${NC}"
exit 0
