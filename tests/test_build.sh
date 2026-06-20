# Build automation CLI unit and integration tests
# Sources test_helper.sh

run_build_tests() {
  echo -e "\n================================================================================"
  echo -e "RUNNING BUILD SERVER AUTOMATION TESTS (build.sh)"
  echo -e "================================================================================"

  # Test Case 1: Fresh Build Scan
  log_info "TEST: Scan package branches with empty database..."
  assert_success "./build.sh --scan-only" "Scanner runs successfully when database is empty"
  
  # Test Case 2: Compilation queue and compilation execution
  log_info "TEST: Run build for all packages..."
  # Clean up packages first to ensure clean state
  rm -rf repo/*
  
  # Verify compile executes and builds all packages in queue (test-pkg-copy and librewolf-bin)
  assert_success "./build.sh" "Builder execution"
  
  # Check if packages are moved to repo/ and database is created
  assert_file_exists "repo/custom.db.tar.gz" "Repository database custom.db.tar.gz created"
  assert_file_exists "repo/status.json" "Repository build status.json created"
  assert_file_exists "repo/librewolf-bin-126.0.0-1-any.pkg.tar.zst" "Main librewolf-bin package moved to repo/"
  assert_file_exists "repo/librewolf-bin-debug-126.0.0-1-any.pkg.tar.zst" "Debug librewolf-bin package moved to repo/"
  assert_success "[ -d cache/sources ]" "Source cache directory cache/sources exists"
  assert_success "[ -d cache/packages ]" "Pacman package cache directory cache/packages exists"
  assert_success "[ -d cache/ccache ]" "Compiler cache directory cache/ccache exists"
  
  # Check status.json content is correct
  local repo_status
  repo_status=$(grep -o '"status": "[^"]*"' repo/status.json | cut -d'"' -f4)
  assert_equals "success" "$repo_status" "Repository build status is 'success'"

  if [ "$BUILD_METHOD" = "chroot" ]; then
    assert_file_exists "extra_x86_64_build_args.log" "Chroot builds logged arguments"
    local has_deps_flag
    has_deps_flag=$(grep -c "\-I" extra_x86_64_build_args.log)
    assert_success "[ \"$has_deps_flag\" -gt 0 ]" "Clean chroot called with dependency install flags (-I)"
    local has_cache_flag
    has_cache_flag=$(grep -c "\-d .*cache/packages:/var/cache/pacman/pkg" extra_x86_64_build_args.log)
    assert_success "[ \"$has_cache_flag\" -gt 0 ]" "Clean chroot called with pacman package cache bind mount (-d)"
    local has_gpg_flag
    has_gpg_flag=$(grep -c "\-d .*\.gnupg:/build/.gnupg" extra_x86_64_build_args.log)
    assert_success "[ \"$has_gpg_flag\" -gt 0 ]" "Clean chroot called with GPG keyring bind mount (-d)"
    local has_ccache_flag
    has_ccache_flag=$(grep -c "\-d .*cache/ccache:/ccache" extra_x86_64_build_args.log)
    assert_success "[ \"$has_ccache_flag\" -gt 0 ]" "Clean chroot called with ccache compiler cache bind mount (-d)"
    local has_ccache_dir_env
    has_ccache_dir_env=$(grep -c "CCACHE_DIR=/ccache" extra_x86_64_build_args.log)
    assert_success "[ \"$has_ccache_dir_env\" -gt 0 ]" "Clean chroot called with CCACHE_DIR=/ccache environment argument"
    
    # Assert that devtools options (-d, -I) are placed after the first "--" separator in extra-x86_64-build
    assert_success "grep -q -- \" -- .* \-d \" extra_x86_64_build_args.log" "GPG/pacman cache mounts passed after the -- separator"
    assert_success "grep -q -- \" -- .* \-I \" extra_x86_64_build_args.log" "Local dependencies passed after the -- separator"
  fi
  rm -f extra_x86_64_build_args.log

  # Test Case 3: Re-scan with up-to-date database
  log_info "TEST: Re-scan when database is up-to-date..."
  # Check output contains SKIP for up-to-date packages
  ./build.sh --scan-only > scan_output.txt
  local skip_count
  skip_count=$(grep -c "SKIP" scan_output.txt)
  # Both test-pkg-copy and librewolf-bin should be skipped
  assert_equals "2" "$skip_count" "Both package branches are skipped"

  # Test Case 4: Re-scan after version bump
  log_info "TEST: Scan after bumping branch version..."
  # Bump test-pkg-copy version
  echo -e "pkgname=test-pkg-copy\npkgver=0.0.2\npkgrel=1\ndepends=('librewolf-bin')" > packages/test-pkg-copy/PKGBUILD
  (
    cd packages/test-pkg-copy || exit 1
    git add PKGBUILD
    git commit -m "bump version to 0.0.2" --quiet
  )
  
  # Scan should now report BUMP for test-pkg-copy
  ./build.sh --scan-only > scan_bump_output.txt
  local bump_found
  bump_found=$(grep -c "BUILD (Bump)" scan_bump_output.txt)
  assert_equals "1" "$bump_found" "One branch version bump detected"

  # Test Case 5: Compile bumped package and clean up old package archive
  log_info "TEST: Compile bumped package and clean up older version..."
  # Ensure we have the old package in repo/
  local old_package_count
  old_package_count=$(find repo/ -name "test-pkg-copy-*.pkg.tar.*" | wc -l)
  
  # Run build to compile 0.0.2 version
  assert_success "./build.sh" "Compile bump version"
  
  # Verify new package is built
  local new_pkg
  new_pkg=$(find repo/ -name "test-pkg-copy-0.0.2-1-*.pkg.tar.zst")
  assert_equals "1" "$(echo "$new_pkg" | wc -w)" "New package test-pkg-copy-0.0.2-1 built"
  
  # Verify old package is removed (since CLEAN_OLD_PACKAGES=true)
  local total_pkg_files
  total_pkg_files=$(find repo/ -name "test-pkg-copy-*.pkg.tar.zst" | wc -l)
  assert_equals "1" "$total_pkg_files" "Old version cleaned up (only 1 test-pkg-copy file remains)"

  # Test Case 6: Concurrent lock blocking
  log_info "TEST: Concurrency lock blocks double builds..."
  # Open lock manually in background
  (
    exec 9> repo/repo.lock
    flock -n 9
    sleep 3
  ) &
  local lock_pid=$!
  sleep 0.5 # wait for background process to lock
  
  # Run build.sh, which should fail because of lock conflict
  assert_failure "./build.sh" "Concurrency conflict failure"
  
  # Wait for lock background process to release
  wait $lock_pid

  # Test Case 7: Graceful compilation failure handling
  log_info "TEST: Graceful handling of compilation failures..."
  # Create a package that fails to compile
  ./manage.sh create failing-pkg --copy-main >/dev/null
  # Inject compile error in makepkg mock
  # By removing PKGBUILD or making it invalid
  echo "invalid-syntax" > packages/failing-pkg/PKGBUILD
  (
    cd packages/failing-pkg || exit 1
    git add PKGBUILD
    git commit -m "add invalid pkgbuild" --quiet
  )
  
  # Run builder, which should fail because of failing-pkg compilation error, but complete the queue
  assert_failure "./build.sh" "Builder fails when a package in the queue fails to compile"
  
  # Check that status.json records the failure
  repo_status=$(grep -o '"status": "[^"]*"' repo/status.json | cut -d'"' -f4)
  assert_equals "failed" "$repo_status" "Repository build status is 'failed'"
  
  # Cleanup
  ./manage.sh delete failing-pkg >/dev/null

  # Test Case 8: GPG Key management and validation verification
  log_info "TEST: GPG Key management and validation verification..."
  # Create a package with validpgpkeys array in PKGBUILD
  ./manage.sh create pgp-pkg --copy-main >/dev/null
  echo -e "pkgname=pgp-pkg\npkgver=0.0.1\npkgrel=1\nvalidpgpkeys=('ABCDEF0123456789' '9876543210FEDCBA')" > packages/pgp-pkg/PKGBUILD
  (
    cd packages/pgp-pkg || exit 1
    git add PKGBUILD
    git commit -m "add pkgbuild with validpgpkeys" --quiet
  )
  
  # Clear mock gpg import log if exists
  rm -f gpg_imports.log
  
  # Running build first without importing keys should print a warning about missing keys
  ./build.sh > build_gpg_warn.txt 2>&1
  local warn_count
  warn_count=$(grep -c "is required but not present in the keyring" build_gpg_warn.txt)
  assert_equals "2" "$warn_count" "Warnings printed for missing GPG keys"
  
  # Import keys manually via package manager CLI
  assert_success "./manage.sh import-key ABCDEF0123456789 9876543210FEDCBA" "Import keys manually via manage.sh"
  
  # Check if keys were logged by mock gpg import trace
  assert_file_exists "gpg_imports.log" "GPG import trace log created"
  local import_count
  import_count=$(grep -c -E "ABCDEF0123456789|9876543210FEDCBA" gpg_imports.log)
  assert_equals "2" "$import_count" "Both GPG keys imported via manage.sh"
  
  # Running build again after import should NOT print warnings about missing keys
  ./build.sh > build_gpg_clean.txt 2>&1
  local warn_count_after
  warn_count_after=$(grep -c "is required but not present in the keyring" build_gpg_clean.txt)
  assert_equals "0" "$warn_count_after" "No warnings printed after GPG keys are imported"
  
  # Verify custom GNUPGHOME directory exists and has 700 permissions
  assert_success "[ -d .gnupg ]" "Custom GNUPGHOME directory created"
  assert_success "[ \"\$(stat -c %a .gnupg)\" = \"700\" ]" "Custom GNUPGHOME has correct 700 permissions"

  # Test Case 9: Verify globally writable cache directories permissions
  log_info "TEST: Verify cache directories permissions..."
  assert_success "[ \"\$(stat -c %a cache/sources)\" = \"777\" ]" "cache/sources directory is globally writable (777)"
  assert_success "[ \"\$(stat -c %a cache/packages)\" = \"777\" ]" "cache/packages directory is globally writable (777)"
  assert_success "[ \"\$(stat -c %a cache/ccache)\" = \"777\" ]" "cache/ccache directory is globally writable (777)"
  
  # Test Case 10: GPG directory ownership mismatch check
  log_info "TEST: GPG directory ownership mismatch check..."
  local original_gnupg="$GNUPGHOME"
  export GNUPGHOME="mock_gpg_home"
  (
    source src/common.sh
    init_dirs
  ) > gpg_ownership_test.txt 2>&1
  assert_success "grep -q 'mismatch' gpg_ownership_test.txt" "Ownership mismatch warning printed"
  assert_success "grep -q 'chown' gpg_ownership_test.txt" "Ownership correction instruction printed"
  rm -rf mock_gpg_home gpg_ownership_test.txt
  export GNUPGHOME="$original_gnupg"

  # Test Case 11: Package and database GPG signing verification (SIGN_PACKAGES=true)
  log_info "TEST: Package and database GPG signing verification..."
  rm -rf repo/*
  cp config.conf config.conf.bak
  echo -e "\nSIGN_PACKAGES=\"true\"\nGPG_KEY=\"MOCK_SIGNING_KEY_ID\"\nGNUPGHOME=\".gnupg\"" >> config.conf
  assert_success "./build.sh -f" "Builder execution with GPG signing enabled"
  assert_file_exists "repo/custom.db.tar.gz" "Repository database created"
  assert_file_exists "repo/custom.db.tar.gz.sig" "Repository database signature created"
  assert_file_exists "repo/librewolf-bin-126.0.0-1-any.pkg.tar.zst.sig" "Main package signature created"
  assert_file_exists "repo/librewolf-bin-debug-126.0.0-1-any.pkg.tar.zst.sig" "Debug package signature created"
  mv config.conf.bak config.conf

  # Test Case 12: Specific package force rebuild verification
  log_info "TEST: Specific package force rebuild verification..."
  assert_success "./build.sh" "Ensure all packages are built and database is up to date"
  rm -rf logs/*
  assert_success "./build.sh -f test-pkg-copy" "Run force rebuild for specific package"
  local compiled_test_pkg
  compiled_test_pkg=$(find logs/ -name "test-pkg-copy-*.log" | wc -l)
  assert_equals "1" "$compiled_test_pkg" "test-pkg-copy was compiled"
  local compiled_librewolf
  compiled_librewolf=$(find logs/ -name "librewolf-bin-*.log" | wc -l)
  assert_equals "0" "$compiled_librewolf" "librewolf-bin was skipped"
  assert_failure "./build.sh -f non-existent-pkg" "Should fail when forcing non-existent package"

  # Verify that other outstanding updates are ignored when forcing a specific package
  # Introduce outstanding update on librewolf-bin (which would normally trigger a scan build)
  echo -e "pkgname=librewolf-bin\npkgver=127.0.0\npkgrel=1" > packages/librewolf-bin/PKGBUILD
  (
    cd packages/librewolf-bin || exit 1
    git add PKGBUILD
    git commit -m "bump librewolf-bin version to 127.0.0" --quiet
  )
  rm -rf logs/*
  assert_success "./build.sh -f test-pkg-copy" "Run specific package force rebuild when other packages have outstanding updates"
  compiled_test_pkg=$(find logs/ -name "test-pkg-copy-*.log" | wc -l)
  assert_equals "1" "$compiled_test_pkg" "Only test-pkg-copy was compiled"
  compiled_librewolf=$(find logs/ -name "librewolf-bin-*.log" | wc -l)
  assert_equals "0" "$compiled_librewolf" "librewolf-bin was skipped despite having outstanding updates"
  # Revert the temporary version bump commit
  (
    cd packages/librewolf-bin || exit 1
    git reset --hard HEAD~1 --quiet
  )

  # Verify that running without package argument rebuilds all
  rm -rf logs/*
  assert_success "./build.sh -f" "Run force rebuild with no package argument (should rebuild all)"
  local compiled_test_pkg_all
  compiled_test_pkg_all=$(find logs/ -name "test-pkg-copy-*.log" | wc -l)
  assert_equals "1" "$compiled_test_pkg_all" "test-pkg-copy was force rebuilt"
  local compiled_librewolf_all
  compiled_librewolf_all=$(find logs/ -name "librewolf-bin-*.log" | wc -l)
  assert_equals "1" "$compiled_librewolf_all" "librewolf-bin was force rebuilt"

  # Test Case 13: Exclusion of upgrade/ branches in scan
  log_info "TEST: Exclusion of upgrade/ branches in scan..."
  # Create a branch starting with upgrade/ without checking it out
  git branch upgrade/test-ignored-branch librewolf-bin
  
  # Run scan-only and capture output
  ./build.sh --scan-only > scan_upgrade_output.txt
  
  local upgrade_branch_scanned
  upgrade_branch_scanned=$(grep -c "upgrade/test-ignored-branch" scan_upgrade_output.txt)
  assert_equals "0" "$upgrade_branch_scanned" "upgrade/ branches are excluded from scan"
  
  # Delete the test branch
  git branch -D upgrade/test-ignored-branch --quiet
  rm -f scan_upgrade_output.txt

  # Test Case 14: Sign and Unsign command post-build
  log_info "TEST: Sign and Unsign command post-build..."
  # Import mock signing key so gpg --list-keys check passes
  assert_success "./manage.sh import-key MOCK_SIGNING_KEY_ID" "Import signing key"
  
  # First, build all packages with signing disabled
  rm -rf repo/*
  # Ensure sign_packages is false in config
  cp config.conf config.conf.bak
  sed -i 's/SIGN_PACKAGES=.*/SIGN_PACKAGES="false"/g' config.conf
  
  assert_success "./build.sh -f" "Compile packages unsigned"
  assert_file_exists "repo/custom.db.tar.gz" "Unsigned database created"
  assert_file_not_exists "repo/custom.db.tar.gz.sig" "No database signature should exist"
  assert_file_not_exists "repo/librewolf-bin-126.0.0-1-any.pkg.tar.zst.sig" "No package signature should exist"
  
  # Run manage.sh sign
  assert_success "./manage.sh sign --key MOCK_SIGNING_KEY_ID --gnupghome .gnupg" "Sign existing unsigned repository"
  assert_file_exists "repo/custom.db.tar.gz.sig" "Database signature created post-build"
  assert_file_exists "repo/librewolf-bin-126.0.0-1-any.pkg.tar.zst.sig" "Package signature created post-build"
  
  # Verify config.conf was updated (forward compatibility)
  local config_sign_packages
  config_sign_packages=$(grep "^SIGN_PACKAGES=" config.conf | cut -d'=' -f2 | tr -d '"'\')
  assert_equals "true" "$config_sign_packages" "SIGN_PACKAGES was enabled in config.conf"
  local config_gpg_key
  config_gpg_key=$(grep "^GPG_KEY=" config.conf | cut -d'=' -f2 | tr -d '"'\')
  assert_equals "MOCK_SIGNING_KEY_ID" "$config_gpg_key" "GPG_KEY was saved in config.conf"
  
  # Run manage.sh unsign
  assert_success "./manage.sh unsign" "Unsign repository"
  assert_file_not_exists "repo/custom.db.tar.gz.sig" "Database signature removed"
  assert_file_not_exists "repo/librewolf-bin-126.0.0-1-any.pkg.tar.zst.sig" "Package signature removed"
  
  # Verify config.conf was updated to SIGN_PACKAGES="false"
  config_sign_packages=$(grep "^SIGN_PACKAGES=" config.conf | cut -d'=' -f2 | tr -d '"'\')
  assert_equals "false" "$config_sign_packages" "SIGN_PACKAGES was disabled in config.conf"
  
  # Restore config
  mv config.conf.bak config.conf

  # Cleanup
  ./manage.sh delete pgp-pkg >/dev/null
  rm -f gpg_imports.log build_gpg_warn.txt build_gpg_clean.txt
}
