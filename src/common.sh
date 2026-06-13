# Shared core utilities for Arch Repository System

# Resolve workspace root directory
WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WORKSPACE_DIR

# Define log levels with colors
COLOR_RESET="\033[0m"
COLOR_INFO="\033[1;34m"    # Bold Blue
COLOR_SUCCESS="\033[1;32m" # Bold Green
COLOR_WARNING="\033[1;33m" # Bold Yellow
COLOR_ERROR="\033[1;31m"   # Bold Red

log_info() {
  echo -e "${COLOR_INFO}[INFO]${COLOR_RESET} $*"
}

log_success() {
  echo -e "${COLOR_SUCCESS}[SUCCESS]${COLOR_RESET} $*"
}

log_warning() {
  echo -e "${COLOR_WARNING}[WARNING]${COLOR_RESET} $*"
}

log_error() {
  echo -e "${COLOR_ERROR}[ERROR]${COLOR_RESET} $*" >&2
}

# Load configuration and set defaults
load_config() {
  # Isolate GPG home to prevent polluting or using developer's personal keyring
  unset GNUPGHOME
  local config_file="${WORKSPACE_DIR}/config.conf"
  if [ -f "$config_file" ]; then
    # shellcheck source=/dev/null
    source "$config_file"
  else
    log_warning "config.conf not found, using default settings."
  fi

  # Set defaults
  export REPO_NAME="${REPO_NAME:-custom}"
  export REPO_DIR="${REPO_DIR:-repo}"
  export PACKAGES_DIR="${PACKAGES_DIR:-packages}"
  export LOG_DIR="${LOG_DIR:-logs}"
  export BUILD_METHOD="${BUILD_METHOD:-makepkg}"
  export SIGN_PACKAGES="${SIGN_PACKAGES:-false}"
  export GPG_KEY="${GPG_KEY:-}"
  export CLEAN_OLD_PACKAGES="${CLEAN_OLD_PACKAGES:-true}"
  export GNUPGHOME="${GNUPGHOME:-${WORKSPACE_DIR}/.gnupg}"
  export CACHE_SOURCES="${CACHE_SOURCES:-true}"
  export SOURCE_CACHE_DIR="${SOURCE_CACHE_DIR:-cache/sources}"
  export CHROOT_DIR="${CHROOT_DIR:-}"
  export CACHE_PACMAN_PACKAGES="${CACHE_PACMAN_PACKAGES:-true}"
  export PACMAN_CACHE_DIR="${PACMAN_CACHE_DIR:-cache/packages}"
  export PUBLISH_DEST="${PUBLISH_DEST:-}"

  # Make paths absolute if they are relative
  [[ "$REPO_DIR" = /* ]] || REPO_DIR="${WORKSPACE_DIR}/${REPO_DIR}"
  [[ "$PACKAGES_DIR" = /* ]] || PACKAGES_DIR="${WORKSPACE_DIR}/${PACKAGES_DIR}"
  [[ "$LOG_DIR" = /* ]] || LOG_DIR="${WORKSPACE_DIR}/${LOG_DIR}"
  [[ "$GNUPGHOME" = /* ]] || GNUPGHOME="${WORKSPACE_DIR}/${GNUPGHOME}"
  [[ "$SOURCE_CACHE_DIR" = /* ]] || SOURCE_CACHE_DIR="${WORKSPACE_DIR}/${SOURCE_CACHE_DIR}"
  [[ "$PACMAN_CACHE_DIR" = /* ]] || PACMAN_CACHE_DIR="${WORKSPACE_DIR}/${PACMAN_CACHE_DIR}"
  if [ -n "$CHROOT_DIR" ]; then
    [[ "$CHROOT_DIR" = /* ]] || CHROOT_DIR="${WORKSPACE_DIR}/${CHROOT_DIR}"
  fi

  export REPO_DIR
  export PACKAGES_DIR
  export LOG_DIR
  export GNUPGHOME
  export SOURCE_CACHE_DIR
  export CHROOT_DIR
  export PACMAN_CACHE_DIR
}

# Verify and create necessary directory structure
init_dirs() {
  mkdir -p "$REPO_DIR"
  mkdir -p "$PACKAGES_DIR"
  mkdir -p "$LOG_DIR"
  if [ -n "$GNUPGHOME" ]; then
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"
  fi
  if [ "$CACHE_SOURCES" = "true" ]; then
    mkdir -p "$SOURCE_CACHE_DIR"
  fi
  if [ "$CACHE_PACMAN_PACKAGES" = "true" ]; then
    mkdir -p "$PACMAN_CACHE_DIR"
  fi
}

# Concurrency locking using file descriptors and flock
LOCK_FD=9
acquire_lock() {
  # Ensure target directory exists before lock file creation
  mkdir -p "$REPO_DIR"
  local lock_file="${REPO_DIR}/repo.lock"
  touch "$lock_file"
  
  # Open file descriptor for lock file
  eval "exec ${LOCK_FD}>\"\$lock_file\""
  
  if ! flock -n $LOCK_FD; then
    log_error "Concurrency Lock Conflict: Another repository modification process is running."
    log_error "Please wait for it to complete or manually remove the lock at: ${lock_file}"
    exit 1
  fi
}

release_lock() {
  if [ -n "$LOCK_FD" ]; then
    flock -u $LOCK_FD 2>/dev/null || true
    eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
  fi
}

# Register exit handler to clean up locks
trap release_lock EXIT
