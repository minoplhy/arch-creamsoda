# Repository publishing module
# Sources common.sh

publish_repository() {
  log_info "Preparing to publish repository..."
  
  if [ -z "$PUBLISH_DEST" ]; then
    log_warning "PUBLISH_DEST is not configured in config.conf."
    log_info "--------------------------------------------------------------------------------"
    log_info "To publish your repository, you have two primary options:"
    log_info ""
    log_info "Option A: Remote Web Server Hosting (via rsync)"
    log_info "  1. Set PUBLISH_DEST=\"user@yourserver.com:/var/www/html/repo/\" in config.conf"
    log_info "  2. Ensure SSH access and rsync are installed on both host and target."
    log_info "  3. Re-run: ./manage.sh publish"
    log_info ""
    log_info "Option B: GitHub / GitLab Pages hosting"
    log_info "  1. Enable GitHub Pages on your repository and set it to publish from a branch (e.g. gh-pages)."
    log_info "  2. Commit the repository database files (*.db.tar.gz, *.files.tar.gz) to that branch."
    log_info "  3. Host the large package files (*.pkg.tar.zst) on GitHub Releases under a release tag."
    log_info "  4. Set your client's Server URL to the Release download URL:"
    log_info "     Server = https://github.com/USER/REPO/releases/download/TAG"
    log_info "--------------------------------------------------------------------------------"
    return 1
  fi

  log_info "Syncing repository files to destination: ${PUBLISH_DEST}..."
  
  # Ensure rsync is installed
  if ! command -v rsync >/dev/null 2>&1; then
    log_error "rsync is required but not installed on this system."
    return 1
  fi

  # Run rsync command
  # -a: archive mode
  # -v: verbose
  # -z: compress during transfer
  # --delete: delete extraneous files from dest dirs (cleans up old packages)
  # --exclude: exclude lock files and local status metadata
  rsync -avz --delete --exclude="repo.lock" --exclude="status.json" "${REPO_DIR}/" "$PUBLISH_DEST"
  local status=$?

  if [ $status -eq 0 ]; then
    log_success "Repository successfully published to ${PUBLISH_DEST}!"
    return 0
  else
    log_error "Failed to publish repository. rsync exited with status ${status}."
    return 1
  fi
}
