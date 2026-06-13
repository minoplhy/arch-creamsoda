# Integration and unit tests for git-bare-worktree.sh
# Sources test_helper.sh

run_worktree_tests() {
  echo -e "\n================================================================================"
  echo -e "RUNNING GIT BARE WORKTREE TESTS (git-bare-worktree.sh)"
  echo -e "================================================================================"

  # Enable local file protocol for submodules in tests (required by git security updates since git 2.38)
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0=protocol.file.allow
  export GIT_CONFIG_VALUE_0=always

  # 1. Setup local mock remote repository in sandbox
  local upstream_dir="${SANDBOX_DIR}/mock-remote-git"
  mkdir -p "$upstream_dir"
  
  local submodule_upstream_dir="${SANDBOX_DIR}/mock-submodule-git"
  mkdir -p "$submodule_upstream_dir"
  (
    cd "$submodule_upstream_dir" || exit 1
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test Admin"
    echo "Submodule file content" > sub-file.txt
    git add sub-file.txt
    git commit -m "initial submodule commit" --quiet
  )

  (
    cd "$upstream_dir" || exit 1
    git init --quiet
    git config user.email "test@example.com"
    git config user.name "Test Admin"
    echo "Initial file" > file.txt
    git add file.txt
    git commit -m "initial commit" --quiet
    
    # Create another branch to test
    git checkout -b feature-test --quiet
    echo "Feature change" > feature.txt
    git add feature.txt
    git commit -m "feature commit" --quiet

    # Add mock submodule using file:// URI to prevent compatibility warnings
    git submodule add --quiet "file://${submodule_upstream_dir}" my-submodule
    git commit -m "added submodule" --quiet
    
    # Return to master/main
    git checkout master --quiet 2>/dev/null || git checkout main --quiet
  )

  local bare_repo="${SANDBOX_DIR}/bare-repo.git"
  local worktree_dir="${SANDBOX_DIR}/worktree-target"
  local script_path="${WORKSPACE_DIR}/git-bare-worktree.sh"

  # Test Case 1: Setup bare repository from mock remote
  log_info "TEST: Bare clone setup..."
  assert_success "${script_path} setup \"${upstream_dir}\" \"${bare_repo}\"" "Bare repository setup command"
  assert_file_exists "${bare_repo}/config" "Bare config file exists"

  # Verify it is bare
  local is_bare
  is_bare=$(git -C "$bare_repo" rev-parse --is-bare-repository)
  assert_equals "true" "$is_bare" "Repository is configured as bare"

  # Verify the fetch refspec is set to refs/remotes/origin/*
  local fetch_refspec
  fetch_refspec=$(git -C "$bare_repo" config remote.origin.fetch)
  assert_equals "+refs/heads/*:refs/remotes/origin/*" "$fetch_refspec" "Fetch refspec maps to refs/remotes/origin/*"

  # Verify remote refs are tracked
  local refs_list
  refs_list=$(git -C "$bare_repo" show-ref)
  local has_remote_master=0
  local has_remote_feature=0
  if echo "$refs_list" | grep -q "refs/remotes/origin/master" || echo "$refs_list" | grep -q "refs/remotes/origin/main"; then
    has_remote_master=1
  fi
  if echo "$refs_list" | grep -q "refs/remotes/origin/feature-test"; then
    has_remote_feature=1
  fi
  assert_equals "1" "$has_remote_master" "Tracks upstream default branch"
  assert_equals "1" "$has_remote_feature" "Tracks upstream feature-test branch"


  # Test Case 2: Sync worktree using Option B (Tracking Branch)
  log_info "TEST: Sync worktree with tracking branch (Option B)..."
  assert_success "${script_path} sync \"${bare_repo}\" \"feature-test\" \"${worktree_dir}\"" "Sync feature-test worktree"
  
  # Verify files are checked out
  assert_file_exists "${worktree_dir}/feature.txt" "Feature file present in worktree"
  assert_file_exists "${worktree_dir}/file.txt" "Initial file present in worktree"
  assert_file_exists "${worktree_dir}/my-submodule/sub-file.txt" "Submodule file present and initialized in worktree"

  # Verify Option B (Observability/Tracking Branch)
  local wt_branch
  wt_branch=$(cd "$worktree_dir" && git branch --show-current)
  assert_equals "feature-test" "$wt_branch" "Worktree is checked out on local branch 'feature-test'"

  local wt_upstream
  wt_upstream=$(cd "$worktree_dir" && git config "branch.${wt_branch}.remote")
  assert_equals "origin" "$wt_upstream" "Upstream remote is 'origin'"

  local wt_merge
  wt_merge=$(cd "$worktree_dir" && git config "branch.${wt_branch}.merge")
  assert_equals "refs/heads/feature-test" "$wt_merge" "Upstream branch is 'refs/heads/feature-test'"


  # Test Case 3: Sync a non-existent branch (should fail)
  log_info "TEST: Sync non-existent branch fails..."
  assert_failure "${script_path} sync \"${bare_repo}\" \"non-existent-branch\" \"${SANDBOX_DIR}/wt-fail\"" "Syncing non-existent branch fails"


  # Test Case 3b: Update bare repository database (standalone)
  log_info "TEST: Update bare repository database (standalone)..."
  # Add a new branch to the upstream remote
  (
    cd "$upstream_dir" || exit 1
    git checkout -b new-branch-for-update --quiet
    echo "Update test" > update-test.txt
    git add update-test.txt
    git commit -m "added update-test branch" --quiet
    git checkout master --quiet 2>/dev/null || git checkout main --quiet
  )
  
  # Run update
  assert_success "${script_path} update \"${bare_repo}\"" "Bare repository update command"
  
  # Verify that the new branch reference is fetched and tracked
  local refs_after_update
  refs_after_update=$(git -C "$bare_repo" show-ref)
  local has_new_branch=0
  if echo "$refs_after_update" | grep -q "refs/remotes/origin/new-branch-for-update"; then
    has_new_branch=1
  fi
  assert_equals "1" "$has_new_branch" "Bare repository has fetched the new remote branch reference"


  # Test Case 4: Sync/Update worktree after remote has new commits
  log_info "TEST: Sync updates worktree with new upstream commits..."
  # Add a new commit to mock upstream branch 'feature-test'
  (
    cd "$upstream_dir" || exit 1
    git checkout feature-test --quiet
    echo "New modification" >> feature.txt
    git add feature.txt
    git commit -m "newer feature commit" --quiet
  )

  # Sync again
  assert_success "${script_path} sync \"${bare_repo}\" \"feature-test\" \"${worktree_dir}\"" "Re-sync/update feature-test worktree"

  # Verify the new change is present in the worktree
  local feature_content
  feature_content=$(cat "${worktree_dir}/feature.txt")
  local has_new_mod=0
  if echo "$feature_content" | grep -q "New modification"; then
    has_new_mod=1
  fi
  assert_equals "1" "$has_new_mod" "Worktree contains the new remote modifications"


  # Test Case 5: Sync updates worktree with dirty local state (autoclean)
  log_info "TEST: Sync resolves dirty local worktree state..."
  # Make local modifications inside the worktree (simulating a build directory with leftover files/dirty state)
  echo "Dirty uncommitted changes" > "${worktree_dir}/feature.txt"
  echo "Untracked build file" > "${worktree_dir}/build_output.log"

  # Sync again (the script should forcefully remove the dirty worktree and sync a fresh one)
  assert_success "${script_path} sync \"${bare_repo}\" \"feature-test\" \"${worktree_dir}\"" "Syncing over dirty worktree succeeds"

  # Verify it's clean and has latest upstream changes
  feature_content=$(cat "${worktree_dir}/feature.txt")
  local has_dirty=0
  if echo "$feature_content" | grep -q "Dirty uncommitted changes"; then
    has_dirty=1
  fi
  assert_equals "0" "$has_dirty" "Dirty local modifications are cleaned up"
  assert_file_not_exists "${worktree_dir}/build_output.log" "Untracked files are removed"


  # Test Case 5b: Sync all packages (sync-packages)
  log_info "TEST: Sync all packages (sync-packages)..."
  local packages_sandbox_dir="${SANDBOX_DIR}/packages-test"
  mkdir -p "$packages_sandbox_dir"
  
  # Clean up previous worktree from earlier tests to free the local branch checkout lock
  assert_success "${script_path} cleanup \"${bare_repo}\" \"${worktree_dir}\"" "Cleanup worktree-target before sync-packages"
  
  assert_success "${script_path} sync-packages \"${bare_repo}\" \"${packages_sandbox_dir}\"" "Sync all packages command"
  
  # Assert that all package branches are checked out under packages_sandbox_dir
  # In our setup, we have "feature-test" and "new-branch-for-update"
  assert_file_exists "${packages_sandbox_dir}/feature-test/feature.txt" "Synced feature-test package worktree exists"
  assert_file_exists "${packages_sandbox_dir}/new-branch-for-update/update-test.txt" "Synced new-branch-for-update package worktree exists"
  assert_file_not_exists "${packages_sandbox_dir}/master" "master branch is ignored"
  assert_file_not_exists "${packages_sandbox_dir}/main" "main branch is ignored"


  # Test Case 6: Cleanup worktree
  log_info "TEST: Cleanup worktree..."
  assert_success "${script_path} cleanup \"${bare_repo}\" \"${worktree_dir}\"" "Cleanup worktree command"
  assert_file_not_exists "${worktree_dir}/feature.txt" "Worktree files are removed"
  
  local wt_list_after
  wt_list_after=$(git -C "$bare_repo" worktree list)
  local is_removed=1
  if echo "$wt_list_after" | grep -F " ${worktree_dir} " >/dev/null; then
    is_removed=0
  fi
  assert_equals "1" "$is_removed" "Worktree is removed from Git metadata"

  # Unset test-specific git config overrides
  unset GIT_CONFIG_COUNT
  unset GIT_CONFIG_KEY_0
  unset GIT_CONFIG_VALUE_0
}
