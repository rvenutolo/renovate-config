# README.md: the sections and literal strings consumers copy from, so a rename
# of an example file or the reusable workflow cannot leave the docs stale.

function setup() {
  load 'test_helper/common'
  README="${REPO_DIR}/README.md"
}

@test "readme: has the required headings" {
  local heading
  for heading in \
    '## What the preset does' \
    '## Adopting it in a repo' \
    '## Overriding settings' \
    '## Prerequisites' \
    '## Releasing'; do
    grep --fixed-strings --line-regexp --quiet -- "${heading}" "${README}"
  done
}

@test "readme: names the preset reference consumers extend" {
  grep --fixed-strings --quiet 'github>rvenutolo/renovate-config#v' "${README}"
}

@test "readme: names both example files" {
  grep --fixed-strings --quiet 'examples/renovate.json5' "${README}"
  grep --fixed-strings --quiet 'examples/renovate-failure-issue.yml' "${README}"
}

@test "readme: explains overriding through packageRules" {
  grep --fixed-strings --quiet 'packageRules' "${README}"
}

@test "readme: names the Actions allowlist entry for the reusable workflow" {
  grep --fixed-strings --quiet \
    'rvenutolo/renovate-config/.github/workflows/renovate-failure-issue.yml@*' "${README}"
}

@test "readme: describes the stuck-PR sweep and its schedule" {
  grep --fixed-strings --quiet 'is stuck' "${README}"
  grep --fixed-strings --quiet '17 14 * * 1' "${README}"
}

@test "readme: describes the Sunday problems check" {
  grep --fixed-strings --quiet 'Renovate reports problems in this repository' "${README}"
  grep --fixed-strings --quiet '47 19 * * 0' "${README}"
}
