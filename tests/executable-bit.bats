# .ci/check-executable-bit, against the real repo and against fixture
# repositories whose tracked modes a case sets.
#
# setup sets CHECK, the gate under test.

function setup() {
  load 'test_helper/common'
  CHECK="${REPO_DIR}/.ci/check-executable-bit"
}

# Tracked paths the fixture creates, one per EXPECT_EXECUTABLE row. A glob row
# gets one representative file; a literal row gets exactly its path.
readonly -a FIXTURE_EXECUTABLE=(
  '.ci/activate-githooks'
  '.ci/in-devshell'
  '.ci/check-thing'
  '.ci/run-thing'
  '.githooks/pre-commit'
  'run-all-checks'
  'run-tests'
)
# The same, one per EXPECT_NON_EXECUTABLE row.
readonly -a FIXTURE_NON_EXECUTABLE=(
  '.ci/required-tools'
  'tests/thing.bats'
  'tests/test_helper/thing.bash'
  'package.json'
  'README.md'
  'thing.mjs'
  'flake.nix'
  'thing.toml'
  'thing.yml'
)

# @description Build a minimal tracked tree in the shape the gate checks: a git
#              repo holding one file per expected-mode row, each tracked with
#              the mode its row demands. The negative cases below then change
#              a tracked mode, or add or remove a file.
#
#              The mode is set in the index with `git update-index --chmod`
#              rather than on disk, because the gate reads the tracked mode
#              from `git ls-files --stage`, never the working tree. Every file
#              holds an inert marker line: nothing here is ever executed.
# @arg $1 root directory to populate
function make_exec_bit_fixture() {
  local -r root="$1"
  local path
  mkdir --parents "${root}"
  git -C "${root}" init --quiet
  for path in "${FIXTURE_EXECUTABLE[@]}" "${FIXTURE_NON_EXECUTABLE[@]}"; do
    mkdir --parents "${root}/$(dirname -- "${path}")"
    printf 'FIXTURE_FILE\n' > "${root}/${path}"
  done
  git -C "${root}" add --all
  git -C "${root}" update-index --chmod=-x -- "${FIXTURE_NON_EXECUTABLE[@]}"
  git -C "${root}" update-index --chmod=+x -- "${FIXTURE_EXECUTABLE[@]}"
}

# Every case drives FIXTURE mode, which needs nothing but bash and git, so there
# is no devShell skip here, the same as tests/shell-shebangs.bats.
#
# The real-repo case is the exception that keeps the rest honest: it points the gate
# at the real repo, so a fixture that has drifted away from the shape the
# tracked tree actually has cannot hide behind a green suite.

@test "executable bit: the real repo passes" {
  # REPO_DIR explicitly rather than relying on the argument-less default, so the
  # case does not depend on the directory the suite was launched from.
  run "${CHECK}" "${REPO_DIR}"
  assert_success
  assert_output ''
}

@test "executable bit: a valid fixture passes" {
  local -r root="${BATS_TEST_TMPDIR}/ok"
  make_exec_bit_fixture "${root}"
  run "${CHECK}" "${root}"
  assert_success
  assert_output ''
}

@test "executable bit: an expected-executable file tracked 100644 is named" {
  local -r root="${BATS_TEST_TMPDIR}/not-exec"
  make_exec_bit_fixture "${root}"
  git -C "${root}" update-index --chmod=-x -- 'run-tests'
  run "${CHECK}" "${root}"
  assert_failure 1
  assert_output --partial 'FAIL: run-tests must be executable (tracked mode 100644)'
}

@test "executable bit: a glob-matched executable tracked 100644 is named" {
  local -r root="${BATS_TEST_TMPDIR}/glob-not-exec"
  make_exec_bit_fixture "${root}"
  git -C "${root}" update-index --chmod=-x -- '.ci/check-thing'
  run "${CHECK}" "${root}"
  assert_failure 1
  assert_output --partial 'FAIL: .ci/check-thing must be executable'
}

@test "executable bit: a non-executable file tracked 100755 is named" {
  # The gate's core case: a data file is only ever read, and an exec bit on it
  # would suggest otherwise.
  local -r root="${BATS_TEST_TMPDIR}/exec"
  make_exec_bit_fixture "${root}"
  git -C "${root}" update-index --chmod=+x -- '.ci/required-tools'
  run "${CHECK}" "${root}"
  assert_failure 1
  assert_output --partial 'FAIL: .ci/required-tools must NOT be executable (tracked mode 100755)'
}

@test "executable bit: the working-tree mode is ignored, the tracked mode wins" {
  # A chmod that was never staged changes nothing a clone would see.
  local -r root="${BATS_TEST_TMPDIR}/worktree-mode"
  make_exec_bit_fixture "${root}"
  chmod 0755 "${root}/README.md"
  run "${CHECK}" "${root}"
  assert_success
}

@test "executable bit: an untracked file is never graded" {
  local -r root="${BATS_TEST_TMPDIR}/untracked"
  make_exec_bit_fixture "${root}"
  printf 'FIXTURE_FILE\n' > "${root}/NOTES.md"
  chmod 0755 "${root}/NOTES.md"
  run "${CHECK}" "${root}"
  assert_success
}

@test "executable bit: a literal row whose file is no longer tracked is named" {
  # A rename must not drop the file from the check without a word. The file
  # is left on disk, untracked: only the tracked tree counts.
  local -r root="${BATS_TEST_TMPDIR}/vanished-literal"
  make_exec_bit_fixture "${root}"
  git -C "${root}" update-index --force-remove -- 'run-all-checks'
  run "${CHECK}" "${root}"
  assert_failure 1
  assert_output --partial "EXPECT_EXECUTABLE entry 'run-all-checks' matches no tracked file"
}

@test "executable bit: a stale EXPECT_NON_EXECUTABLE row is named too" {
  local -r root="${BATS_TEST_TMPDIR}/vanished-non-exec"
  make_exec_bit_fixture "${root}"
  git -C "${root}" update-index --force-remove -- '.ci/required-tools'
  run "${CHECK}" "${root}"
  assert_failure 1
  assert_output --partial "EXPECT_NON_EXECUTABLE entry '.ci/required-tools' matches no tracked file"
}

@test "executable bit: a glob row that matches no tracked file is named" {
  local -r root="${BATS_TEST_TMPDIR}/vanished-glob"
  make_exec_bit_fixture "${root}"
  git -C "${root}" update-index --force-remove -- '.ci/run-thing'
  run "${CHECK}" "${root}"
  assert_failure 1
  assert_output --partial "EXPECT_EXECUTABLE entry '.ci/run-*' matches no tracked file"
}

@test "executable bit: a repo with no tracked files fails" {
  # An empty scan grades no mode at all, so the gate names that cause outright.
  local -r root="${BATS_TEST_TMPDIR}/empty"
  mkdir --parents "${root}"
  git -C "${root}" init --quiet
  run "${CHECK}" "${root}"
  assert_failure 1
  assert_output --partial 'FAIL: no tracked files found'
}

@test "executable bit: a surplus argument is a usage error, exit 2" {
  run "${CHECK}" "${BATS_TEST_TMPDIR}" 'extra'
  assert_failure 2
  assert_output --partial 'usage: check-executable-bit [dir]'
  refute_output --partial 'ERROR: line'
}
