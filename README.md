# Arch Linux AUR-Based Repository Automation System

A robust pair of scripts designed to scan, upgrade, compile, sign, and manage a custom Arch Linux package repository using the AUR.

---

## Architecture Overview

The system consists of two primary parts:
1. **`manage.sh`**: Command-line package manager to track AUR/VCS branches, add/delete packages, import PGP keys, and trigger version upgrades (including Pull Requests/CI automation).
2. **`build.sh`**: Automation builder that scans package branches for updates, compiles new versions, updates the Pacman database (`custom.db.tar.gz`), and handles cleanups.

---

## Installation & Configuration

Copy `config.conf` to configure defaults:
```ini
# Name of the custom repository.
REPO_NAME="custom"

# Output directory for built packages and database files.
REPO_DIR="repo"

# Directory where package branches are checked out.
PACKAGES_DIR="packages"

# Method to compile packages ("makepkg" or "chroot").
BUILD_METHOD="makepkg"

# GPG Signing settings.
SIGN_PACKAGES="false"
GPG_KEY=""

# Cleanup older version packages.
CLEAN_OLD_PACKAGES="true"

# Cache downloaded package source files.
CACHE_SOURCES="true"
SOURCE_CACHE_DIR="cache/sources"

# Cache downloaded pacman package dependencies for chroot builds.
CACHE_PACMAN_PACKAGES="true"
PACMAN_CACHE_DIR="cache/packages"

# Custom chroot directory path (optional).
CHROOT_DIR=""
```

---

## Compilation Methods

### 1. `makepkg` (Default)
Runs `makepkg -s --noconfirm` directly on the host system. Fast and simple, but pollutes the host with build-time dependencies.

### 2. `chroot` (Isolated)
Compiles packages inside an isolated systemd-nspawn container container using the `devtools` utilities. This ensures a clean, isolated build environment and keeps the host system clean of build dependencies.

---

## Clean Chroot Requirements & Setup

To use `BUILD_METHOD="chroot"` successfully, your build environment must meet the following requirements:

### 1. Install Devtools
You must install the official Arch Linux package build helper tools:
```bash
sudo pacman -S devtools
```

### 2. Elevated Permissions
The `extra-x86_64-build` script uses systemd-nspawn containers, which requires root permissions:
* The build execution user must be configured in `/etc/sudoers` to run devtools commands without password prompting if you run this in an automated CI/CD environment.
* Add this rule to `/etc/sudoers` to allow passwordless execution:
  ```sudoers
  %wheel ALL=(ALL) NOPASSWD: /usr/bin/extra-x86_64-build, /usr/bin/makechrootpkg
  ```

### 3. Pacman Dependency Caching (Highly Recommended)
By default, each clean chroot rebuild downloads its own dependency packages from scratch. To avoid downloading package dependencies repeatedly on each build:
* Enable `CACHE_PACMAN_PACKAGES="true"` and set a central `PACMAN_CACHE_DIR` in your configuration.
* The builder will automatically bind-mount this directory into `/var/cache/pacman/pkg` inside the build chroot container during compilation.

### 4. Initialize the Chroot (Optional if using custom `CHROOT_DIR`)
If you specify a custom chroot path (e.g. `CHROOT_DIR="cache/chroot"`), you must initialize it before running the build:
```bash
# Create the clean chroot root base
mkdir -p cache/chroot
mkarchroot cache/chroot/root base-devel
```
*(If `CHROOT_DIR` is left empty, the system defaults to the pre-configured system-wide chroot path `/var/lib/archbuild/extra-x86_64/`).*

### 5. Running on Non-Arch Hosts via Docker (Alpine Linux, etc.)
If your build server runs on a non-Arch host OS (like Alpine Linux), you cannot execute `devtools` or systemd namespaces directly. Instead, run the build server inside a privileged Arch Linux Docker container that matches your host user's UID and GID:

1. **Start the build container** using the automated script:
   ```bash
   ./arch-creamsoda/docker-run.sh
   ```
   *This automatically builds the container matching your host UID/GID, mounts the workspace, and maps the Pacman package cache directory.*
