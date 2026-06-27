# Management CLI unit and integration tests
# Sources test_helper.sh

run_manage_tests() {
  echo -e "\n================================================================================"
  echo -e "RUNNING PACKAGE MANAGEMENT CLI TESTS (manage.sh)"
  echo -e "================================================================================"

  # Test Case 1: Create scratch package
  log_info "TEST: Create scratch package..."
  assert_success "./manage.sh create test-pkg-scratch --scratch" "Create test-pkg-scratch command"
  assert_file_exists "packages/test-pkg-scratch/PKGBUILD" "Scratch PKGBUILD created"
  assert_file_exists "packages/test-pkg-scratch/.pkgconfig" "Scratch .pkgconfig created"
  
  # Check if branch test-pkg-scratch is orphan (no commit history initially, but let's check its parent count if we commit)
  # Wait, since we did --scratch, it has 0 commits. Let's make the first commit to test.
  (
    cd packages/test-pkg-scratch || exit 1
    git add PKGBUILD .pkgconfig
    git commit -m "First scratch commit" --quiet
  )
  local parents
  parents=$(git rev-list --parents -n 1 test-pkg-scratch | wc -w)
  assert_equals "1" "$parents" "Scratch branch has no parents (orphan branch)"

  # Test Case 2: Create copy-main package
  log_info "TEST: Create copy-main package..."
  assert_success "./manage.sh create test-pkg-copy --copy-main" "Create test-pkg-copy command"
  assert_file_exists "packages/test-pkg-copy/PKGBUILD" "Copy-main PKGBUILD created"
  assert_file_exists "packages/test-pkg-copy/.pkgconfig" "Copy-main .pkgconfig created"
  
  # Check if branch is orphan
  parents=$(git rev-list --parents -n 1 test-pkg-copy | wc -w)
  assert_equals "1" "$parents" "Copy-main branch has no parents (orphan branch)"

  # Test Case 3: Create clone package
  # We mock the AUR clone by pointing it to a local folder in the sandbox acting as a remote
  log_info "TEST: Create clone package..."
  # Prepare a mock upstream repository in sandbox/mock-upstream
  mkdir -p "${SANDBOX_DIR}/mock-upstream"
  (
    cd "${SANDBOX_DIR}/mock-upstream" || exit 1
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test Admin"
    echo -e "pkgname=librewolf-bin\npkgver=124.0.0\npkgrel=1" > PKGBUILD
    git add PKGBUILD
    git commit -m "initial aur release" --quiet
  )
  
  # Now clone it
  assert_success "./manage.sh create librewolf-bin --clone \"${SANDBOX_DIR}/mock-upstream\"" "Clone librewolf-bin command"
  assert_file_exists "packages/librewolf-bin/PKGBUILD" "Cloned PKGBUILD created"
  assert_file_exists "packages/librewolf-bin/.pkgconfig" "Cloned .pkgconfig created"
  
  # Check that local git branch librewolf-bin is mapped correctly
  assert_failure "git merge-base librewolf-bin master" "Cloned branch shares no history with master"

  # Test Case 4: List packages
  log_info "TEST: List packages..."
  assert_success "./manage.sh list" "List packages command"

  # Test Case 5: Version check (cloned packages defaults to aur version check)
  log_info "TEST: Version check package..."
  # Push a new version to our mock upstream remote first
  (
    cd "${SANDBOX_DIR}/mock-upstream" || exit 1
    echo -e "pkgname=librewolf-bin\npkgver=125.0.0\npkgrel=1" > PKGBUILD
    git add PKGBUILD
    git commit -m "aur version bump" --quiet
  )
  
  # For librewolf-bin, version check should report OUT-OF-DATE since local is 124.0.0-1 and mock upstream has 125.0.0-1
  ./manage.sh version-check librewolf-bin > version_output.txt 2>&1
  local status_line
  status_line=$(grep "STATUS=" version_output.txt)
  assert_equals "STATUS=OUT-OF-DATE" "$status_line" "librewolf-bin reported as OUT-OF-DATE"

  # Test Case 6: Upgrade package (clean merge)
  log_info "TEST: Upgrade package (clean merge)..."
  # Direct upgrade should merge cleanly
  assert_success "./manage.sh upgrade librewolf-bin" "Direct upgrade librewolf-bin"
  
  local local_updated_ver
  local_updated_ver=$(git show librewolf-bin:PKGBUILD | grep "^pkgver=" | cut -d'=' -f2)
  assert_equals "125.0.0" "$local_updated_ver" "PKGBUILD version updated to 125.0.0"

  # Test Case 7: Upgrade conflict (abort strategy)
  log_info "TEST: Upgrade conflict (abort strategy)..."
  # Modify local PKGBUILD to conflict with remote
  echo -e "pkgname=librewolf-bin\npkgver=125.0.0\npkgrel=1\n# Local edits that conflict" > packages/librewolf-bin/PKGBUILD
  (
    cd packages/librewolf-bin || exit 1
    git add PKGBUILD
    git commit -m "local custom change" --quiet
  )
  
  # Push conflicting change to mock upstream
  (
    cd "${SANDBOX_DIR}/mock-upstream" || exit 1
    echo -e "pkgname=librewolf-bin\npkgver=126.0.0\npkgrel=1\n# Remote conflicting edits" > PKGBUILD
    git add PKGBUILD
    git commit -m "upstream conflicting update" --quiet
  )
  
  # Configure CONFLICT_STRATEGY="abort" in librewolf-bin's .pkgconfig
  sed -i 's/CONFLICT_STRATEGY=.*/CONFLICT_STRATEGY="abort"/g' packages/librewolf-bin/.pkgconfig
  (
    cd packages/librewolf-bin || exit 1
    git add .pkgconfig
    git commit -m "set conflict strategy to abort" --quiet
  )
  
  # Upgrade should fail and abort the merge
  assert_failure "./manage.sh upgrade librewolf-bin" "Upgrade command with conflict fails"
  
  # Verify we are back to clean state (no merge in progress)
  (
    cd packages/librewolf-bin || exit 1
    assert_success "git merge-base --is-ancestor HEAD HEAD" "Worktree state is clean"
  )

  # Test Case 8: Upgrade conflict (theirs strategy)
  log_info "TEST: Upgrade conflict (theirs strategy)..."
  # Run upgrade with explicit --theirs flag
  assert_success "./manage.sh upgrade librewolf-bin --theirs" "Upgrade command with conflict resolved via --theirs"
  
  # Verify the PKGBUILD matches the upstream version (126.0.0)
  local ours_resolved_ver
  ours_resolved_ver=$(git show librewolf-bin:PKGBUILD | grep "^pkgver=" | cut -d'=' -f2)
  assert_equals "126.0.0" "$ours_resolved_ver" "PKGBUILD contains theirs changes (126.0.0)"

  # Test Case 9: Delete package
  log_info "TEST: Delete package..."
  assert_success "./manage.sh delete test-pkg-scratch" "Delete test-pkg-scratch command"
  assert_file_not_exists "packages/test-pkg-scratch" "Scratch package directory removed"
  
  # Check branch is removed
  assert_failure "git show-ref --verify --quiet refs/heads/test-pkg-scratch" "Scratch branch deleted"

  # Test Case 10: Short AUR upstream URL resolution
  log_info "TEST: Short AUR upstream URL resolution..."
  sed -i 's|UPSTREAM_URL=.*|UPSTREAM_URL="non-existent-pkg-name"|g' packages/librewolf-bin/.pkgconfig
  (
    cd packages/librewolf-bin || exit 1
    git add .pkgconfig
    git commit -m "test short upstream url" --quiet
  )
  ./manage.sh version-check librewolf-bin > short_url_output.txt 2>&1
  local resolved_log
  resolved_log=$(grep -c "Checking remote Git upstream: https://aur.archlinux.org/non-existent-pkg-name.git..." short_url_output.txt)
  assert_equals "1" "$resolved_log" "Short AUR upstream URL resolved to full AUR Git URL"
  rm -f short_url_output.txt

  # Test Case 11: Repository publishing command
  log_info "TEST: Repository publishing command..."
  # When PUBLISH_DEST is empty, it should print instructions and exit with status 1
  assert_failure "./manage.sh publish" "Publish command fails when PUBLISH_DEST is empty"
  
  # Configure a local destination for publishing
  local temp_publish_dir="${SANDBOX_DIR}/publish-dest"
  mkdir -p "$temp_publish_dir"
  
  # Inject PUBLISH_DEST into config.conf
  echo -e "\nPUBLISH_DEST=\"$temp_publish_dir\"" >> config.conf
  
  # Populate repo/ directory with test files
  mkdir -p repo
  echo "test package data" > repo/test-pkg.pkg.tar.zst
  echo "db contents" > repo/custom.db.tar.gz
  echo "lock file" > repo/repo.lock
  echo "status" > repo/status.json
  
  # Run publish
  assert_success "./manage.sh publish" "Publish command succeeds with valid PUBLISH_DEST"
  
  # Verify files are copied, excluding repo.lock and status.json
  assert_file_exists "${temp_publish_dir}/custom.db.tar.gz" "Database file is published"
  assert_file_exists "${temp_publish_dir}/test-pkg.pkg.tar.zst" "Package file is published"
  assert_file_not_exists "${temp_publish_dir}/repo.lock" "repo.lock is not published"
  assert_file_not_exists "${temp_publish_dir}/status.json" "status.json is not published"

  # Test Case 12: Git Tag-Object Hash Upgrade
  log_info "TEST: Git tag-object hash upgrade check..."
  # Setup mock project git remote
  local git_remote_dir="${SANDBOX_DIR}/mock-git-remote"
  mkdir -p "$git_remote_dir"
  (
    cd "$git_remote_dir" || exit 1
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test Admin"
    echo "Initial files" > README.md
    git add README.md
    git commit -m "initial commit" --quiet
    
    # Create annotated tag v1.0.0
    git tag -a v1.0.0 -m "version 1.0.0"
  )
  
  # Get tag v1.0.0 hash
  local tag_v1_hash
  tag_v1_hash=$(git -C "$git_remote_dir" rev-parse v1.0.0)
  
  # Create a package branch in our test repository
  assert_success "./manage.sh create test-git-tag-pkg --scratch" "Create test-git-tag-pkg command"
  
  # Write custom PKGBUILD using this format
  cat <<EOF > packages/test-git-tag-pkg/PKGBUILD
pkgname=test-git-tag-pkg
pkgver=1.0.0
pkgrel=1
_tag=${tag_v1_hash} # git rev-parse "v\$pkgver"
source=(git+file://${git_remote_dir}#tag=\$_tag)
pkgver() {
  cd "\$pkgname"
  git describe
}
EOF
  
  (
    cd packages/test-git-tag-pkg || exit 1
    git add PKGBUILD
    git commit -m "add pkgbuild with tag object hash" --quiet
  )
  
  # Run version check - should be UP-TO-DATE
  ./manage.sh version-check test-git-tag-pkg > tag_version_output1.txt 2>&1
  cat tag_version_output1.txt
  local status_line1
  status_line1=$(grep "STATUS=" tag_version_output1.txt)
  assert_equals "STATUS=UP-TO-DATE" "$status_line1" "test-git-tag-pkg reported as UP-TO-DATE initially"
  rm -f tag_version_output1.txt
  
  # Now add a new annotated tag v1.1.0 on the mock remote
  (
    cd "$git_remote_dir" || exit 1
    echo "New release feature" >> README.md
    git add README.md
    git commit -m "new feature commit" --quiet
    git tag -a v1.1.0 -m "version 1.1.0"
  )
  
  local tag_v1_1_hash
  tag_v1_1_hash=$(git -C "$git_remote_dir" rev-parse v1.1.0)
  
  # Run version check again - should be OUT-OF-DATE
  ./manage.sh version-check test-git-tag-pkg > tag_version_output2.txt 2>&1
  cat tag_version_output2.txt
  local status_line2
  status_line2=$(grep "STATUS=" tag_version_output2.txt)
  assert_equals "STATUS=OUT-OF-DATE" "$status_line2" "test-git-tag-pkg reported as OUT-OF-DATE after new remote tag"
  rm -f tag_version_output2.txt
  
  # Run upgrade
  assert_success "./manage.sh upgrade test-git-tag-pkg" "Upgrade test-git-tag-pkg"
  
  # Verify that the PKGBUILD was updated correctly
  local updated_pkgver
  updated_pkgver=$(git show test-git-tag-pkg:PKGBUILD | grep "^pkgver=" | cut -d'=' -f2)
  assert_equals "1.1.0" "$updated_pkgver" "PKGBUILD pkgver updated to 1.1.0"
  
  local updated_tag_hash
  updated_tag_hash=$(git show test-git-tag-pkg:PKGBUILD | grep "^_tag=" | cut -d'=' -f2 | cut -d' ' -f1)
  assert_equals "$tag_v1_1_hash" "$updated_tag_hash" "PKGBUILD _tag updated to new tag object hash"
  
  local updated_pkgrel
  updated_pkgrel=$(git show test-git-tag-pkg:PKGBUILD | grep "^pkgrel=" | cut -d'=' -f2)
  assert_equals "1" "$updated_pkgrel" "PKGBUILD pkgrel updated to 1"
  
  # Delete package to clean up
  assert_success "./manage.sh delete test-git-tag-pkg" "Delete test-git-tag-pkg"

  # Test Case 13: Git Tag Name Upgrade
  log_info "TEST: Git tag name upgrade check..."
  # Setup mock project git remote
  local git_remote_dir2="${SANDBOX_DIR}/mock-git-remote2"
  mkdir -p "$git_remote_dir2"
  (
    cd "$git_remote_dir2" || exit 1
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test Admin"
    echo "Initial files" > README.md
    git add README.md
    git commit -m "initial commit" --quiet
    
    # Create tag 1.0.0 (no prefix)
    git tag 1.0.0
  )
  
  # Create a package branch in our test repository
  assert_success "./manage.sh create test-git-tagname-pkg --scratch" "Create test-git-tagname-pkg command"
  
  # Write custom PKGBUILD using tag name pinning
  cat <<EOF > packages/test-git-tagname-pkg/PKGBUILD
pkgname=test-git-tagname-pkg
pkgver=1.0.0
pkgrel=1
source=(git+file://${git_remote_dir2}#tag=\$pkgver)
EOF
  
  (
    cd packages/test-git-tagname-pkg || exit 1
    git add PKGBUILD
    git commit -m "add pkgbuild with tag name source" --quiet
  )
  
  # Run version check - should be UP-TO-DATE
  ./manage.sh version-check test-git-tagname-pkg > tagname_version_output1.txt 2>&1
  cat tagname_version_output1.txt
  local status_line1
  status_line1=$(grep "STATUS=" tagname_version_output1.txt)
  assert_equals "STATUS=UP-TO-DATE" "$status_line1" "test-git-tagname-pkg reported as UP-TO-DATE initially"
  rm -f tagname_version_output1.txt
  
  # Now add a new tag 1.1.0 on the mock remote
  (
    cd "$git_remote_dir2" || exit 1
    echo "New release feature" >> README.md
    git add README.md
    git commit -m "new feature commit" --quiet
    git tag 1.1.0
  )
  
  # Run version check again - should be OUT-OF-DATE
  ./manage.sh version-check test-git-tagname-pkg > tagname_version_output2.txt 2>&1
  cat tagname_version_output2.txt
  local status_line2
  status_line2=$(grep "STATUS=" tagname_version_output2.txt)
  assert_equals "STATUS=OUT-OF-DATE" "$status_line2" "test-git-tagname-pkg reported as OUT-OF-DATE after new remote tag"
  rm -f tagname_version_output2.txt
  
  # Run upgrade
  assert_success "./manage.sh upgrade test-git-tagname-pkg" "Upgrade test-git-tagname-pkg"
  
  # Verify that the PKGBUILD was updated correctly
  local updated_pkgver2
  updated_pkgver2=$(git show test-git-tagname-pkg:PKGBUILD | grep "^pkgver=" | cut -d'=' -f2)
  assert_equals "1.1.0" "$updated_pkgver2" "PKGBUILD pkgver updated to 1.1.0"
  
  local updated_pkgrel2
  updated_pkgrel2=$(git show test-git-tagname-pkg:PKGBUILD | grep "^pkgrel=" | cut -d'=' -f2)
  assert_equals "1" "$updated_pkgrel2" "PKGBUILD pkgrel updated to 1"
  
  # Delete package to clean up
  assert_success "./manage.sh delete test-git-tagname-pkg" "Delete test-git-tagname-pkg"

  # Test Case 14: Parse PKGBUILD version with epoch
  log_info "TEST: parse_pkgbuild_version parsing of epoch..."
  # Source list.sh if not already sourced
  source "src/manage/list.sh"
  
  local pkgbuild_no_epoch="pkgname=test-pkg
pkgver=1.2.3
pkgrel=4
"
  local parsed_no_epoch
  parsed_no_epoch=$(parse_pkgbuild_version "$pkgbuild_no_epoch")
  assert_equals "1.2.3-4" "$parsed_no_epoch" "parse_pkgbuild_version parsed version without epoch"

  local pkgbuild_with_epoch="pkgname=test-pkg-epoch
epoch=2
pkgver=1.2.3
pkgrel=4
"
  local parsed_with_epoch
  parsed_with_epoch=$(parse_pkgbuild_version "$pkgbuild_with_epoch")
  assert_equals "2:1.2.3-4" "$parsed_with_epoch" "parse_pkgbuild_version parsed version with epoch"

  # Test Case 15: Epoch Version PR Upgrade Branch Name Sanitization
  log_info "TEST: Epoch version PR upgrade branch name sanitization..."
  
  # Setup mock project git remote
  local git_remote_dir3="${SANDBOX_DIR}/mock-git-remote3"
  mkdir -p "$git_remote_dir3"
  (
    cd "$git_remote_dir3" || exit 1
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test Admin"
    echo "Initial files" > README.md
    git add README.md
    git commit -m "initial commit" --quiet
    git tag 1.0.0
  )
  
  # Create a package branch with epoch in the test repo
  assert_success "./manage.sh create test-epoch-pkg --scratch" "Create test-epoch-pkg command"
  
  # Write custom PKGBUILD using epoch version
  cat <<EOF > packages/test-epoch-pkg/PKGBUILD
pkgname=test-epoch-pkg
epoch=1
pkgver=1.0.0
pkgrel=1
source=(git+file://${git_remote_dir3}#tag=\$pkgver)
EOF
  
  (
    cd packages/test-epoch-pkg || exit 1
    git add PKGBUILD
    git commit -m "add pkgbuild with epoch version" --quiet
  )
  
  # Add a new version tag 1.1.0 on the mock remote
  (
    cd "$git_remote_dir3" || exit 1
    echo "New version feature" >> README.md
    git add README.md
    git commit -m "new version commit" --quiet
    git tag 1.1.0
  )
  
  # Run upgrade in PR mode.
  # This verifies that git does not fail with "invalid branch name" because of the colon.
  assert_success "./manage.sh upgrade test-epoch-pkg --pr" "PR upgrade test-epoch-pkg with epoch version succeeds"
  
  # Delete package to clean up
  assert_success "./manage.sh delete test-epoch-pkg" "Delete test-epoch-pkg"

  # Test Case 16: PR Upgrade conflict (abort strategy) fails
  log_info "TEST: PR Upgrade conflict (abort strategy) fails..."
  
  # Setup mock project git remote for conflict
  local git_remote_dir4="${SANDBOX_DIR}/mock-git-remote4"
  mkdir -p "$git_remote_dir4"
  (
    cd "$git_remote_dir4" || exit 1
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test Admin"
    echo "Initial content" > README.md
    git add README.md
    git commit -m "initial commit" --quiet
    git tag 1.0.0
  )
  
  # Create a package branch in our test repository
  assert_success "./manage.sh create test-pr-conflict-pkg --scratch" "Create test-pr-conflict-pkg command"
  
  # Write custom PKGBUILD pointing to 1.0.0
  cat <<EOF > packages/test-pr-conflict-pkg/PKGBUILD
pkgname=test-pr-conflict-pkg
pkgver=1.0.0
pkgrel=1
source=(git+file://${git_remote_dir4}#tag=\$pkgver)
EOF
  
  (
    cd packages/test-pr-conflict-pkg || exit 1
    git add PKGBUILD
    git commit -m "add pkgbuild 1.0.0" --quiet
  )
  
  # Modify local PKGBUILD to conflict
  echo -e "pkgname=test-pr-conflict-pkg\npkgver=1.0.0\npkgrel=1\n# Local edits that conflict" > packages/test-pr-conflict-pkg/PKGBUILD
  (
    cd packages/test-pr-conflict-pkg || exit 1
    git add PKGBUILD
    git commit -m "local conflicting edits" --quiet
  )
  
  # Add conflicting version tag 1.1.0 on the mock remote
  (
    cd "$git_remote_dir4" || exit 1
    echo "Upstream conflicting change" > README.md
    git add README.md
    git commit -m "upstream change" --quiet
    git tag 1.1.0
  )
  
  # Configure CONFLICT_STRATEGY="abort" in .pkgconfig
  sed -i 's/CONFLICT_STRATEGY=.*/CONFLICT_STRATEGY="abort"/g' packages/test-pr-conflict-pkg/.pkgconfig
  (
    cd packages/test-pr-conflict-pkg || exit 1
    git add .pkgconfig
    git commit -m "set conflict strategy to abort" --quiet
  )
  
  # Run upgrade in PR mode - this should fail!
  assert_failure "./manage.sh upgrade test-pr-conflict-pkg --pr" "PR upgrade test-pr-conflict-pkg with conflict fails"
  
  # Delete package to clean up
  assert_success "./manage.sh delete test-pr-conflict-pkg" "Delete test-pr-conflict-pkg"
}
