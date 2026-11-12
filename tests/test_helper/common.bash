#!/usr/bin/env bash

# Shared test setup loader for every *.bats file under tests/.
# Each .bats file's setup() does: load 'test_helper/common'
#
# Globals exported:
#   REPO_DIR — repo root, resolved from BATS_TEST_DIRNAME
#   GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM — /dev/null
#   GIT_CEILING_DIRECTORIES — the repo root
#
# Globals unset:
#   every repo-local GIT_* variable `git rev-parse --local-env-vars` names
#   BASH_ENV

REPO_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
export REPO_DIR

# bats-support / bats-assert resolve through the BATS_LIB_PATH that the flake's
# bats wrapper exports. A bats that cannot find the libraries fails loudly here
# rather than silently missing assertions.
bats_load_library 'bats-support'
bats_load_library 'bats-assert'

# --- Fixture-escape hardening: every test is hermetic w.r.t. the real repo ---

# A caller may carry repo-scoped GIT_* vars; with GIT_DIR set, `git -C <fixture>`
# ignores the fixture path and operates on the real repo. Unset them all.
_git_local_env_vars="$(git rev-parse --local-env-vars)"
while IFS= read -r _git_env_var; do
  unset "${_git_env_var}"
done <<< "${_git_local_env_vars}"
unset _git_local_env_vars _git_env_var

# Host git config must never leak into fixtures, and a fixture must never write
# the inverse back into the real shared config.
export GIT_CONFIG_GLOBAL='/dev/null'
export GIT_CONFIG_SYSTEM='/dev/null'

# Upward repo discovery from a fixture path must never cross into the real repo.
export GIT_CEILING_DIRECTORIES="${REPO_DIR}"

# Stop child bash processes from re-sourcing the user's interactive ~/.bashrc,
# which would clobber the per-test environment.
unset BASH_ENV