2. **Configure caching in `config.conf`** to persist the clean chroot base system to the host filesystem:
   ```ini
   CHROOT_DIR="cache/chroot"
   ```
   By saving the chroot base inside the workspace, it persists permanently across container restarts.

---

## Command Reference

### Package Management (`manage.sh`)

* **List packages:**
  ```bash
  ./manage.sh list
  ```
* **Add/Track an AUR package:**
  ```bash
  ./manage.sh create <pkgname> --clone https://aur.archlinux.org/<pkgname>.git
  ```
* **Remove a package from tracking:**
  ```bash
  ./manage.sh delete <pkgname>
  ```
* **Import a required PGP key:**
  ```bash
  ./manage.sh import-key <key-id>
  ```
* **Check package updates:**
  ```bash
  ./manage.sh version-check <pkgname>
  ```
* **Upgrade package branch locally:**
  ```bash
  ./manage.sh upgrade <pkgname>
  ```
* **Generate Pull Request for upgrades (CI/CD mode):**
  ```bash
  ./manage.sh upgrade <pkgname> --pr
  ```
* **Publish/Sync the built package repository:**
  ```bash
  ./manage.sh publish
  ```

### Build Automation (`build.sh`)

* **Build outstanding packages:**
  ```bash
  ./build.sh
  ```
* **Scan branches only (Dry Run):**
  ```bash
  ./build.sh --scan-only
  ```
* **Force rebuild of all packages:**
  ```bash
  ./build.sh --force-rebuild
  ```

---

## Remote Build Server Worktree Automation (`git-bare-worktree.sh`)

A self-contained helper script designed to configure and manage git worktrees from bare repositories on remote build servers. It maps all remote branches cleanly under the remote tracking namespace (`refs/remotes/origin/*`) and checks out worktrees using tracking branches (Option B) for optimal observability. It also includes automatic recursive submodule initialization.

### Commands

1. **Setup Bare Repository:**
   Clones the repository as bare and maps branches cleanly:
   ```bash
   ./git-bare-worktree.sh setup <remote_url> <bare_repo_path>
   ```

2. **Sync Branch into Worktree:**
   Fetches latest remote references, updates or creates the local tracking branch pointing to `origin/<branch_name>` for tracking visibility, and initializes/updates all submodules recursively:
   ```bash
   ./git-bare-worktree.sh sync <bare_repo_path> <branch_name> <worktree_path>
   ```

3. **Sync All Package Branches:**
   Fetches remote refs, automatically scans all package branches, and checks them out under the specified target directory:
   ```bash
   ./git-bare-worktree.sh sync-packages <bare_repo_path> <packages_dir_path>
   ```

4. **Cleanup Worktree:**
   Removes the worktree and prunes git administrative metadata:
   ```bash
   ./git-bare-worktree.sh cleanup <bare_repo_path> <worktree_path>
   ```

### CI/CD Server Usage Example (Via Curl)

This script is fully standalone and can be curled directly onto any remote build server or runner. It is recommended to clone the bare repository inside a hidden `.bare/` folder in your workspace root to keep the environment self-contained:

```bash
# 1. Download and make executable
curl -sSL -o git-bare-worktree.sh https://raw.githubusercontent.com/username/repo/main/git-bare-worktree.sh
chmod +x git-bare-worktree.sh

# 2. Setup the bare database clone inside the workspace under .bare/
./git-bare-worktree.sh setup "git@github.com:username/repo.git" "/var/lib/builds/workspace/.bare"

# 3. Sync all package branches into worktrees under packages/
./git-bare-worktree.sh sync-packages "/var/lib/builds/workspace/.bare" "/var/lib/builds/workspace/packages"

# 4. Sync the master build workspace branch to the workspace root
./git-bare-worktree.sh sync "/var/lib/builds/workspace/.bare" "master" "/var/lib/builds/workspace"

# 5. Run the builder to compile outstanding package updates
cd "/var/lib/builds/workspace"
./arch-creamsoda/build.sh
```

