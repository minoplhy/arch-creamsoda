# Package upgrade module
# Sources common.sh and version.sh

# shellcheck source=src/manage/version.sh
source "${WORKSPACE_DIR}/src/manage/version.sh"

upgrade_package() {
  local pkgname="$1"
  shift # Remove pkgname from args list
  
  # Parse flags
  local force_flag=false
  local ours_flag=false
  local theirs_flag=false
  local abort_flag=false
  local pr_flag=false

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -f|--force|--force-upstream) force_flag=true ;;
      --ours) ours_flag=true ;;
      --theirs) theirs_flag=true ;;
      --abort) abort_flag=true ;;
      --pr) pr_flag=true ;;
      *) log_error "Unknown option: $1"; exit 1 ;;
    esac
    shift
  done

  if [ -z "$pkgname" ]; then
    log_error "Package name is required."
    exit 1
  fi

  local target_dir="${PACKAGES_DIR}/${pkgname}"
  if [ ! -d "$target_dir" ]; then
    log_error "Package worktree directory '${target_dir}' is missing."
    exit 1
  fi

  # Load package configuration
  local tracking_mode="source"
  local conflict_strategy="abort"
  local upstream_url=""
  local pkgconfig_path="${target_dir}/.pkgconfig"
  
  if [ -f "$pkgconfig_path" ]; then
    # Parse tracking mode
    local track_mode
    track_mode=$(grep "^TRACKING_MODE=" "$pkgconfig_path" | cut -d'=' -f2 | tr -d '"'\')
    if [ -n "$track_mode" ]; then
      tracking_mode="$track_mode"
    fi
    # Parse conflict strategy
    local conf_strat
    conf_strat=$(grep "^CONFLICT_STRATEGY=" "$pkgconfig_path" | cut -d'=' -f2 | tr -d '"'\')
    if [ -n "$conf_strat" ]; then
      conflict_strategy="$conf_strat"
    fi
    # Parse upstream URL
    local config_url
    config_url=$(grep "^UPSTREAM_URL=" "$pkgconfig_path" | cut -d'=' -f2 | tr -d '"'\')
    if [ -n "$config_url" ]; then
      upstream_url="$config_url"
      if [[ ! "$upstream_url" =~ :// ]] && [[ ! "$upstream_url" =~ @ ]] && [[ ! "$upstream_url" =~ / ]]; then
        upstream_url="https://aur.archlinux.org/${upstream_url}.git"
      fi
    fi
  fi

  # Command line flags override configuration file settings
  if [ "$ours_flag" = true ]; then
    conflict_strategy="ours"
  elif [ "$theirs_flag" = true ]; then
    conflict_strategy="theirs"
  elif [ "$abort_flag" = true ]; then
    conflict_strategy="abort"
  fi

  # Get versions
  local local_ver
  local_ver=$(get_local_version "$pkgname")
  
  local upstream_ver=""
  if [ "$tracking_mode" = "source" ]; then
    upstream_ver=$(get_source_project_version "$pkgname")
    if [ -z "$upstream_ver" ] || [ "$upstream_ver" = "unknown" ]; then
      log_warning "Could not query real upstream version. Falling back to AUR..."
      tracking_mode="aur" # Temporarily switch to AUR merge if VCS is not working or if regular package
    fi
  fi

  if [ "$tracking_mode" = "aur" ]; then
    if [ -n "$upstream_url" ]; then
      log_info "Checking remote Git upstream: ${upstream_url}..."
      local temp_remote="aur-temp-ver-${pkgname}"
      git remote remove "$temp_remote" >/dev/null 2>&1 || true
      git remote add "$temp_remote" "$upstream_url" >/dev/null 2>&1 || true
      git fetch "$temp_remote" --quiet >/dev/null 2>&1
      
      local remote_branch="master"
      if ! git show-ref --quiet "refs/remotes/${temp_remote}/master"; then
        if git show-ref --quiet "refs/remotes/${temp_remote}/main"; then
          remote_branch="main"
        else
          remote_branch="$(git branch -r | grep "${temp_remote}/" | head -n1 | sed "s|[[:space:]]*${temp_remote}/||")"
        fi
      fi
      
      local remote_pkgbuild
      remote_pkgbuild=$(git show "refs/remotes/${temp_remote}/${remote_branch}:PKGBUILD" 2>/dev/null)
      upstream_ver=$(parse_pkgbuild_version "$remote_pkgbuild")
      
      git remote remove "$temp_remote" >/dev/null 2>&1
    else
      upstream_ver=$(get_aur_version "$pkgname")
    fi
  fi

  if [ -z "$upstream_ver" ] || [ "$upstream_ver" = "unknown" ]; then
    log_error "Cannot retrieve upstream version to perform upgrade."
    exit 1
  fi

  local comp
  comp=$(compare_versions "$local_ver" "$upstream_ver")
  if [ "$comp" -ge 0 ] && [ "$force_flag" = false ]; then
    log_success "Package '${pkgname}' is already up-to-date (Version: ${local_ver}). Use --force to reinstall/rebuild."
    exit 0
  fi

  log_info "Upgrading package '${pkgname}' from version ${local_ver} to ${upstream_ver}..."

  if [ "$pr_flag" = true ]; then
    # PR-Based Upgrade Workflow (Automation/CI)
    log_info "Running in PR mode. Creating temporary upgrade branch..."
    local pr_branch="upgrade/${pkgname}-to-${upstream_ver}"
    
    # Check if branch already exists
    if git show-ref --verify --quiet "refs/heads/${pr_branch}"; then
      log_warning "PR upgrade branch '${pr_branch}' already exists. Recreating it..."
      git branch -D "$pr_branch" >/dev/null 2>&1
    fi

    # Create temporary upgrade branch off the package branch
    git branch "$pr_branch" "$pkgname"
    
    # Checkout temporary worktree
    local pr_worktree="${PACKAGES_DIR}/upgrade-${pkgname}"
    rm -rf "$pr_worktree"
    git worktree add "$pr_worktree" "$pr_branch" >/dev/null 2>&1
    
    # Run upgrade inside the worktree
    (
      cd "$pr_worktree" || exit 1
      perform_actual_upgrade "$pkgname" "$tracking_mode" "$conflict_strategy" "$upstream_ver" "$upstream_url"
    )
    local upgrade_status=$?

    if [ $upgrade_status -eq 0 ]; then
      log_info "Pushing upgrade branch to origin and creating Pull Request..."
      git push origin "$pr_branch" --force --quiet 2>/dev/null || log_warning "Could not push branch to origin. Are you in a sandbox/test env?"
      
      # Use GitHub CLI to create PR if available
      if command -v gh >/dev/null 2>&1; then
        local pr_title="Upgrade ${pkgname} to ${upstream_ver}"
        local pr_body="Automated version upgrade check detected a new version of ${pkgname}. Local: ${local_ver} -> Upstream: ${upstream_ver}."
        if [ "$conflict_strategy" = "theirs" ] || [ "$conflict_strategy" = "ours" ]; then
          pr_body="${pr_body}\n\n⚠️ **Warning:** A git merge conflict occurred and was resolved automatically using the \`${conflict_strategy}\` strategy."
        fi
        
        # Open the PR targeting the package branch
        if gh pr create --base "$pkgname" --head "$pr_branch" --title "$pr_title" --body "$pr_body" --label "aur-upgrade" >/dev/null 2>&1; then
          log_success "Pull Request created successfully!"
        else
          log_warning "Could not create Pull Request via 'gh' CLI. Ensure you are authenticated."
        fi
      else
        log_warning "GitHub CLI ('gh') is not installed. Skipping PR creation."
      fi
    else
      log_error "Upgrade failed inside temporary branch. Aborting."
    fi
    
    # Cleanup worktree
    git worktree remove --force "$pr_worktree" >/dev/null 2>&1
    git branch -D "$pr_branch" >/dev/null 2>&1
    
  else
    # Direct Upgrade Mode (Local developers running instantly)
    # Check for local uncommitted changes
    if [ -d "$target_dir" ]; then
      cd "$target_dir" || exit 1
      if ! git diff-index --quiet HEAD --; then
        if [ "$force_flag" = true ]; then
          log_warning "Uncommitted changes found in '${pkgname}' worktree, but --force was specified. Proceeding..."
        else
          log_error "Uncommitted changes found in '${pkgname}' worktree. Commit them or run with --force to ignore."
          exit 1
        fi
      fi
      
      # Execute actual upgrade
      perform_actual_upgrade "$pkgname" "$tracking_mode" "$conflict_strategy" "$upstream_ver" "$upstream_url"
      local upgrade_status=$?
      cd "${WORKSPACE_DIR}" || exit 1
      
      if [ $upgrade_status -eq 0 ]; then
        log_success "Package '${pkgname}' upgraded successfully to: ${upstream_ver}"
      else
        log_error "Package '${pkgname}' upgrade failed."
        exit 1
      fi
    fi
  fi
}

perform_actual_upgrade() {
  local pkgname="$1"
  local tracking_mode="$2"
  local conflict_strategy="$3"
  local upstream_ver="$4"
  local upstream_url="$5"
  
  if [ "$tracking_mode" = "source" ]; then
    # VCS Upgrade
    # VCS pkgver update is done by running makepkg -od to pull new commits
    log_info "Updating package using VCS pkgver extraction..."
    export PACMAN=true # Mock pacman
    makepkg -od --nodeps --noconfirm >/dev/null 2>&1
    
    # Get updated PKGBUILD content
    local current_version
    current_version=$(parse_pkgbuild_version "$(cat PKGBUILD)")
    
    # Commit changes on branch
    git add PKGBUILD
    git commit -m "Automated VCS version bump to ${current_version}" --quiet >/dev/null 2>&1 || true
    return 0
  else
    # AUR Upgrade
    # Fetch from AUR git repository (or custom configured URL) and merge
    local aur_url="${upstream_url:-https://aur.archlinux.org/${pkgname}.git}"
    local temp_remote="aur-temp-${pkgname}"
    
    git remote remove "$temp_remote" >/dev/null 2>&1 || true
    git remote add "$temp_remote" "$aur_url" >/dev/null 2>&1 || true
    git fetch "$temp_remote" --quiet >/dev/null 2>&1
    
    # Determine remote branch name (master or main)
    local remote_branch="master"
    if ! git show-ref --quiet "refs/remotes/${temp_remote}/master"; then
      if git show-ref --quiet "refs/remotes/${temp_remote}/main"; then
        remote_branch="main"
      else
        remote_branch="$(git branch -r | grep "${temp_remote}/" | head -n1 | sed "s|[[:space:]]*${temp_remote}/||")"
      fi
    fi
    
    # Try merging
    log_info "Merging upstream AUR branch '${remote_branch}'..."
    local merge_opts=""
    if [ "$conflict_strategy" = "ours" ]; then
      merge_opts="-X ours"
    elif [ "$conflict_strategy" = "theirs" ]; then
      merge_opts="-X theirs"
    fi

    # Attempt merge
    if git merge --no-edit $merge_opts "${temp_remote}/${remote_branch}" >/dev/null 2>&1; then
      # Merge succeeded cleanly
      git remote remove "$temp_remote" >/dev/null 2>&1
      return 0
    else
      # Merge conflict detected
      if [ "$conflict_strategy" = "abort" ]; then
        log_warning "Merge conflict occurred. Aborting merge (CONFLICT_STRATEGY=abort)..."
        git merge --abort >/dev/null 2>&1
        git remote remove "$temp_remote" >/dev/null 2>&1
        return 1
      else
        # Resolved using ours/theirs strategy
        log_warning "Conflict occurred and was resolved automatically (CONFLICT_STRATEGY=${conflict_strategy})."
        git remote remove "$temp_remote" >/dev/null 2>&1
        return 0
      fi
    fi
  fi
}
