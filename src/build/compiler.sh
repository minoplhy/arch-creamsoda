# Package compilation and repo registration module
# Sources common.sh

compile_and_register() {
  local build_queue_ref="$1"
  
  # Check if there is work to do
  if [ "${#BUILD_QUEUE[@]}" -eq 0 ]; then
    log_success "No packages require compilation. Repository is up-to-date."
    write_status_json "success" "No updates required"
    return 0
  fi

  log_info "Starting compilation queue of ${#BUILD_QUEUE[@]} packages..."
  
  local success_count=0
  local failure_count=0
  declare -A build_results

  for pkgname in "${!BUILD_QUEUE[@]}"; do
    local version="${BUILD_QUEUE[$pkgname]}"
    local target_dir="${PACKAGES_DIR}/${pkgname}"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local log_file="${LOG_DIR}/${pkgname}-${version}-${timestamp}.log"
    
    log_info "Building '${pkgname}' version ${version}..."
    log_info "Build output will be logged to: ${log_file}"

    if [ ! -d "$target_dir" ]; then
      log_error "Worktree directory '${target_dir}' is missing. Skipping."
      build_results["$pkgname"]="FAILED (Missing worktree)"
      failure_count=$((failure_count + 1))
      continue
    fi

    # Perform compilation
    (
      cd "$target_dir" || exit 1
      log_info "Cleaning build directory..." >> "$log_file" 2>&1
      git clean -xdff -e .pkgconfig >> "$log_file" 2>&1
      
      # Check if validpgpkeys array from PKGBUILD is present in keyring
      local pgp_keys
      pgp_keys=$(bash -c 'source PKGBUILD &>/dev/null && printf "%s\n" "${validpgpkeys[@]}"' 2>/dev/null)
      
      if [ -n "$pgp_keys" ]; then
        if command -v gpg >/dev/null 2>&1; then
          for key in $pgp_keys; do
            if ! gpg --list-keys "$key" >/dev/null 2>&1; then
              log_warning "PGP key '${key}' is required but not present in the keyring."
              log_warning "Please import it manually using: ./manage.sh import-key ${key}"
              log_warning "PGP key '${key}' is missing. You can import it via: ./manage.sh import-key ${key}" >> "$log_file" 2>&1
            fi
          done
        else
          log_warning "GnuPG is not installed. PGP signature verification may fail." >> "$log_file" 2>&1
        fi
      fi

      if [ "$CACHE_SOURCES" = "true" ]; then
        export SRCDEST="$SOURCE_CACHE_DIR"
      fi

      if [ "$BUILD_METHOD" = "chroot" ]; then
        # Validate chroot to auto-recover from interrupted/corrupted builds
        local active_chroot_dir="/var/lib/archbuild"
        if [ -n "$CHROOT_DIR" ]; then
          active_chroot_dir="$CHROOT_DIR"
        fi
        
        local chroot_root_path="${active_chroot_dir}/extra-x86_64/root"
        if [ -d "${active_chroot_dir}/extra-x86_64" ] && [ ! -f "${chroot_root_path}/.arch-chroot" ]; then
          log_warning "Corrupted or incomplete chroot detected at ${chroot_root_path}."
          log_warning "Cleaning up corrupted chroot directory to force a clean re-initialization..."
          log_warning "Corrupted or incomplete chroot detected at ${chroot_root_path}. Cleaning up..." >> "$log_file" 2>&1
          # Clean up using sudo since chroot files are owned by root
          sudo rm -rf "${active_chroot_dir}/extra-x86_64" >> "$log_file" 2>&1 || true
        fi

        log_info "Compiling in clean chroot using extra-x86_64-build..." >> "$log_file" 2>&1
        
        local chroot_opts=()
        if [ -n "$CHROOT_DIR" ]; then
          chroot_opts+=("-r" "$CHROOT_DIR")
        fi
        
        local makechrootpkg_opts=()
        if [ "$CACHE_PACMAN_PACKAGES" = "true" ]; then
          makechrootpkg_opts+=("-d" "${PACMAN_CACHE_DIR}:/var/cache/pacman/pkg")
        fi

        # Extract dependencies from PKGBUILD to only install required local dependencies
        local deps=()
        if [ -f "${target_dir}/PKGBUILD" ]; then
          local raw_deps
          raw_deps=$(bash -c "source '${target_dir}/PKGBUILD' &>/dev/null && printf '%s\n' \"\${depends[@]}\" \"\${makedepends[@]}\"" 2>/dev/null)
          for d in $raw_deps; do
            # Strip version constraints, e.g. "package>=1.0.0" -> "package"
            d=$(echo "$d" | sed -E 's/[<>=].*//')
            deps+=("$d")
          done
        fi

        # Install existing built repository packages into the chroot to satisfy local dependencies
        for f in "${REPO_DIR}"/*.pkg.tar.*; do
          [ -e "$f" ] || continue
          [[ "$f" =~ \.sig$ ]] && continue
          [[ "$f" =~ \.log$ ]] && continue
          
          local base_f=$(basename "$f")
          local temp="${base_f%.pkg.tar.*}"
          temp="${temp%-*}"
          temp="${temp%-*}"
          local pkgname="${temp%-*}"
          
          local matched=false
          for dep in "${deps[@]}"; do
            if [ "$pkgname" = "$dep" ]; then
              matched=true
              break
            fi
          done
          
          if [ "$matched" = true ]; then
            makechrootpkg_opts+=("-I" "$f")
            log_info "Including local repository dependency: $(basename "$f")" >> "$log_file" 2>&1
          fi
        done
        
        extra-x86_64-build "${chroot_opts[@]}" -- "${makechrootpkg_opts[@]}" >> "$log_file" 2>&1
      else
        log_info "Compiling with makepkg..." >> "$log_file" 2>&1
        # makepkg -s (install dependencies), --noconfirm (non-interactive)
        makepkg -s --noconfirm >> "$log_file" 2>&1
      fi
    )
    local compile_status=$?

    if [ $compile_status -eq 0 ]; then
      log_success "Compilation of '${pkgname}' succeeded!"
      
      # Move built packages to repo directory
      local pkg_moved=false
      local active_pkg_files=()
      
      for pkg_file in "${target_dir}"/*.pkg.tar.*; do
        [ -e "$pkg_file" ] || continue
        # Skip source package tarballs (.src.tar.gz) if generated
        [[ "$pkg_file" =~ \.src\.tar\.gz$ ]] && continue
        # Skip signatures generated by makepkg itself if any (we handle signing below)
        [[ "$pkg_file" =~ \.sig$ ]] && continue
        # Skip log files (e.g. namcap logs)
        [[ "$pkg_file" =~ \.log$ ]] && continue
        
        local dest_file="${REPO_DIR}/$(basename "$pkg_file")"
        mv "$pkg_file" "$dest_file"
        active_pkg_files+=("$dest_file")
        pkg_moved=true
        log_info "Moved $(basename "$pkg_file") to repository directory."
      done

      if [ "$pkg_moved" = false ]; then
        log_error "Compilation succeeded but no package files (*.pkg.tar.*) were found in '${target_dir}'."
        build_results["$pkgname"]="FAILED (No package file)"
        failure_count=$((failure_count + 1))
        continue
      fi

      # Optional GPG Signing
      local repo_add_opts=()
      if [ "$SIGN_PACKAGES" = "true" ] && [ -n "$GPG_KEY" ]; then
        for active_pkg_file in "${active_pkg_files[@]}"; do
          log_info "Signing package $(basename "$active_pkg_file") with GPG Key: ${GPG_KEY}..."
          gpg --detach-sign --no-armor --use-agent -u "$GPG_KEY" "$active_pkg_file" >> "$log_file" 2>&1
        done
        repo_add_opts+=("--sign" "--key" "$GPG_KEY")
      fi

      # Add package to repository database
      log_info "Registering package in repository database..."
      local db_file="${REPO_DIR}/${REPO_NAME}.db.tar.gz"
      if repo-add "${repo_add_opts[@]}" "$db_file" "${active_pkg_files[@]}" >> "$log_file" 2>&1; then
        log_success "Package '${pkgname}' registered in database successfully!"
        build_results["$pkgname"]="SUCCESS"
        success_count=$((success_count + 1))

        # Cleanup old package versions if configured
        if [ "$CLEAN_OLD_PACKAGES" = "true" ]; then
          cleanup_old_versions "$pkgname" "${active_pkg_files[@]}"
        fi
      else
        log_error "Failed to add package '${pkgname}' to repository database. Check log: ${log_file}"
        build_results["$pkgname"]="FAILED (repo-add failed)"
        failure_count=$((failure_count + 1))
      fi
    else
      if [ $compile_status -eq 130 ]; then
        log_error "Build run aborted by user (SIGINT)."
        write_status_json "failed" "Aborted by user"
        exit 130
      fi
      log_error "Compilation of '${pkgname}' failed! Check log: ${log_file}"
      build_results["$pkgname"]="FAILED (Compilation error)"
      failure_count=$((failure_count + 1))
    fi
  done

  # Print Summary Report
  echo -e "\n================================================================================"
  log_info "BUILD SUMMARY REPORT"
  echo -e "================================================================================"
  printf "%-25s %-40s\n" "PACKAGE NAME" "BUILD OUTCOME"
  echo -e "--------------------------------------------------------------------------------"
  for pkg in "${!build_results[@]}"; do
    local outcome="${build_results[$pkg]}"
    local colored_outcome="$outcome"
    if [ "$outcome" = "SUCCESS" ]; then
      colored_outcome="${COLOR_SUCCESS}${outcome}${COLOR_RESET}"
    else
      colored_outcome="${COLOR_ERROR}${outcome}${COLOR_RESET}"
    fi
    printf "%-25s %-40b\n" "$pkg" "$colored_outcome"
  done
  echo -e "================================================================================"
  log_info "Succeeded: ${success_count}, Failed: ${failure_count}"

  # Write status JSON
  local overall_status="success"
  [ $failure_count -gt 0 ] && overall_status="failed"
  write_status_json "$overall_status" "Succeeded: ${success_count}, Failed: ${failure_count}"

  [ $failure_count -eq 0 ]
}

cleanup_old_versions() {
  local pkgname="$1"
  shift
  local active_files=("$@")
  
  for f in "${REPO_DIR}/${pkgname}"-*.pkg.tar.*; do
    [ -e "$f" ] || continue
    
    # Check if this file is one of the active files or its signature
    local is_active=false
    for active_file in "${active_files[@]}"; do
      if [ "$(basename "$f")" = "$(basename "$active_file")" ] || [ "$(basename "$f")" = "$(basename "$active_file").sig" ]; then
        is_active=true
        break
      fi
    done
    
    if [ "$is_active" = false ]; then
      log_info "Cleaning up old package file: $(basename "$f")"
      rm -f "$f"
      # Also remove signature file if it exists
      if [ -f "${f}.sig" ]; then
        rm -f "${f}.sig"
      fi
    fi
  done
}

write_status_json() {
  local status="$1"
  local message="$2"
  local status_file="${REPO_DIR}/status.json"
  
  # Gather built package details
  local db_file="${REPO_DIR}/${REPO_NAME}.db.tar.gz"
  local pkg_list_json="[]"
  
  if [ -f "$db_file" ] && command -v tar >/dev/null; then
    local entries
    entries=$(tar -tf "$db_file" | grep '/$' | sed 's|/$||' | sort -u)
    pkg_list_json="["
    local first=true
    for entry in $entries; do
      # Strip leading relative path prefixes (e.g. ./)
      entry="${entry#./}"
      entry="${entry#/}"
      local pkgrel="${entry##*-}"
      local temp="${entry%-*}"
      local pkgver="${temp##*-}"
      local pkgname="${temp%-*}"
      
      if [ "$first" = true ]; then
        first=false
      else
        pkg_list_json="${pkg_list_json},"
      fi
      pkg_list_json="${pkg_list_json}{\"name\":\"${pkgname}\",\"version\":\"${pkgver}-${pkgrel}\"}"
    done
    pkg_list_json="${pkg_list_json}]"
  fi

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Write JSON file
  cat <<EOF > "$status_file"
{
  "status": "${status}",
  "message": "${message}",
  "last_build_time": "${timestamp}",
  "packages": ${pkg_list_json}
}
EOF
}
