# Repository branch scanning module
# Sources common.sh and src/manage/version.sh

# shellcheck source=src/manage/version.sh
source "${ENGINE_DIR}/src/manage/version.sh"

scan_packages_for_changes() {
  # Declare global associative array for packages to build
  # Maps pkgname -> local_version
  unset BUILD_QUEUE
  declare -g -A BUILD_QUEUE
  
  # Declare associative array for built versions in database
  declare -A BUILT_VERSIONS

  local db_file="${REPO_DIR}/${REPO_NAME}.db.tar.gz"
  
  if [ -f "$db_file" ]; then
    log_info "Parsing repository database: ${db_file}..."
    local db_entries
    # Extract directory names from tarball (which correspond to package-version-release)
    db_entries=$(tar -tf "$db_file" | grep '/$' | sed 's|/$||' | sort -u)
    
    for entry in $db_entries; do
      # Strip leading relative path prefixes (e.g. ./)
      entry="${entry#./}"
      entry="${entry#/}"
      # Extract parts: package-name-version-release
      # pkgrel is everything after the last hyphen
      local pkgrel="${entry##*-}"
      local temp="${entry%-*}"
      # pkgver is everything after the new last hyphen
      local pkgver="${temp##*-}"
      # pkgname is everything before that
      local pkgname="${temp%-*}"
      
      BUILT_VERSIONS["$pkgname"]="${pkgver}-${pkgrel}"
    done
  else
    log_warning "Repository database '${db_file}' not found. A full build of all packages will be triggered."
  fi

  log_info "Scanning package branches for version bumps..."
  echo -e "--------------------------------------------------------------------------------"
  printf "%-25s %-18s %-18s %-15s\n" "PACKAGE NAME" "GIT VERSION" "BUILT VERSION" "ACTION"
  echo -e "--------------------------------------------------------------------------------"

  local branches
  branches=$(git for-each-ref --format='%(refname:short)' refs/heads/)
  
  local scan_count=0
  local build_count=0

  for branch in $branches; do
    if [ "$branch" = "master" ] || [ "$branch" = "main" ] || [[ "$branch" == upgrade-* ]] || [[ "$branch" == upgrade/* ]] || [[ "$branch" == updates-* ]] || [[ "$branch" == updates/* ]]; then
      continue
    fi
    
    scan_count=$((scan_count + 1))
    
    # Extract git version
    local pkgbuild_content
    pkgbuild_content=$(git show "${branch}:PKGBUILD" 2>/dev/null)
    local git_ver
    git_ver=$(parse_pkgbuild_version "$pkgbuild_content")
    
    # Get built version
    local built_ver="${BUILT_VERSIONS[$branch]}"
    
    local action="SKIP"
    local action_colored="${COLOR_RESET}SKIP${COLOR_RESET}"
    
    if [ -z "$built_ver" ]; then
      action="BUILD (New)"
      action_colored="${COLOR_SUCCESS}BUILD (New)${COLOR_RESET}"
      BUILD_QUEUE["$branch"]="$git_ver"
      build_count=$((build_count + 1))
    else
      local comp
      comp=$(compare_versions "$git_ver" "$built_ver")
      if [ "$comp" -gt 0 ]; then
        action="BUILD (Bump)"
        action_colored="${COLOR_WARNING}BUILD (Bump)${COLOR_RESET}"
        BUILD_QUEUE["$branch"]="$git_ver"
        build_count=$((build_count + 1))
      fi
    fi

    printf "%-25s %-18s %-18s %-15b\n" "$branch" "$git_ver" "${built_ver:-None}" "$action_colored"
  done

  echo -e "--------------------------------------------------------------------------------"
  log_info "Scan complete. Scanned: ${scan_count}, Queue size: ${build_count}"
}
