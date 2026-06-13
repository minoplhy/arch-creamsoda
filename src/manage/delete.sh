# Package deletion module
# Sources common.sh

delete_package() {
  local pkgname="$1"

  if [ -z "$pkgname" ]; then
    log_error "Package name is required."
    exit 1
  fi

  # Check if branch exists
  if ! git show-ref --verify --quiet "refs/heads/${pkgname}"; then
    log_error "Package branch '${pkgname}' does not exist."
    exit 1
  fi

  log_info "Deleting package '${pkgname}'..."

  # Remove worktree if it exists
  local target_dir="${PACKAGES_DIR}/${pkgname}"
  if [ -d "$target_dir" ] || git worktree list | grep -q "${PACKAGES_DIR}/${pkgname}"; then
    log_info "Removing git worktree at ${target_dir}..."
    git worktree remove --force "$target_dir" 2>/dev/null || rm -rf "$target_dir"
  fi

  # Delete local branch
  log_info "Deleting git branch '${pkgname}'..."
  if git branch -D "$pkgname" >/dev/null 2>&1; then
    log_success "Package '${pkgname}' and its branch were successfully deleted."
  else
    log_error "Failed to delete branch '${pkgname}'."
    exit 1
  fi
}
