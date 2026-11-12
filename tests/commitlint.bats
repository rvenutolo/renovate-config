# commitlint.config.mjs, through the devShell commitlint that the commit-msg
# hook and the CI checks job both run. Each test feeds one commit message
# on stdin and asserts the verdict. `--cwd` pins config discovery to the repo
# root, so the test sees the repo's config no matter where bats runs from.

# `run --separate-stderr` is a bats 1.5.0 flag.
bats_require_minimum_version 1.5.0

function setup() {
  load 'test_helper/common'
}

# @description Run commitlint against the repo config on a message.
# @arg $1 message the full commit message
function lint() {
  run commitlint --cwd "${REPO_DIR}" <<< "$1"
}

@test "accepts an ordinary subject" {
  lint 'feat: add a flag'
  assert_success
}

@test "accepts a scoped subject" {
  lint 'fix(api): handle an empty list'
  assert_success
}

@test "accepts a breaking-change subject" {
  lint 'feat!: drop a flag'
  assert_success
}

@test "accepts a scoped breaking-change subject" {
  lint 'feat(api)!: drop a flag'
  assert_success
}

@test "accepts a revert subject" {
  lint $'revert: feat: add a flag\n\nThis reverts commit 0123456789abcdef0123456789abcdef01234567.'
  assert_success
}

@test "rejects a subject with no type" {
  lint 'drop a flag'
  assert_failure
  assert_output --partial 'type may not be empty'
}

@test "rejects an unknown type" {
  lint 'feature: add a flag'
  assert_failure
  assert_output --partial 'type must be one of'
}

# Without the issuePrefixes override, `#12` opens a footer and
# footer-leading-blank warns; the message still passes. commitlint prints
# its report on stdout, and nothing for a message with no problems and no
# warnings, so any footer rule that fires fails the test. stderr is kept apart
# so a Node or dependency warning there cannot fail it.
@test "does not read a mid-paragraph issue reference as a footer" {
  run --separate-stderr commitlint --cwd "${REPO_DIR}" <<< $'fix: handle an empty list\n\nThe parser mishandled this.\nSee #12 for the report on it.'
  assert_success
  assert_output ''
}

# footer-leading-blank is a warning in config-conventional, so the message
# passes; the test pins that the rule still sees the footer.
@test "warns on a BREAKING CHANGE footer with no blank line above it" {
  lint $'feat: drop a flag\n\nThe flag is gone.\nBREAKING CHANGE: the flag is gone'
  assert_success
  assert_output --partial 'footer must have leading blank line'
}

@test "warns on a BREAKING-CHANGE footer with no blank line above it" {
  lint $'feat: drop a flag\n\nThe flag is gone.\nBREAKING-CHANGE: the flag is gone'
  assert_success
  assert_output --partial 'footer must have leading blank line'
}

# A copy of the config sits under a directory whose node_modules holds a fake
# preset with a header pattern nothing matches. Loading that preset would turn
# every subject into a missing type, so a pass means the config loaded the
# preset the running commitlint bundles.
@test "ignores a preset in a node_modules above the config" {
  local fixture="${BATS_TEST_TMPDIR}/shadow"
  local fake="${fixture}/node_modules/conventional-changelog-conventionalcommits"
  mkdir --parents "${fixture}/repo" "${fake}"
  cp "${REPO_DIR}/commitlint.config.mjs" "${fixture}/repo/"
  printf '{"name":"conventional-changelog-conventionalcommits","main":"index.js"}\n' > "${fake}/package.json"
  printf 'module.exports = { default: () => ({ parser: { headerPattern: /^never$/ } }) };\n' > "${fake}/index.js"

  run commitlint --cwd "${fixture}/repo" <<< 'feat: add a flag'
  assert_success
}
