# Package manager key management module
# Sources common.sh

import_gpg_keys() {
  if [ "$#" -eq 0 ]; then
    log_error "At least one GPG key ID or file path is required."
    exit 1
  fi
  
  for target in "$@"; do
    if [ -f "$target" ]; then
      log_info "Importing GPG key from file: ${target}..."
      if gpg --import "$target"; then
        log_success "Successfully imported GPG key from file: ${target}"
      else
        log_error "Failed to import GPG key from file: ${target}"
        exit 1
      fi
    else
      log_info "Importing GPG key '${target}' from keyserver..."
      if gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys "$target"; then
        log_success "Successfully imported GPG key '${target}'"
      else
        log_warning "Failed to import from keyserver.ubuntu.com. Trying pgp.mit.edu..."
        if gpg --keyserver hkp://pgp.mit.edu --recv-keys "$target"; then
          log_success "Successfully imported GPG key '${target}'"
        else
          log_error "Failed to import GPG key '${target}'"
          exit 1
        fi
      fi
    fi
  done
}
