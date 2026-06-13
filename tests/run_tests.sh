#!/usr/bin/env bash

# Arch Linux AUR-Based Repository System - Test Suite Runner

# Resolve workspace root directory
export WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source test scripts
# shellcheck source=tests/test_helper.sh
source "${WORKSPACE_DIR}/tests/test_helper.sh"
# shellcheck source=tests/test_manage.sh
source "${WORKSPACE_DIR}/tests/test_manage.sh"
# shellcheck source=tests/test_build.sh
source "${WORKSPACE_DIR}/tests/test_build.sh"

# Global tracking variable for test failures
TEST_FAILED=0

# Ensure sandbox is cleaned up on exit
cleanup_and_exit() {
  teardown_sandbox
  if [ "$TEST_FAILED" -ne 0 ]; then
    echo -e "\n\033[1;31m[FAILURE] Some tests did not pass!\033[0m"
    exit 1
  else
    echo -e "\n\033[1;32m[SUCCESS] All tests passed successfully!\033[0m"
    exit 0
  fi
}

trap cleanup_and_exit EXIT

# Start Test Suite execution
echo "Initializing Test Sandbox..."
setup_sandbox

# Run management CLI tests
run_manage_tests

# Run build automation tests
run_build_tests
