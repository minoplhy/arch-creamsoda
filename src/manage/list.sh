# Package listing module
# Sources common.sh

# Safe pure-bash PKGBUILD version parser (avoids code execution)
parse_pkgbuild_version() {
  local content="$1"
  local pkgver=""
  local pkgrel=""
  local epoch=""
  
  while IFS= read -r line; do
    # Remove comments
    line="${line%%#*}"
    # Trim leading/trailing whitespace
    line=$(echo "$line" | xargs 2>/dev/null || echo "$line")
    
    if [[ "$line" =~ ^pkgver= ]]; then
      pkgver="${line#pkgver=}"
      pkgver="${pkgver#\"}"
      pkgver="${pkgver%\"}"
      pkgver="${pkgver#\'}"
      pkgver="${pkgver%\'}"
    elif [[ "$line" =~ ^pkgrel= ]]; then
      pkgrel="${line#pkgrel=}"
      pkgrel="${pkgrel#\"}"
      pkgrel="${pkgrel%\"}"
      pkgrel="${pkgrel#\'}"
      pkgrel="${pkgrel%\'}"
    elif [[ "$line" =~ ^epoch= ]]; then
      epoch="${line#epoch=}"
      epoch="${epoch#\"}"
      epoch="${epoch%\"}"
      epoch="${epoch#\'}"
      epoch="${epoch%\'}"
    fi
  done <<< "$content"

  if [ -n "$pkgver" ] && [ -n "$pkgrel" ]; then
    if [ -n "$epoch" ]; then
      echo "${epoch}:${pkgver}-${pkgrel}"
    else
      echo "${pkgver}-${pkgrel}"
    fi
  else
    echo "unknown"
  fi
}

list_packages() {
  # Find all local branches excluding master and main
  local branches
  branches=$(git for-each-ref --format='%(refname:short)' refs/heads/)
  
  log_info "Listing registered packages in the repository system:"
  echo -e "--------------------------------------------------------------------------------"
  printf "%-20s %-15s %-15s %-25s\n" "PACKAGE NAME" "VERSION" "TRACKING" "STATUS"
  echo -e "--------------------------------------------------------------------------------"

  local count=0
  for branch in $branches; do
    if [ "$branch" = "master" ] || [ "$branch" = "main" ] || [[ "$branch" == upgrade-* ]] || [[ "$branch" == upgrade/* ]] || [[ "$branch" == updates-* ]] || [[ "$branch" == updates/* ]]; then
      continue
    fi
    
    count=$((count + 1))
    
    # Read PKGBUILD from git branch directly
    local pkgbuild_content
    pkgbuild_content=$(git show "${branch}:PKGBUILD" 2>/dev/null)
    local version
    version=$(parse_pkgbuild_version "$pkgbuild_content")

    # Read .pkgconfig from git branch directly
    local pkgconfig_content
    pkgconfig_content=$(git show "${branch}:.pkgconfig" 2>/dev/null)
    
    # Extract tracking mode
    local tracking="source (default)"
    if [ -n "$pkgconfig_content" ]; then
      local track_mode
      track_mode=$(echo "$pkgconfig_content" | grep "^TRACKING_MODE=" | cut -d'=' -f2 | tr -d '"'\')
      if [ -n "$track_mode" ]; then
        tracking="$track_mode"
      fi
    fi

    # Check if worktree directory exists
    local status="Checked out"
    local target_dir="${PACKAGES_DIR}/${branch}"
    if [ ! -d "$target_dir" ]; then
      status="Missing worktree"
    fi

    # Colorize status
    local status_colored="$status"
    if [ "$status" = "Checked out" ]; then
      status_colored="${COLOR_SUCCESS}${status}${COLOR_RESET}"
    else
      status_colored="${COLOR_WARNING}${status}${COLOR_RESET}"
    fi

    printf "%-20s %-15s %-15s %-25b\n" "$branch" "$version" "$tracking" "$status_colored"
  done

  echo -e "--------------------------------------------------------------------------------"
  log_info "Total packages: ${count}"
}
