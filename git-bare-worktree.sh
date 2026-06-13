#!/usr/bin/env bash
#
# git-bare-worktree.sh
# Automates bare repository cloning and worktree checkouts with remote-tracking branches.
# Designed for clean and observable build environments on build servers.
#

set -euo pipefail

# ANSI color codes for logs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0;0m' # No Color

log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

show_help() {
  cat <<EOF
Usage: $(basename "$0") <command> [arguments...]

Commands:
  setup <remote_url> <bare_path>
    Clones <remote_url> as a bare repository into <bare_path> and configures 
    its fetch refspec to cleanly map remote branches under refs/remotes/origin/*

  update <bare_path>
    Updates the bare repository database by fetching references from remote origin.

  sync <bare_path> <branch_name> <worktree_path>
    Fetches the latest remote refs, updates or creates the local tracking branch 
    pointing to origin/<branch_name> (Option B for observability), and checks 
    it out to <worktree_path> as a worktree.

  sync-packages <bare_path> <packages_dir>
    Fetches remote refs once, scans all remote package branches, and syncs/checkouts 
    them as tracking worktrees under <packages_dir>/<package_name>.

  cleanup <bare_path> <worktree_path>
    Gracefully and forcefully removes the worktree at <worktree_path> and 
    prunes git worktree administrative metadata.

Options:
  -h, --help
    Show this help message.
EOF
}

# Ensure git is available
if ! command -v git &>/dev/null; then
  log_error "git is not installed or not in PATH."
  exit 1
fi

cmd_setup() {
  local remote_url="$1"
  local bare_path="$2"

  if [ -z "$remote_url" ] || [ -z "$bare_path" ]; then
    log_error "Missing required arguments for setup."
    echo "Usage: $0 setup <remote_url> <bare_path>"
    exit 1
  fi

  if [ -d "$bare_path" ] && [ -n "$(ls -A "$bare_path" 2>/dev/null)" ]; then
    # Already exists, check if it's a bare repository
    if git -C "$bare_path" rev-parse --is-bare-repository &>/dev/null; then
      log_info "Bare repository already exists at ${bare_path}. Ensuring fetch refspec is correct..."
    else
      log_error "Directory ${bare_path} is not empty and is not a bare git repository."
      exit 1
    fi
  else
    log_info "Cloning bare repository from ${remote_url} to ${bare_path}..."
    git clone --bare "$remote_url" "$bare_path"
  fi

  # Configure the refspec so that remote branches are tracked under refs/remotes/origin/*
  log_info "Configuring remote tracking refspec..."
  git -C "$bare_path" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"

  # Perform a fetch to populate the refs/remotes/origin/* namespace
  log_info "Fetching latest remote references..."
  git -C "$bare_path" fetch origin --prune

  log_success "Bare repository setup completed at ${bare_path}."
}

cmd_sync() {
  local bare_path="$1"
  local branch_name="$2"
  local worktree_path="$3"

  if [ -z "$bare_path" ] || [ -z "$branch_name" ] || [ -z "$worktree_path" ]; then
    log_error "Missing required arguments for sync."
    echo "Usage: $0 sync <bare_path> <branch_name> <worktree_path>"
    exit 1
  fi

  # Expand paths to absolute to prevent relative path mapping issues in worktrees
  local abs_bare_path
  abs_bare_path=$(mkdir -p "$bare_path" && cd "$bare_path" && pwd)
  
  # Resolve parent dir of worktree before making it absolute
  local worktree_parent
  worktree_parent=$(dirname "$worktree_path")
  local abs_worktree_parent
  abs_worktree_parent=$(mkdir -p "$worktree_parent" && cd "$worktree_parent" && pwd)
  local abs_worktree_path="${abs_worktree_parent}/$(basename "$worktree_path")"

  if [ ! -d "$abs_bare_path" ] || ! git -C "$abs_bare_path" rev-parse --is-bare-repository &>/dev/null; then
    log_error "Invalid bare repository path: ${bare_path}"
    exit 1
  fi

  # Fetch remote branches
  log_info "Fetching latest remote references..."
  git -C "$abs_bare_path" fetch origin --prune

  # Verify the remote branch exists
  local remote_ref="refs/remotes/origin/${branch_name}"
  if ! git -C "$abs_bare_path" show-ref --quiet "$remote_ref"; then
    log_error "Remote branch '${branch_name}' (ref: ${remote_ref}) not found on remote."
    exit 1
  fi

  # Check if the worktree is already registered
  local is_registered=0
  if git -C "$abs_bare_path" worktree list | grep -F "${abs_worktree_path} " >/dev/null 2>&1; then
    is_registered=1
  fi

  if [ $is_registered -eq 1 ]; then
    log_info "Worktree already registered at ${abs_worktree_path}. Updating in-place..."
    # Reset the worktree files directly to match origin/<branch_name>
    # (Allowed on checked out branch directly in worktree, avoids Git branch lock conflicts)
    git -C "$abs_worktree_path" reset --hard "refs/remotes/origin/$branch_name" --quiet
    
    # Removed git clean -fdx to natively protect untracked assets (repo, logs, cache, packages) and only reset tracked files.

    # Initialize and update submodules if .gitmodules exists
    if [ -f "${abs_worktree_path}/.gitmodules" ]; then
      log_info "Submodules configuration (.gitmodules) detected. Updating submodules..."
      git -C "$abs_worktree_path" submodule update --init --recursive
    fi
  else
    # Ensure the local branch is aligned to track the remote branch (Option B for Observability)
    # (Safe because the branch is not checked out yet)
    log_info "Resetting/creating local tracking branch '${branch_name}' to track 'origin/${branch_name}'..."
    git -C "$abs_bare_path" branch -f "$branch_name" "refs/remotes/origin/$branch_name"
    git -C "$abs_bare_path" branch --set-upstream-to="origin/$branch_name" "$branch_name" >/dev/null 2>&1 || true

    # Untracked files and pre-existing directories (.bare, packages) will be natively ignored/preserved.
    # Add the worktree
    log_info "Creating worktree at ${abs_worktree_path} on branch '${branch_name}'..."
    git -C "$abs_bare_path" worktree add --force "$abs_worktree_path" "$branch_name"
    
    # Initialize submodules
    if [ -f "${abs_worktree_path}/.gitmodules" ]; then
      log_info "Submodules configuration (.gitmodules) detected. Initializing submodules..."
      git -C "$abs_worktree_path" submodule update --init --recursive
    fi
  fi

  # Print branch tracking info for observability verification
  log_info "Verifying branch tracking state (observability):"
  (
    cd "$abs_worktree_path"
    git status
    git branch -vv
  )

  log_success "Worktree synced and ready for building at ${abs_worktree_path}."
}

cmd_cleanup() {
  local bare_path="$1"
  local worktree_path="$2"

  if [ -z "$bare_path" ] || [ -z "$worktree_path" ]; then
    log_error "Missing required arguments for cleanup."
    echo "Usage: $0 cleanup <bare_path> <worktree_path>"
    exit 1
  fi

  local abs_bare_path
  abs_bare_path=$(cd "$bare_path" && pwd)
  
  # Resolve worktree parent first, handle cases where directory was deleted
  local abs_worktree_path
  if [ -d "$worktree_path" ]; then
    abs_worktree_path=$(cd "$worktree_path" && pwd)
  else
    local worktree_parent
    worktree_parent=$(dirname "$worktree_path")
    if [ -d "$worktree_parent" ]; then
      abs_worktree_path="$(cd "$worktree_parent" && pwd)/$(basename "$worktree_path")"
    else
      abs_worktree_path="$worktree_path"
    fi
  fi

  if [ ! -d "$abs_bare_path" ] || ! git -C "$abs_bare_path" rev-parse --is-bare-repository &>/dev/null; then
    log_error "Invalid bare repository path: ${bare_path}"
    exit 1
  fi

  log_info "Removing worktree at ${abs_worktree_path}..."
  git -C "$abs_bare_path" worktree remove --force "$abs_worktree_path" 2>/dev/null || true
  rm -rf "$abs_worktree_path"

  log_info "Pruning worktree metadata..."
  git -C "$abs_bare_path" worktree prune

  log_success "Cleanup completed."
}

cmd_update() {
  local bare_path="$1"

  if [ -z "$bare_path" ]; then
    log_error "Missing required arguments for update."
    echo "Usage: $0 update <bare_path>"
    exit 1
  fi

  local abs_bare_path
  abs_bare_path=$(cd "$bare_path" && pwd)

  if [ ! -d "$abs_bare_path" ] || ! git -C "$abs_bare_path" rev-parse --is-bare-repository &>/dev/null; then
    log_error "Invalid bare repository path: ${bare_path}"
    exit 1
  fi

  log_info "Updating bare repository database (fetching from origin)..."
  git -C "$abs_bare_path" fetch origin --prune
  log_success "Bare repository database updated successfully."
}

cmd_sync_packages() {
  local bare_path="$1"
  local packages_dir="$2"

  if [ -z "$bare_path" ] || [ -z "$packages_dir" ]; then
    log_error "Missing required arguments for sync-packages."
    echo "Usage: $0 sync-packages <bare_path> <packages_dir>"
    exit 1
  fi

  local abs_bare_path
  abs_bare_path=$(mkdir -p "$bare_path" && cd "$bare_path" && pwd)

  if [ ! -d "$abs_bare_path" ] || ! git -C "$abs_bare_path" rev-parse --is-bare-repository &>/dev/null; then
    log_error "Invalid bare repository path: ${bare_path}"
    exit 1
  fi

  # Step 1: Update bare repository database
  log_info "Updating bare repository references..."
  git -C "$abs_bare_path" fetch origin --prune

  # Step 2: Query remote branches
  log_info "Scanning package branches from remote tracking references..."
  local branches=()
  while read -r short_ref; do
    # Ensure reference format is origin/<branch_name>
    if [[ "$short_ref" != origin/* ]]; then
      continue
    fi
    local branch_name="${short_ref#origin/}"
    # Ignore main branches, HEAD pointer, and upgrade/PR branches
    if [ "$branch_name" = "master" ] || [ "$branch_name" = "main" ] || [ "$branch_name" = "HEAD" ] || [[ "$branch_name" == upgrade-* ]]; then
      continue
    fi
    branches+=("$branch_name")
  done < <(git -C "$abs_bare_path" for-each-ref --format='%(refname:short)' refs/remotes/origin/)

  log_info "Found ${#branches[@]} package branches to sync."

  # Step 3: Sync each package branch worktree
  for branch_name in "${branches[@]}"; do
    log_info "--------------------------------------------------------------------------------"
    log_info "Syncing package worktree: ${branch_name}"
    log_info "--------------------------------------------------------------------------------"
    cmd_sync "$abs_bare_path" "$branch_name" "${packages_dir}/${branch_name}"
  done

  log_success "All ${#branches[@]} package worktrees synced successfully under ${packages_dir}."
}

# Command Router
cmd="${1:-}"
case "$cmd" in
  setup)
    shift
    cmd_setup "$@"
    ;;
  sync)
    shift
    cmd_sync "$@"
    ;;
  sync-packages)
    shift
    cmd_sync_packages "$@"
    ;;
  update)
    shift
    cmd_update "$@"
    ;;
  cleanup)
    shift
    cmd_cleanup "$@"
    ;;
  -h|--help|"")
    show_help
    ;;
  *)
    log_error "Unknown command: ${cmd}"
    show_help
    exit 1
    ;;
esac
