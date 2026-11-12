# .ci/check-uses-sha-pinned, against throwaway repos whose tracked workflows
# and composite actions carry pinned and unpinned `uses:` lines.
#
# `run --separate-stderr` is a bats 1.5.0 flag: the gate prints every verdict on
# stderr, and a merged capture cannot tell that apart from a stray stdout write.
#
# setup sets CHECK, the gate under test, and FIXTURE, the throwaway repo the
# gate runs in.
bats_require_minimum_version 1.5.0

function setup() {
  load 'test_helper/common'
  CHECK="${REPO_DIR}/.ci/check-uses-sha-pinned"
  FIXTURE="${BATS_TEST_TMPDIR}/repo"
  mkdir --parents "${FIXTURE}"
  git -C "${FIXTURE}" init --quiet
}

readonly PINNED_SHA='0123456789abcdef0123456789abcdef01234567'

# @description Track a file in the fixture repo.
# @arg $1 path path relative to the fixture root
# @arg $2 content the file's content, written verbatim
function track() {
  local -r path="$1"
  local -r content="$2"
  mkdir --parents "${FIXTURE}/$(dirname -- "${path}")"
  printf '%s\n' "${content}" > "${FIXTURE}/${path}"
  git -C "${FIXTURE}" add -- "${path}"
}

# @description Run the gate from inside the fixture. The gate takes no
#              arguments and finds its repo with `git rev-parse
#              --show-toplevel`, so the cd is the fixture selection.
# @noargs
function gate_in_fixture() {
  (cd "${FIXTURE}" && "${CHECK}")
}

# @description Run the gate from inside the real repo, which is where the
#              argument-less gate looks for its tracked files.
# @noargs
function real_repo_gate() {
  (cd "${REPO_DIR}" && "${CHECK}")
}

@test "uses sha pinned: the real repo passes" {
  run --separate-stderr real_repo_gate
  assert_success
}

@test "uses sha pinned: a repo with no tracked workflow passes, loudly" {
  track 'README.md' '# Title'
  run --separate-stderr gate_in_fixture
  assert_success
  [[ "${stderr}" == *'OK: no workflow files tracked yet'* ]]
}

@test "uses sha pinned: a SHA with a version comment passes" {
  track '.github/workflows/ci.yml' "    - uses: actions/checkout@${PINNED_SHA} # v4.2.0"
  run --separate-stderr gate_in_fixture
  assert_success
}

@test "uses sha pinned: a list-item uses and a plain uses both pass when pinned" {
  track '.github/workflows/ci.yml' "      - uses: actions/checkout@${PINNED_SHA} # v4
        uses: actions/setup@${PINNED_SHA}  # v1.2"
  run --separate-stderr gate_in_fixture
  assert_success
}

@test "uses sha pinned: a tag ref is named and rejected" {
  track '.github/workflows/ci.yml' '      - uses: actions/checkout@v4'
  run --separate-stderr gate_in_fixture
  assert_failure 1
  [[ "${stderr}" == *'FAIL: .github/workflows/ci.yml:1 not SHA-pinned with a version comment: actions/checkout@v4'* ]]
}

@test "uses sha pinned: a SHA without a version comment is rejected" {
  track '.github/workflows/ci.yml' "      - uses: actions/checkout@${PINNED_SHA}"
  run --separate-stderr gate_in_fixture
  assert_failure 1
  [[ "${stderr}" == *'not SHA-pinned with a version comment'* ]]
}

@test "uses sha pinned: a truncated SHA is rejected" {
  track '.github/workflows/ci.yml' '      - uses: actions/checkout@0123456 # v4'
  run --separate-stderr gate_in_fixture
  assert_failure 1
  [[ "${stderr}" == *'not SHA-pinned with a version comment'* ]]
}

@test "uses sha pinned: a local action is exempt" {
  track '.github/workflows/ci.yml' "      - uses: ./.github/actions/setup
      - uses: actions/checkout@${PINNED_SHA} # v4"
  run --separate-stderr gate_in_fixture
  assert_success
}

@test "uses sha pinned: a composite action is graded too" {
  track '.github/actions/setup/action.yml' '    - uses: actions/cache@v4'
  track '.github/workflows/ci.yml' "      - uses: actions/checkout@${PINNED_SHA} # v4"
  run --separate-stderr gate_in_fixture
  assert_failure 1
  [[ "${stderr}" == *'FAIL: .github/actions/setup/action.yml:1 not SHA-pinned'* ]]
}

@test "uses sha pinned: an unpinned uses: under examples/ fails" {
  track '.github/workflows/ci.yml' "      - uses: actions/checkout@${PINNED_SHA} # v4"
  track 'examples/caller.yml' '      - uses: actions/checkout@v4'
  run --separate-stderr gate_in_fixture
  assert_failure 1
  [[ "${stderr}" == *'FAIL: examples/caller.yml:1 not SHA-pinned'* ]]
}

@test "uses sha pinned: every offender is named with its line, not just the first" {
  track '.github/workflows/ci.yml' "      - uses: actions/checkout@v4
      - run: echo PAYLOAD_RAN
      - uses: actions/cache@v3"
  run --separate-stderr gate_in_fixture
  assert_failure 1
  [[ "${stderr}" == *'ci.yml:1 not SHA-pinned'* ]]
  [[ "${stderr}" == *'ci.yml:3 not SHA-pinned'* ]]
}

@test "uses sha pinned: workflows holding no external uses is a broken scan, not a pass" {
  track '.github/workflows/ci.yml' 'on: push'
  run --separate-stderr gate_in_fixture
  assert_failure 1
  [[ "${stderr}" == *'contain no external "uses:"'* ]]
}

@test "uses sha pinned: an untracked workflow is never graded" {
  track '.github/workflows/ci.yml' "      - uses: actions/checkout@${PINNED_SHA} # v4"
  mkdir --parents "${FIXTURE}/.github/workflows"
  printf '      - uses: actions/checkout@v4\n' > "${FIXTURE}/.github/workflows/scratch.yml"
  run --separate-stderr gate_in_fixture
  assert_success
}
