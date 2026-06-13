# Package creation module
# Sources common.sh

create_package() {
  local pkgname="$1"
  local mode="$2"
  local target="$3"

  local current_branch
  current_branch=$(git branch --show-current)

  if [ -z "$pkgname" ]; then
    log_error "Package name is required."
    exit 1
  fi

  # Validate package name characters
  if [[ ! "$pkgname" =~ ^[a-zA-Z0-9@._+-]+$ ]]; then
    log_error "Invalid package name: '$pkgname'. Only alphanumeric and @._+- characters are allowed."
    exit 1
  fi

  # Check if branch already exists in our git repository
  if git show-ref --verify --quiet "refs/heads/${pkgname}" 2>/dev/null; then
    log_error "Branch '${pkgname}' already exists in the repository."
    exit 1
  fi

  # Check if worktree directory already exists
  local target_dir="${PACKAGES_DIR}/${pkgname}"
  if [ -d "$target_dir" ]; then
    log_error "Target worktree directory '${target_dir}' already exists."
    exit 1
  fi

  log_info "Creating package '${pkgname}' in mode: ${mode}..."

  case "$mode" in
    --scratch)
      log_info "Creating clean orphan branch '${pkgname}' (0 commits)..."
      # Create orphan branch in a new worktree
      git worktree add --orphan -b "$pkgname" "$target_dir" >/dev/null 2>&1
      
      # Populate skeleton template files
      cp "${ENGINE_DIR}/templates/PKGBUILD.proto" "${target_dir}/PKGBUILD"
      sed -i "s/_PKGNAME_/${pkgname}/g" "${target_dir}/PKGBUILD"
      cp "${ENGINE_DIR}/templates/pkgconfig.proto" "${target_dir}/.pkgconfig"
      
      log_success "Package '${pkgname}' created from scratch at: ${target_dir}"
      log_info "No initial commit was created. Please edit PKGBUILD and run 'git add' and 'git commit' inside ${target_dir} to create the first commit."
      ;;

    --copy-main)
      log_info "Creating orphan branch '${pkgname}' copying template files from main..."
      # Create orphan branch in a new worktree
      git worktree add --orphan -b "$pkgname" "$target_dir" >/dev/null 2>&1
      
      # Populate skeleton templates from main branch
      cp "${ENGINE_DIR}/templates/PKGBUILD.proto" "${target_dir}/PKGBUILD"
      sed -i "s/_PKGNAME_/${pkgname}/g" "${target_dir}/PKGBUILD"
      cp "${ENGINE_DIR}/templates/pkgconfig.proto" "${target_dir}/.pkgconfig"
      
      # For copy-main, we commit the template files to start with an initial commit
      cd "$target_dir" || exit 1
      git add PKGBUILD .pkgconfig
      git commit -m "Initial commit copying templates from main" >/dev/null
      cd "${WORKSPACE_DIR}" || exit 1
      
      log_success "Package '${pkgname}' created from main template at: ${target_dir}"
      ;;

    --clone)
      if [ -z "$target" ]; then
        log_error "Clone target URL or package name is required."
        exit 1
      fi

      local clone_url="$target"
      # If target is a directory or path, keep it. Otherwise check if it's a remote URL. If neither, construct AUR URL.
      if [ -d "$clone_url" ] || [[ "$clone_url" = /* ]] || [[ "$clone_url" = ./* ]] || [[ "$clone_url" = ../* ]]; then
        # It is a local directory or path
        true
      elif [[ "$clone_url" =~ ^(https?|git|ssh|file):// ]]; then
        # It is a remote git URL
        true
      else
        # It is an AUR package name
        clone_url="https://aur.archlinux.org/${target}.git"
      fi

      log_info "Fetching upstream AUR repository: ${clone_url}..."
      
      # Add upstream as a temporary remote
      local temp_remote="aur-${pkgname}"
      git remote add "$temp_remote" "$clone_url" || {
        log_error "Could not add git remote ${temp_remote}."
        exit 1
      }
      
      # Fetch remote master branch
      if ! git fetch "$temp_remote" master:refs/remotes/"$temp_remote"/master --quiet; then
        # Try fetching default branch if master fails
        if ! git fetch "$temp_remote" --quiet; then
          log_error "Failed to fetch from remote: ${clone_url}"
          git remote remove "$temp_remote"
          exit 1
        fi
      fi

      # Determine remote branch name (master or main)
      local remote_branch="master"
      if ! git show-ref --quiet "refs/remotes/${temp_remote}/master"; then
        if git show-ref --quiet "refs/remotes/${temp_remote}/main"; then
          remote_branch="main"
        else
          # Fallback to whatever ref we fetched
          remote_branch="$(git branch -r | grep "${temp_remote}/" | head -n1 | sed "s|[[:space:]]*${temp_remote}/||")"
        fi
      fi

      log_info "Importing upstream history as branch '${pkgname}'..."
      if ! git checkout -b "$pkgname" "${temp_remote}/${remote_branch}" --quiet; then
        log_error "Failed to checkout new branch ${pkgname} from remote."
        git remote remove "$temp_remote"
        exit 1
      fi

      # Clean up remote
      git remote remove "$temp_remote"
      
      # Return to original branch in the root repository
      git checkout "$current_branch" --quiet

      log_info "Checking out package worktree..."
      if ! git worktree add "$target_dir" "$pkgname"; then
        log_error "Failed to add worktree for ${pkgname} at ${target_dir}"
        exit 1
      fi

      # Add default .pkgconfig if not present in the cloned repository
      if [ ! -f "${target_dir}/.pkgconfig" ]; then
        cp "${ENGINE_DIR}/templates/pkgconfig.proto" "${target_dir}/.pkgconfig"
        # Since it is a clone, we configure TRACKING_MODE="aur" by default in .pkgconfig
        sed -i 's/TRACKING_MODE="source"/TRACKING_MODE="aur"/g' "${target_dir}/.pkgconfig"
      fi
      
      # Set the UPSTREAM_URL inside .pkgconfig to the clone target URL/path
      sed -i "s|UPSTREAM_URL=.*|UPSTREAM_URL=\"$target\"|g" "${target_dir}/.pkgconfig"
      
      # Commit the .pkgconfig in the package branch
      cd "$target_dir" || exit 1
      git add .pkgconfig
      git commit -m "Initialize package config (.pkgconfig) with upstream URL" --quiet >/dev/null || true
      cd "${WORKSPACE_DIR}" || exit 1

      log_success "Package '${pkgname}' cloned and checked out at: ${target_dir}"
      ;;

    *)
      log_error "Unknown creation mode: ${mode}"
      exit 1
      ;;
  esac
}
