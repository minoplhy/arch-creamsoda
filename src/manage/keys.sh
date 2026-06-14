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
