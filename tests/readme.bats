# README.md and docs/*.md: the sections and literal strings consumers copy
# from, so a rename of an example file or the reusable workflow cannot leave
# the docs stale.

bats_require_minimum_version 1.5.0

function setup() {
  load 'test_helper/common'
  README="${REPO_DIR}/README.md"
  DOCS="${REPO_DIR}/docs"
}

@test "readme: every docs link resolves" {
  local target count=0
  while IFS= read -r target; do
    [[ -f "${REPO_DIR}/${target}" ]]
    count=$((count + 1))
  done < <(grep --only-matching --extended-regexp '\]\(docs/[^)#]+' "${README}" | sed 's/^](//')
  ((count >= 6))
}

@test "docs: adopting has the walkthrough headings" {
  local heading
  for heading in \
    '## Adopting it in a repo' \
    '## Prerequisites'; do
    grep --fixed-strings --line-regexp --quiet -- "${heading}" "${DOCS}/adopting.md"
  done
}

@test "docs: preset has its heading" {
  grep --fixed-strings --line-regexp --quiet -- '# What the preset does' "${DOCS}/preset.md"
}

@test "docs: overriding has its heading" {
  grep --fixed-strings --line-regexp --quiet -- '# Overriding settings' "${DOCS}/overriding.md"
}

@test "docs: releasing has its heading" {
  grep --fixed-strings --line-regexp --quiet -- '# Releasing' "${DOCS}/releasing.md"
}

@test "docs: adopting names the preset reference consumers extend" {
  grep --fixed-strings --quiet 'github>rvenutolo/renovate-config#v' "${DOCS}/adopting.md"
}

@test "docs: adopting names both example files" {
  grep --fixed-strings --quiet 'examples/renovate.json5' "${DOCS}/adopting.md"
  grep --fixed-strings --quiet 'examples/renovate-failure-issue.yml' "${DOCS}/adopting.md"
}

@test "docs: adopting requires the CI workflow be named ci" {
  grep --fixed-strings --quiet "\`ci\`" "${DOCS}/adopting.md"
}

@test "docs: overriding explains overriding through packageRules" {
  grep --fixed-strings --quiet 'packageRules' "${DOCS}/overriding.md"
}

@test "docs: adopting names the Actions allowlist entry for the reusable workflow" {
  grep --fixed-strings --quiet \
    'rvenutolo/renovate-config/.github/workflows/renovate-failure-issue.yml@*' "${DOCS}/adopting.md"
}

@test "docs: issues describes the stuck-PR sweep and its schedule" {
  grep --fixed-strings --quiet 'is stuck' "${DOCS}/issues.md"
  grep --fixed-strings --quiet '17 14 * * 1' "${DOCS}/issues.md"
}

@test "docs: issues describes the Sunday problems check" {
  grep --fixed-strings --quiet 'Renovate reports problems in this repository' "${DOCS}/issues.md"
  grep --fixed-strings --quiet '47 19 * * 0' "${DOCS}/issues.md"
}

@test "docs: no placeholder wording" {
  run ! grep --ignore-case --quiet --extended-regexp 'v0\.0\.0|placeholder' "${README}" "${DOCS}"/*.md
}
