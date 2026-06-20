# Package manager key management module
# Sources common.sh

import_gpg_keys() {
  if [ "$#" -eq 0 ]; then
    log_error "At least one GPG key ID or file path is required."
    exit 1
  fi
  
  local gpg_opts=("--no-permission-warning")
  if [ -n "${GNUPGHOME:-}" ]; then
    gpg_opts+=("--homedir" "$GNUPGHOME")
  fi
  
  for target in "$@"; do
    if [ -f "$target" ]; then
      log_info "Importing GPG key from file: ${target}..."
      if gpg "${gpg_opts[@]}" --import "$target"; then
        log_success "Successfully imported GPG key from file: ${target}"
      else
        log_error "Failed to import GPG key from file: ${target}"
        exit 1
      fi
    else
      log_info "Importing GPG key '${target}' from keyserver..."
      if gpg "${gpg_opts[@]}" --keyserver hkps://keyserver.ubuntu.com --recv-keys "$target"; then
        log_success "Successfully imported GPG key '${target}'"
      else
        log_warning "Failed to import from keyserver.ubuntu.com. Trying pgp.mit.edu..."
        if gpg "${gpg_opts[@]}" --keyserver hkp://pgp.mit.edu --recv-keys "$target"; then
          log_success "Successfully imported GPG key '${target}'"
        else
          log_error "Failed to import GPG key '${target}'"
          exit 1
        fi
      fi
    fi
  done
}

list_gpg_keys() {
  local gpg_opts=("--no-permission-warning")
  if [ -n "${GNUPGHOME:-}" ]; then
    gpg_opts+=("--homedir" "$GNUPGHOME")
  fi

  if [ -n "${GNUPGHOME:-}" ]; then
    log_info "Listing keys in GNUPG keyring (${GNUPGHOME}):"
    if [ -d "$GNUPGHOME" ]; then
      gpg "${gpg_opts[@]}" --list-keys
    else
      log_warning "GPG directory '${GNUPGHOME}' does not exist yet."
    fi
  else
    log_info "Listing keys in system default GNUPG keyring:"
    gpg "${gpg_opts[@]}" --list-keys
  fi
}

sign_repository() {
  local gpg_key="${GPG_KEY:-}"
  local gnupg_home="${GNUPGHOME:-}"
  
  # Parse arguments
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --key)
        gpg_key="$2"
        shift 2
        ;;
      --gnupghome)
        gnupg_home="$2"
        shift 2
        ;;
      *)
        log_error "Unknown option: $1"
        exit 1
        ;;
    esac
  done
  
  if [ -z "$gpg_key" ]; then
    log_error "GPG Key ID is required for signing. Please specify with --key <key_id> or configure GPG_KEY in config.conf."
    exit 1
  fi
  
  # Set up GPG options
  local gpg_opts=("--no-permission-warning")
  if [ -n "$gnupg_home" ]; then
    gpg_opts+=("--homedir" "$gnupg_home")
  fi
  
  # Verify that the key is present in the keyring
  if ! gpg "${gpg_opts[@]}" --list-keys "$gpg_key" >/dev/null 2>&1; then
    log_error "GPG Key '$gpg_key' was not found in the keyring."
    if [ -n "$gnupg_home" ]; then
      log_error "Check that the key has been imported into GNUPGHOME '$gnupg_home'."
    else
      log_error "Import it first using: ./manage.sh import-key $gpg_key"
    fi
    exit 1
  fi
  
  log_info "Signing all packages in the repository with key '$gpg_key'..."
  local signed_packages_count=0
  for pkg in "${REPO_DIR}"/*.pkg.tar.*; do
    [ -e "$pkg" ] || continue
    [[ "$pkg" =~ \.sig$ ]] && continue
    [[ "$pkg" =~ \.log$ ]] && continue
    
    log_info "Signing package $(basename "$pkg")..."
    local p_gpg_opts=("${gpg_opts[@]}" "--detach-sign" "--no-armor" "--use-agent" "-u" "$gpg_key")
    rm -f "${pkg}.sig"
    if gpg "${p_gpg_opts[@]}" "$pkg"; then
      signed_packages_count=$((signed_packages_count + 1))
    else
      log_error "Failed to sign package: $(basename "$pkg")"
      exit 1
    fi
  done
  
  log_info "Signing database and files files..."
  local signed_db_count=0
  for db in "${REPO_DIR}"/*.db.tar.gz "${REPO_DIR}"/*.files.tar.gz; do
    [ -e "$db" ] || continue
    log_info "Signing database $(basename "$db")..."
    local d_gpg_opts=("${gpg_opts[@]}" "--detach-sign" "--no-armor" "--use-agent" "-u" "$gpg_key")
    rm -f "${db}.sig"
    if gpg "${d_gpg_opts[@]}" "$db"; then
      signed_db_count=$((signed_db_count + 1))
    else
      log_error "Failed to sign database: $(basename "$db")"
      exit 1
    fi
  done
  
  # Re-link signature files if symlinks exist
  for sym in "${REPO_DIR}"/*.db "${REPO_DIR}"/*.files; do
    if [ -L "$sym" ]; then
      local target
      target=$(readlink "$sym")
      if [ -f "${sym%/*}/${target}.sig" ]; then
        rm -f "${sym}.sig"
        ln -s "${target}.sig" "${sym}.sig"
      fi
    fi
  done
  
  log_success "Successfully signed $signed_packages_count packages and $signed_db_count database files."
  
  # Forward compatibility: Update config.conf to set SIGN_PACKAGES="true" and save the key
  log_info "Updating config.conf to persist signing configuration..."
  update_config_key "SIGN_PACKAGES" "true"
  update_config_key "GPG_KEY" "$gpg_key"
  if [ -n "$gnupg_home" ]; then
    update_config_key "GNUPGHOME" "$gnupg_home"
  fi
}

unsign_repository() {
  log_info "Removing all signatures from the repository directory..."
  rm -f "${REPO_DIR}"/*.sig
  log_success "All signatures removed from the repository."
  
  # Forward compatibility: Update config.conf to set SIGN_PACKAGES="false"
  log_info "Updating config.conf to disable signing..."
  update_config_key "SIGN_PACKAGES" "false"
}
