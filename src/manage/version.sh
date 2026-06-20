# Version checking module
# Sources common.sh and list.sh (for parse_pkgbuild_version)

# Sourcing list.sh to reuse parse_pkgbuild_version
# shellcheck source=src/manage/list.sh
source "${ENGINE_DIR}/src/manage/list.sh"

get_local_version() {
  local pkgname="$1"
  local pkgbuild_content
  pkgbuild_content=$(git show "${pkgname}:PKGBUILD" 2>/dev/null)
  parse_pkgbuild_version "$pkgbuild_content"
}

get_aur_version() {
  local pkgname="$1"
  local json
  json=$(curl -s --connect-timeout 5 "https://aur.archlinux.org/rpc/?v=5&type=info&arg[]=${pkgname}")
  if [ -z "$json" ]; then
    echo ""
    return 1
  fi
  
  # Try jq
  if command -v jq >/dev/null 2>&1; then
    echo "$json" | jq -r '.results[0].Version // empty'
  # Try python3
  elif command -v python3 >/dev/null 2>&1; then
    echo "$json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data['results'][0]['Version'] if data['results'] and 'Version' in data['results'][0] else '')" 2>/dev/null
  # Fallback sed
  else
    echo "$json" | grep -o '"Version":"[^"]*"' | head -n1 | cut -d'"' -f4
  fi
}

get_github_release_version() {
  local url="$1"
  # Extract owner and repo from github URL
  # e.g., https://github.com/owner/repo
  if [[ "$url" =~ github\.com/([^/]+)/([^/]+) ]]; then
    local owner="${BASH_REMATCH[1]}"
    local repo="${BASH_REMATCH[2]}"
    # Remove trailing .git or slashes
    repo="${repo%.git}"
    repo="${repo%/}"
    
    local api_url="https://api.github.com/repos/${owner}/${repo}/releases/latest"
    local json
    json=$(curl -s --connect-timeout 5 "$api_url")
    if [ -z "$json" ]; then
      return 1
    fi
    
    local tag=""
    if command -v jq >/dev/null 2>&1; then
      tag=$(echo "$json" | jq -r '.tag_name // empty')
    elif command -v python3 >/dev/null 2>&1; then
      tag=$(echo "$json" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('tag_name', ''))" 2>/dev/null)
    else
      tag=$(echo "$json" | grep -o '"tag_name":"[^"]*"' | head -n1 | cut -d'"' -f4)
    fi

    # Clean tag (strip leading 'v' or 'r')
    tag="${tag#v}"
    tag="${tag#r}"
    echo "$tag"
  else
    return 1
  fi
}

