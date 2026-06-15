#!/usr/bin/env bash

# Arch Linux Repository Automation Builder

# Source common core
# shellcheck source=src/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/src/common.sh"

load_config
init_dirs

# Sourcing build modules
# shellcheck source=src/build/scanner.sh
source "${ENGINE_DIR}/src/build/scanner.sh"
# shellcheck source=src/build/compiler.sh
source "${ENGINE_DIR}/src/build/compiler.sh"

show_help() {
  echo -e "Arch Linux Repository Automation Builder"
  echo -e "Usage: $0 [options]"
  echo -e ""
  echo -e "Options:"
  echo -e "  -s, --scan-only             Scan branch versions and show outstanding updates without compiling"
  echo -e "  -f, --force-rebuild [pkg]   Force rebuild of all packages or a specific package regardless of DB version"
  echo -e "                              (defaults to 'all' if no package is specified)"
  echo -e "  -h, --help                  Show this help menu"
}

# Parse options
scan_only=false
force_rebuild=false
force_rebuild_package=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -s|--scan-only) scan_only=true ;;
    -f|--force-rebuild)
      force_rebuild=true
      if [ -n "${2:-}" ] && [[ ! "$2" =~ ^- ]]; then
        force_rebuild_package="$2"
        shift
      fi
      ;;
    -h|--help) show_help; exit 0 ;;
    *) log_error "Unknown option: $1"; show_help; exit 1 ;;
  esac
  shift
done

# Acquire repository lock for build safety
acquire_lock

# Run scanner
scan_packages_for_changes

if [ "$scan_only" = "true" ]; then
  log_info "Scan-only mode. Skipping compilation."
  exit 0
fi

# Force rebuild if specified
if [ "$force_rebuild" = "true" ]; then
  if [ -n "$force_rebuild_package" ] && [ "$force_rebuild_package" != "all" ]; then
    log_info "Force-rebuild flag specified. Forcing compilation of specific package branch: ${force_rebuild_package}..."
    if git show "${force_rebuild_package}:PKGBUILD" &>/dev/null; then
      pkgbuild_content=$(git show "${force_rebuild_package}:PKGBUILD" 2>/dev/null)
      git_ver=$(parse_pkgbuild_version "$pkgbuild_content")
      BUILD_QUEUE["$force_rebuild_package"]="$git_ver"
    else
      log_error "Package branch '${force_rebuild_package}' not found."
      exit 1
    fi
  else
    log_info "Force-rebuild flag specified. Forcing compilation of all registered package branches..."
    
    # Populate build queue with all scanned branches
    branches=$(git for-each-ref --format='%(refname:short)' refs/heads/)
    for branch in $branches; do
      if [ "$branch" = "master" ] || [ "$branch" = "main" ]; then
        continue
      fi
      pkgbuild_content=$(git show "${branch}:PKGBUILD" 2>/dev/null)
      git_ver=$(parse_pkgbuild_version "$pkgbuild_content")
      BUILD_QUEUE["$branch"]="$git_ver"
    done
  fi
fi

# Run compiler and register packages
compile_and_register
build_status=$?

if [ $build_status -eq 0 ]; then
  log_success "Build run completed successfully!"
  exit 0
else
  log_error "Build run encountered compilation errors."
  exit 1
fi
