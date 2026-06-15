# Test helper for Arch Repository System tests

# Source common core to make logging macros and config available
source "$(dirname "${BASH_SOURCE[0]}")/../src/common.sh"

SANDBOX_DIR="${WORKSPACE_DIR}/tests/sandbox"
MOCKS_DIR="${WORKSPACE_DIR}/tests/mocks"

setup_sandbox() {
  # Clean up existing sandbox and mocks
  teardown_sandbox
  
  # Create directories
  mkdir -p "$SANDBOX_DIR"
  mkdir -p "$MOCKS_DIR"
  
  # Setup mock commands
  setup_mocks
  
  # Copy source files to sandbox
  cp -r "${WORKSPACE_DIR}/src" "$SANDBOX_DIR/"
  cp -r "${WORKSPACE_DIR}/templates" "$SANDBOX_DIR/"
  cp "${WORKSPACE_DIR}/config.conf" "$SANDBOX_DIR/"
  cp "${WORKSPACE_DIR}/manage.sh" "$SANDBOX_DIR/"
  cp "${WORKSPACE_DIR}/build.sh" "$SANDBOX_DIR/"
  cp "${WORKSPACE_DIR}/git-bare-worktree.sh" "$SANDBOX_DIR/"
  
  # Initialize git repository in sandbox
  cd "$SANDBOX_DIR" || exit 1
  git init --quiet
  git config user.email "test@example.com"
  git config user.name "Test Admin"
  
  # Create initial commit on master
  echo "init" > readme
  git add readme .gitignore config.conf templates/ 2>/dev/null || git add readme config.conf templates/
  git commit -m "init" --quiet
  
  # Prepend mocks directory to PATH so scripts use mock tools
  export PATH="${MOCKS_DIR}:${PATH}"
  export WORKSPACE_DIR="$SANDBOX_DIR"
}

teardown_sandbox() {
  # Restore workspace dir
  export WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  # Restore PATH
  export PATH="${PATH#$MOCKS_DIR:}"
  
  # Remove sandbox and mocks directories
  rm -rf "$SANDBOX_DIR"
  rm -rf "$MOCKS_DIR"
}