get_source_project_version() {
  local pkgname="$1"
  local target_dir="${PACKAGES_DIR}/${pkgname}"
  
  if [ ! -d "$target_dir" ]; then
    # If worktree is missing, we cannot run VCS commands locally easily
    return 1
  fi

  local pkgbuild_path="${target_dir}/PKGBUILD"
  if [ ! -f "$pkgbuild_path" ]; then
    return 1
  fi

  # Check if it uses git tag-pinned sources standard (matching git+ and #tag=)
  if grep -q "git\+.*#tag=" "$pkgbuild_path"; then
    log_info "Running git tag-pinned upgrade check for '${pkgname}'..." >&2
    
    # 1. Get source URL
    local src_url=""
    src_url=$(pkgbuild_path="$pkgbuild_path" bash -c '
      source "$pkgbuild_path" &>/dev/null
      for src in "${source[@]}"; do
        if [[ "$src" =~ git\+ ]]; then
          url="${src#git+}"
          url="${url%%\?*}"
          url="${url%%#*}"
          echo "$url"
          exit 0
        fi
      done
    ' 2>/dev/null)
    
    if [ -n "$src_url" ]; then
      local tags_list
      tags_list=$(git ls-remote --tags "$src_url" 2>/dev/null)
      
      if [ -n "$tags_list" ]; then
        # 2. Get current pkgver & pkgrel
        local current_pkgver
        current_pkgver=$(grep -E "^pkgver=" "$pkgbuild_path" | cut -d'=' -f2- | tr -d '"'\')
        local current_pkgrel
        current_pkgrel=$(grep -E "^pkgrel=" "$pkgbuild_path" | cut -d'=' -f2- | tr -d '"'\')
        [ -z "$current_pkgrel" ] && current_pkgrel="1"
        
        # 3. Detect prefix
        local prefix=""
        local found_prefix=false
        while read -r hash ref; do
          [ -z "$ref" ] && continue
          local tag_name="${ref#refs/tags/}"
          [[ "$tag_name" == *^{} ]] && continue
          if [[ "$tag_name" == *"${current_pkgver}" ]]; then
            prefix="${tag_name%"${current_pkgver}"}"
            found_prefix=true
            break
          fi
        done <<< "$tags_list"
        
        if [ "$found_prefix" = false ]; then
          local tag_line
          tag_line=$(grep -E "^\s*_tag=" "$pkgbuild_path")
          if [[ "$tag_line" =~ git\ rev-parse\ [\'\"]?([a-zA-Z0-9_-]*)\$pkgver ]]; then
            prefix="${BASH_REMATCH[1]}"
            found_prefix=true
          fi
        fi
        
        if [ "$found_prefix" = false ]; then
          # Extract tag template from source array, e.g., git+xxx#tag=v$pkgver
          local src_tag_tmpl=""
          src_tag_tmpl=$(pkgbuild_path="$pkgbuild_path" bash -c '
            source "$pkgbuild_path" &>/dev/null
            for src in "${source[@]}"; do
              if [[ "$src" =~ #tag= ]]; then
                echo "${src##*#tag=}"
                exit 0
              fi
            done
          ' 2>/dev/null)
          
          # Clean and resolve the template's prefix
          if [ -n "$src_tag_tmpl" ]; then
            if [[ "$src_tag_tmpl" =~ ^([a-zA-Z0-9_-]*)\$\{?pkgver\}? ]]; then
              prefix="${BASH_REMATCH[1]}"
              found_prefix=true
            fi
          fi
        fi
        
        # 4. Find max version
        local max_ver=""
        while read -r hash ref; do
          [ -z "$ref" ] && continue
          local tag_name="${ref#refs/tags/}"
          [[ "$tag_name" == *^{} ]] && continue
          
          if [[ "$tag_name" == "${prefix}"* ]]; then
            local candidate_ver="${tag_name#"$prefix"}"
            candidate_ver=$(echo "$candidate_ver" | tr -cd 'a-zA-Z0-9._-')
            [ -z "$candidate_ver" ] && continue
            
            if [ -z "$max_ver" ]; then
              max_ver="$candidate_ver"
            else
              local comp
              comp=$(compare_versions "$candidate_ver" "$max_ver")
              if [ "$comp" -gt 0 ]; then
                max_ver="$candidate_ver"
              fi
            fi
          fi
        done <<< "$tags_list"
        
        if [ -n "$max_ver" ]; then
          echo "${max_ver}-${current_pkgrel}"
          return 0
        fi
      fi
    fi
  fi

  # Check if it has a pkgver() function (VCS package)
  if grep -q "^pkgver()" "$pkgbuild_path"; then
    log_info "Running pkgver() dynamically for VCS package '${pkgname}'..." >&2
    # Run makepkg -od to fetch sources and update PKGBUILD
    # We run in a subshell to not pollute current shell env
    (
      cd "$target_dir" || exit 1
      # Run makepkg -od (downloads sources, runs pkgver)
      # Redirect output to /dev/null to keep it clean
      # We bypass build-key check using --nodeps
      export PACMAN=true # Mock pacman to avoid dependencies error during source fetch
      makepkg -od --nodeps --noconfirm >/dev/null 2>&1
    )
    
    # Read the updated PKGBUILD version
    local updated_version
    updated_version=$(parse_pkgbuild_version "$(cat "$pkgbuild_path")")
    
    # Reset PKGBUILD changes to keep clean state
    (
      cd "$target_dir" || exit 1
      git checkout PKGBUILD >/dev/null 2>&1
    )
    
    echo "$updated_version"
    return 0
  fi

  # For non-VCS packages, try parsing PKGBUILD url for GitHub releases
  local url
  url=$(git show "${pkgname}:PKGBUILD" 2>/dev/null | grep "^url=" | cut -d'=' -f2- | tr -d '"'\')
  if [[ "$url" =~ github\.com ]]; then
    local gh_ver
    gh_ver=$(get_github_release_version "$url")
    if [ -n "$gh_ver" ]; then
      # Append '-1' rel suffix as a guess for comparison
      echo "${gh_ver}-1"
      return 0
    fi
  fi

  return 1
}

# Compare two version strings using pacman's vercmp if available, else a custom fallback
compare_versions() {
  local ver1="$1"
  local ver2="$2"
  
  if command -v vercmp >/dev/null 2>&1; then
    vercmp "$ver1" "$ver2"
  else
    # Simple fallback using sort -V
    if [ "$ver1" = "$ver2" ]; then
      echo 0
    else
      local sorted
      sorted=$(printf "%s\n%s" "$ver1" "$ver2" | sort -V | head -n1)
      if [ "$sorted" = "$ver1" ]; then
        echo -1
      else
        echo 1
      fi
    fi
  fi
}

check_package_version() {
  local pkgname="$1"
  
  if [ -z "$pkgname" ]; then
    log_error "Package name is required."
    exit 1
  fi
  
  if ! git show-ref --verify --quiet "refs/heads/${pkgname}"; then
    log_error "Package branch '${pkgname}' does not exist."
    exit 1
  fi

  # Load package-specific config
  local tracking_mode="source"
  local pkgconfig_content
  pkgconfig_content=$(git show "${pkgname}:.pkgconfig" 2>/dev/null)
  if [ -n "$pkgconfig_content" ]; then
    local track_mode
    track_mode=$(echo "$pkgconfig_content" | grep "^TRACKING_MODE=" | cut -d'=' -f2 | tr -d '"'\')
    if [ -n "$track_mode" ]; then
      tracking_mode="$track_mode"
    fi
  fi

  local local_ver
  local_ver=$(get_local_version "$pkgname")

  local upstream_ver=""
  log_info "Checking versions for '${pkgname}' (tracking mode: ${tracking_mode})..."

  if [ "$tracking_mode" = "source" ]; then
    upstream_ver=$(get_source_project_version "$pkgname")
    if [ -z "$upstream_ver" ] || [ "$upstream_ver" = "unknown" ]; then
      log_warning "Could not query real upstream version. Falling back to AUR..."
      upstream_ver=$(get_aur_version "$pkgname")
    fi
  else
    # Query custom remote upstream URL if set, else fallback to AUR RPC
    local upstream_url=""
    local config_url
    config_url=$(git show "${pkgname}:.pkgconfig" 2>/dev/null | grep "^UPSTREAM_URL=" | cut -d'=' -f2 | tr -d '"'\')
    if [ -n "$config_url" ]; then
      upstream_url="$config_url"
      if [[ ! "$upstream_url" =~ :// ]] && [[ ! "$upstream_url" =~ @ ]] && [[ ! "$upstream_url" =~ / ]]; then
        upstream_url="https://aur.archlinux.org/${upstream_url}.git"
      fi
    fi
    
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
    log_error "Failed to retrieve upstream version for '${pkgname}'."
    echo "LOCAL=${local_ver}"
    echo "UPSTREAM=unknown"
    echo "STATUS=ERROR"
    return 1
  fi

  local comp
  comp=$(compare_versions "$local_ver" "$upstream_ver")

  echo "LOCAL=${local_ver}"
  echo "UPSTREAM=${upstream_ver}"

  if [ "$comp" -lt 0 ]; then
    log_warning "Package '${pkgname}' is OUT-OF-DATE (Local: ${local_ver} < Upstream: ${upstream_ver})"
    echo "STATUS=OUT-OF-DATE"
    return 2
  else
    log_success "Package '${pkgname}' is UP-TO-DATE (Local: ${local_ver} >= Upstream: ${upstream_ver})"
    echo "STATUS=UP-TO-DATE"
    return 0
  fi
}
