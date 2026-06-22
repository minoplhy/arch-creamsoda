#!/usr/bin/env bash

# Arch Linux AUR-Based Repository Management CLI

# Source common core
# shellcheck source=src/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/src/common.sh"

load_config
init_dirs

# Sourcing management modules
# shellcheck source=src/manage/create.sh
source "${ENGINE_DIR}/src/manage/create.sh"
# shellcheck source=src/manage/delete.sh
source "${ENGINE_DIR}/src/manage/delete.sh"
# shellcheck source=src/manage/list.sh
source "${ENGINE_DIR}/src/manage/list.sh"
# shellcheck source=src/manage/version.sh
source "${ENGINE_DIR}/src/manage/version.sh"
# shellcheck source=src/manage/upgrade.sh
source "${ENGINE_DIR}/src/manage/upgrade.sh"
# shellcheck source=src/manage/keys.sh
source "${ENGINE_DIR}/src/manage/keys.sh"
# shellcheck source=src/manage/publish.sh
source "${ENGINE_DIR}/src/manage/publish.sh"

show_help() {
  echo -e "Arch Linux AUR-Based Repository Management CLI"
  echo -e "Usage: $0 [command] [options]"
  echo -e ""
  echo -e "Commands:"
  echo -e "  create <pkgname> --scratch               Create a new package branch from scratch (0 commits)"
  echo -e "  create <pkgname> --copy-main              Create a package branch copying template from main"
  echo -e "  create <pkgname> --clone <url|name>       Create a package branch by cloning from AUR or custom URL"
  echo -e "  delete <pkgname>                         Delete a package branch and its worktree"
  echo -e "  list                                     List all registered packages, versions, and status"
  echo -e "  version-check [pkgname]                  Check local version vs upstream AUR/Project version"
  echo -e "  upgrade <pkgname> [options]              Upgrade package version to the latest upstream"
  echo -e "  import-key <key_id...>                   Import trusted GPG public key(s) into the keyring"
  echo -e "  list-keys                                List GPG public keys in the repository keyring"
  echo -e "  publish                                  Publish/Sync the built package repository"
  echo -e "  sign [options]                           Sign all packages and databases in the repository"
  echo -e "  unsign                                   Remove all signatures from the repository and disable signing"
  echo -e "      Options for sign:"
  echo -e "         --key <key_id>                    GPG Key ID to use for signing"
  echo -e "         --gnupghome <dir>                 GPG home directory (optional)"
  echo -e "      Options for upgrade:"
  echo -e "         -f, --force                       Force upgrade even if local version is newer"
  echo -e "         --ours                            Resolve merge conflicts by keeping local version"
  echo -e "         --theirs                          Resolve merge conflicts by using upstream version"
  echo -e "         --abort                           Abort merge on conflict (default)"
  echo -e "         --pr                              Run in PR mode (creates branch and opens PR)"
  echo -e ""
  echo -e "Options:"
  echo -e "  -h, --help                               Show this help menu"
}

# Entry point routing
cmd="$1"
case "$cmd" in
  create)
    pkgname="$2"
    mode="$3"
    target="$4"
    if [ "$mode" != "--scratch" ] && [ "$mode" != "--copy-main" ] && [ "$mode" != "--clone" ]; then
      show_help
      exit 1
    fi
    # Acquire lock for mutation
    acquire_lock
    create_package "$pkgname" "$mode" "$target"
    ;;
  delete)
    pkgname="$2"
    if [ -z "$pkgname" ]; then
      show_help
      exit 1
    fi
    acquire_lock
    delete_package "$pkgname"
    ;;
  list)
    list_packages
    ;;
  version-check)
    pkgname="$2"
    if [ -n "$pkgname" ]; then
      check_package_version "$pkgname"
    else
      # Loop through all packages
      branches=$(git for-each-ref --format='%(refname:short)' refs/heads/)
      for branch in $branches; do
        if [ "$branch" = "master" ] || [ "$branch" = "main" ] || [[ "$branch" == upgrade-* ]] || [[ "$branch" == upgrade/* ]] || [[ "$branch" == updates-* ]] || [[ "$branch" == updates/* ]]; then
          continue
        fi
        check_package_version "$branch"
        echo ""
      done
    fi
    ;;
  upgrade)
    pkgname="$2"
    if [ -z "$pkgname" ]; then
      show_help
      exit 1
    fi
    shift 2
    acquire_lock
    upgrade_package "$pkgname" "$@"
    ;;
  import-key)
    shift
    acquire_lock
    import_gpg_keys "$@"
    ;;
  list-keys)
    list_gpg_keys
    ;;
  publish)
    acquire_lock
    publish_repository
    ;;
  sign)
    shift
    acquire_lock
    sign_repository "$@"
    ;;
  unsign)
    acquire_lock
    unsign_repository
    ;;
  -h|--help|"")
    show_help
    ;;
  *)
    log_error "Unknown command: $cmd"
    show_help
    exit 1
    ;;
esac
