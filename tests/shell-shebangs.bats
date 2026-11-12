# .ci/check-shell-shebangs, against the real repo and against fixture
# repositories of tracked files with planted shebangs.
#
# setup sets CHECK, the gate under test.

function setup() {
  load 'test_helper/common'
  CHECK="${REPO_DIR}/.ci/check-shell-shebangs"
}

# @description Build a minimal tracked tree in the shape the gate scans: a git
#              repo holding one canonical bash script, one shebang-less
#              sourced part and one non-script data file. The negative cases
#              below then corrupt, add or remove files in it.
#
#              A real `git init` rather than a path walk, because the gate reads
#              its file list from `git ls-files` on purpose -- an untracked
#              scratch file must never reach it. common.bash's fixture-escape
#              hardening is what keeps this `git` from resolving to the author's
#              own checkout.
# @arg $1 root directory to populate
function make_shebang_fixture() {
  local -r root="$1"
  mkdir --parents "${root}/lib"
  printf '#!/usr/bin/env bash\necho ok\n' > "${root}/run-thing"
  printf '# shellcheck shell=bash\nfunction f() { :; }\n' > "${root}/lib/part.sh"
  printf 'root = true\n' > "${root}/.editorconfig"
  git -C "${root}" init --quiet
  git -C "${root}" add --all
}

# Every case drives FIXTURE mode, which needs nothing but bash and git, so there
# is no devShell skip here.
#
# The real-repo case is the exception that keeps the rest honest: it points the gate
# at the real repo, so a fixture that has drifted away from the shape the
# tracked sources actually have cannot hide behind a green suite.

@test "shell shebangs: the real repo passes" {
  # REPO_DIR explicitly rather than relying on the argument-less default: the
  # default resolves through `git rev-parse --show-toplevel`, and a bats test
  # must not depend on the directory the suite happened to be launched from.
  # Past that one branch the script runs the same either way.
  run "${CHECK}" "${REPO_DIR}"
  assert_success
  assert_output --partial 'shebangs canonical'
}

@test "shell shebangs: a valid fixture passes" {
  local -r root="${BATS_TEST_TMPDIR}/ok"
  make_shebang_fixture "${root}"
  run "${CHECK}" "${root}"
  assert_success
}

@test "shell shebangs: #!/bin/bash is named and rejected" {
  # The hole this gate closes. .ci/run-lint-checks' shell_files admits an
  # extensionless file only on the exact `#!/usr/bin/env bash` line, so a file
  # spelled this way would drop out of BOTH shellcheck and shfmt with no
  # diagnostic at all.
  local -r root="${BATS_TEST_TMPDIR}/bin-bash"
  make_shebang_fixture "${root}"
  printf '#!/bin/bash\necho ok\n' > "${root}/run-thing"
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'run-thing'
  assert_output --partial '#!/bin/bash'
  assert_output --partial '#!/usr/bin/env bash'
}

@test "shell shebangs: env -S bash is rejected too" {
  # The other spelling shell_files misses. It is bash, it works, and
  # shell_files would not match it.
  local -r root="${BATS_TEST_TMPDIR}/env-s"
  make_shebang_fixture "${root}"
  printf '#!/usr/bin/env -S bash\necho ok\n' > "${root}/run-thing"
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'non-canonical bash shebang'
}

@test "shell shebangs: a non-bash interpreter is rejected" {
  local -r root="${BATS_TEST_TMPDIR}/python"
  make_shebang_fixture "${root}"
  printf '#!/usr/bin/env python3\nprint("ok")\n' > "${root}/tool"
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'tool'
  assert_output --partial 'non-bash shebang'
}

@test "shell shebangs: an interpreter whose name merely starts with bash is not bash" {
  local -r root="${BATS_TEST_TMPDIR}/bashful"
  make_shebang_fixture "${root}"
  printf '#!/usr/bin/bashful\necho ok\n' > "${root}/tool"
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'non-bash shebang'
  refute_output --partial 'non-canonical bash shebang'
}

@test "shell shebangs: a shebang-less sourced part is not asked for one" {
  # A file that is sourced rather than executed carries no shebang on purpose.
  # The gate judges the shebangs that exist; it must never demand one.
  local -r root="${BATS_TEST_TMPDIR}/no-shebang"
  make_shebang_fixture "${root}"
  run "${CHECK}" "${root}"
  assert_success
  refute_output --partial 'part.sh'
}

@test "shell shebangs: a .bats file is skipped" {
  # bats files carry no shebang and the lint gate admits them by extension, so
  # the gate has no opinion about one that does.
  local -r root="${BATS_TEST_TMPDIR}/bats"
  make_shebang_fixture "${root}"
  printf '#!/bin/bash\n@test "x" { :; }\n' > "${root}/tests.bats"
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_success
  refute_output --partial 'tests.bats'
}

@test "shell shebangs: an untracked file is never graded" {
  local -r root="${BATS_TEST_TMPDIR}/untracked"
  make_shebang_fixture "${root}"
  printf '#!/bin/bash\necho ok\n' > "${root}/scratch"
  run "${CHECK}" "${root}"
  assert_success
  refute_output --partial 'scratch'
}

@test "shell shebangs: an empty scan is not a clean pass" {
  # Same class of bug as an empty tool list in check-devshell-provides: a gate
  # that looked at nothing and said ok.
  local -r root="${BATS_TEST_TMPDIR}/empty"
  mkdir --parents "${root}"
  printf 'root = true\n' > "${root}/.editorconfig"
  git -C "${root}" init --quiet
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'empty scan'
}

@test "shell shebangs: every failing file is named, not just the first" {
  # The gate aggregates rather than failing fast, the same way run-all-checks
  # does: one run should surface every offender.
  local -r root="${BATS_TEST_TMPDIR}/several"
  make_shebang_fixture "${root}"
  printf '#!/bin/bash\necho ok\n' > "${root}/run-thing"
  printf '#!/bin/bash\necho ok\n' > "${root}/run-other"
  git -C "${root}" add --all
  run "${CHECK}" "${root}"
  assert_failure
  assert_output --partial 'run-thing'
  assert_output --partial 'run-other'
}

@test "shell shebangs: a surplus argument is rejected, not ignored" {
  # Every positional is optional, so an extra argument can only be a typo -- a
  # misplaced flag, a stray path. Swallowing it silently would run the check
  # anyway and report success on something nobody asked for. Exit 2 rather than
  # 1 keeps the misuse distinct from this script's own failure verdict.
  run "${CHECK}" "${REPO_DIR}" 'extra'
  assert_failure 2
  assert_output --partial 'usage:'
}