setup_mocks() {
  # 1. Mock curl
  cat <<'EOF' > "${MOCKS_DIR}/curl"
#!/usr/bin/env bash
# Inspect curl query
url="$*"
if [[ "$url" =~ "type=info&arg[]=librewolf-bin" ]]; then
  echo '{"results":[{"Version":"125.0.0-1","PackageBase":"librewolf-bin","Name":"librewolf-bin"}]}'
elif [[ "$url" =~ "type=info&arg[]=test-package" ]]; then
  echo '{"results":[{"Version":"2.0.0-1","PackageBase":"test-package","Name":"test-package"}]}'
elif [[ "$url" =~ "releases/latest" ]]; then
  echo '{"tag_name": "v3.1.0"}'
else
  # Empty results
  echo '{"results":[]}'
fi
EOF
  chmod +x "${MOCKS_DIR}/curl"

  # 2. Mock makepkg
  cat <<'EOF' > "${MOCKS_DIR}/makepkg"
#!/usr/bin/env bash
# Reads PKGBUILD to get name, ver, rel
pkgname=""
pkgver=""
pkgrel=""

# Source PKGBUILD or parse it
if [ -f PKGBUILD ]; then
  if grep -q "invalid-syntax" PKGBUILD; then
    echo "Mock compilation error: invalid syntax detected." >&2
    exit 1
  fi
  # Evaluate version variables
  pkgname=$(grep -E "^pkgname=" PKGBUILD | cut -d'=' -f2- | tr -d '"'\')
  pkgver=$(grep -E "^pkgver=" PKGBUILD | cut -d'=' -f2- | tr -d '"'\')
  pkgrel=$(grep -E "^pkgrel=" PKGBUILD | cut -d'=' -f2- | tr -d '"'\')
fi

pkgname="${pkgname:-test-pkg}"
pkgver="${pkgver:-1.0.0}"
pkgrel="${pkgrel:-1}"

# Handle pkgver update (VCS mode)
# If arguments contain -o or -d, we simulate updating PKGBUILD version
for arg in "$@"; do
  if [ "$arg" = "-od" ] || [ "$arg" = "-o" ]; then
    # VCS pkgver update simulation
    # Increase pkgver to 1.1.0
    sed -i 's/pkgver=.*/pkgver=1.1.0/g' PKGBUILD
    exit 0
  fi
done

# Touch a mock built package archive
touch "${pkgname}-${pkgver}-${pkgrel}-any.pkg.tar.zst"
if [ "$pkgname" = "librewolf-bin" ]; then
  touch "${pkgname}-debug-${pkgver}-${pkgrel}-any.pkg.tar.zst"
fi
exit 0
EOF
  chmod +x "${MOCKS_DIR}/makepkg"

  # 3. Mock repo-add
  cat <<'EOF' > "${MOCKS_DIR}/repo-add"
#!/usr/bin/env bash
db_file=""
pkg_files=()

# Parse arguments, skipping options
for arg in "$@"; do
  if [[ "$arg" = *.db.tar.* ]]; then
    db_file="$arg"
  elif [[ "$arg" = *.pkg.tar.* ]]; then
    pkg_files+=("$arg")
  fi
done

if [ -z "$db_file" ] || [ ${#pkg_files[@]} -eq 0 ]; then
  echo "Usage: repo-add [options] <path-to-db> <package-file>..."
  exit 1
fi

tmp_tar_dir=$(mktemp -d)

# Extract existing database entries if database file already exists
if [ -f "$db_file" ]; then
  tar -xf "$db_file" -C "$tmp_tar_dir" >/dev/null 2>&1
fi

# Add entries for each package
for pkg_file in "${pkg_files[@]}"; do
  pkg_filename=$(basename "$pkg_file")
  temp="${pkg_filename%.pkg.tar.*}"
  dir_name="${temp%-*}" # e.g. librewolf-bin-125.0.0-1
  mkdir -p "${tmp_tar_dir}/${dir_name}"
  touch "${tmp_tar_dir}/${dir_name}/desc"
done

# Package all folder structures into target db file
tar -czf "$db_file" -C "$tmp_tar_dir" . >/dev/null 2>&1
rm -rf "$tmp_tar_dir"

# Sign database file if --sign option is present
for arg in "$@"; do
  if [ "$arg" = "--sign" ]; then
    touch "${db_file}.sig"
  fi
done

exit 0
EOF
  chmod +x "${MOCKS_DIR}/repo-add"
  
  # 4. Mock extra-x86_64-build
  cat <<'EOF' > "${MOCKS_DIR}/extra-x86_64-build"
#!/usr/bin/env bash
echo "$@" >> "${WORKSPACE_DIR}/extra_x86_64_build_args.log"
# Just run local mock makepkg
makepkg
EOF
  chmod +x "${MOCKS_DIR}/extra-x86_64-build"

  # 5. Mock gpg
  local real_gpg
  real_gpg=$(which gpg 2>/dev/null || command -v gpg 2>/dev/null)
  if [ -n "$real_gpg" ] && [ "$real_gpg" != "${MOCKS_DIR}/gpg" ]; then
    real_gpg=$(readlink -f "$real_gpg" 2>/dev/null || echo "$real_gpg")
  else
    real_gpg=""
  fi

  cat <<EOF > "${MOCKS_DIR}/gpg"
#!/usr/bin/env bash
if [[ "\$*" =~ "--recv-keys" ]]; then
  # Extract key ID (last argument)
  key_id="\${@: -1}"
  echo "\$key_id" >> "\${WORKSPACE_DIR}/gpg_imports.log"
  exit 0
fi

if [[ "\$*" =~ "--list-keys" ]]; then
  key_id="\${@: -1}"
  if [ -f "\${WORKSPACE_DIR}/gpg_imports.log" ] && grep -q -F "\$key_id" "\${WORKSPACE_DIR}/gpg_imports.log"; then
    exit 0
  else
    if [ -n "${real_gpg}" ] && [ -x "${real_gpg}" ]; then
      exec "${real_gpg}" "\$@"
    else
      exit 1
    fi
  fi
fi

if [[ "\$*" =~ "--detach-sign" ]]; then
  file_to_sign="\${@: -1}"
  touch "\${file_to_sign}.sig"
  exit 0
fi

# Fallback to real gpg if it exists and is not this mock
if [ -n "${real_gpg}" ] && [ -x "${real_gpg}" ]; then
  exec "${real_gpg}" "\$@"
else
  exit 0
fi
EOF
  chmod +x "${MOCKS_DIR}/gpg"

  # 6. Mock stat
  local real_stat
  real_stat=$(which stat 2>/dev/null || command -v stat 2>/dev/null)
  if [ -n "$real_stat" ] && [ "$real_stat" != "${MOCKS_DIR}/stat" ]; then
    real_stat=$(readlink -f "$real_stat" 2>/dev/null || echo "$real_stat")
  else
    real_stat=""
  fi

  cat <<EOF > "${MOCKS_DIR}/stat"
#!/usr/bin/env bash
if [[ "\$*" =~ "mock_gpg_home" ]] && [[ "\$*" =~ "%u" ]]; then
  echo "9999"
  exit 0
fi
if [ -n "${real_stat}" ] && [ -x "${real_stat}" ]; then
  exec "${real_stat}" "\$@"
else
  exit 0
fi
EOF
  chmod +x "${MOCKS_DIR}/stat"

  # 7. Mock sudo
  cat <<'EOF' > "${MOCKS_DIR}/sudo"
#!/usr/bin/env bash
exec "$@"
EOF
  chmod +x "${MOCKS_DIR}/sudo"
}

# Assertion Utilities
assert_equals() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  if [ "$expected" != "$actual" ]; then
    echo -e "  \033[1;31m[FAIL]\033[0m ${msg}"
    echo "         Expected: '${expected}'"
    echo "         Actual:   '${actual}'"
    TEST_FAILED=1
    return 1
  else
    echo -e "  \033[1;32m[PASS]\033[0m ${msg}"
    return 0
  fi
}

assert_success() {
  local cmd="$1"
  local msg="$2"
  eval "$cmd" >/dev/null 2>&1
  local status=$?
  assert_equals "0" "$status" "$msg (Expected command success)"
}

assert_failure() {
  local cmd="$1"
  local msg="$2"
  eval "$cmd" >/dev/null 2>&1
  local status=$?
  if [ "$status" -eq 0 ]; then
    echo -e "  \033[1;31m[FAIL]\033[0m ${msg} (Expected command failure, but got success)"
    TEST_FAILED=1
    return 1
  else
    echo -e "  \033[1;32m[PASS]\033[0m ${msg} (Command failed as expected)"
    return 0
  fi
}

assert_file_exists() {
  local file="$1"
  local msg="$2"
  if [ -f "$file" ]; then
    echo -e "  \033[1;32m[PASS]\033[0m ${msg} (File exists: ${file})"
    return 0
  else
    echo -e "  \033[1;31m[FAIL]\033[0m ${msg} (File does not exist: ${file})"
    TEST_FAILED=1
    return 1
  fi
}

assert_file_not_exists() {
  local file="$1"
  local msg="$2"
  if [ ! -f "$file" ]; then
    echo -e "  \033[1;32m[PASS]\033[0m ${msg} (File correctly absent: ${file})"
    return 0
  else
    echo -e "  \033[1;31m[FAIL]\033[0m ${msg} (File exists when it should not: ${file})"
    TEST_FAILED=1
    return 1
  fi
}
