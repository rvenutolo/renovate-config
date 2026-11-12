# .ci/run-lint-checks' own control flow, against a throwaway repo and stub
# linters: what the gate does with the file lists it builds and the
# directories it looks for, not what any linter says about a file.
#
# `run --separate-stderr` is a bats 1.5.0 flag: the reason for an empty file
# list or a missing directory belongs on stderr, and a merged capture cannot
# tell it apart from a stray stdout write.
#
# setup sets CHECK, the gate under test, FIXTURE, the throwaway repo the gate
# runs in, and STUB_DIR, the directory holding the stub linters.
bats_require_minimum_version 1.5.0

function setup() {
  load 'test_helper/common'
  CHECK="${REPO_DIR}/.ci/run-lint-checks"
  FIXTURE="${BATS_TEST_TMPDIR}/repo"
  STUB_DIR="${BATS_TEST_TMPDIR}/stubs"
  make_lint_fixture
}

# @description Build the throwaway repo these cases run the gate in, and the
#              stub linters it finds on PATH.
#
#              The repo tracks one file of every kind the gate lists except
#              Markdown, which each case adds or withholds: a bash script, a
#              Nix file, the root default.json preset, the example consumer
#              config examples/renovate.json5, and the .github directory with
#              its Renovate config and a workflow. No example workflow: the
#              cases that need one add it.
#
#              Every linter is a stub that exits 0, so a case's verdict comes
#              from the gate's handling of its lists alone, and the suite needs
#              no linter installed.
#
#              A real `git init` rather than a path walk, because the gate reads
#              its file lists from `git ls-files` on purpose. common.bash's
#              fixture-escape hardening is what keeps this `git` from resolving
#              to the author's own checkout.
#
#              Builds at the FIXTURE and STUB_DIR paths setup() chose.
# @noargs
function make_lint_fixture() {
  local -r -a linters=(
    'shellcheck' 'shfmt' 'just' 'statix' 'deadnix' 'actionlint' 'zizmor' 'yamllint'
    'renovate-config-validator' 'markdownlint-cli2' 'typos' 'editorconfig-checker'
  )
  local linter
  mkdir --parents "${FIXTURE}/.github/workflows" "${FIXTURE}/examples" "${STUB_DIR}"
  for linter in "${linters[@]}"; do
    printf '#!/bin/sh\nexit 0\n' > "${STUB_DIR}/${linter}"
    chmod +x "${STUB_DIR}/${linter}"
  done
  printf '#!/usr/bin/env bash\necho ok\n' > "${FIXTURE}/run-thing"
  printf '{ }\n' > "${FIXTURE}/flake.nix"
  printf '{}\n' > "${FIXTURE}/default.json"
  printf '{}\n' > "${FIXTURE}/.github/renovate.json5"
  printf '{}\n' > "${FIXTURE}/examples/renovate.json5"
  printf 'on: push\n' > "${FIXTURE}/.github/workflows/ci.yml"
  git -C "${FIXTURE}" init --quiet
  git -C "${FIXTURE}" add --all
}

# @description Run the gate from inside the fixture, with the stub linters first
#              on PATH. The gate takes no arguments and finds its repo with
#              `git rev-parse --show-toplevel`, so the cd is the fixture
#              selection.
# @noargs
function gate_in_fixture() {
  (cd "${FIXTURE}" && PATH="${STUB_DIR}:${PATH}" "${CHECK}")
}

# Every case needs nothing but bash, git and coreutils -- no Nix -- so there is
# no devShell skip here.
#
# Nothing here grades a linter's verdict on the real repo: run-all-checks runs
# the gate itself, with the real linters, on every gate run.

@test "lint checks: a fixture tracking every listed kind of file passes" {
  # The baseline that keeps the failure cases honest: with a Markdown file
  # tracked, nothing else in the fixture fails the gate.
  printf '# Title\n' > "${FIXTURE}/README.md"
  git -C "${FIXTURE}" add -- 'README.md'
  run --separate-stderr gate_in_fixture
  assert_success
  assert_output ''
}

@test "lint checks: an empty Markdown file list is a failure, not a clean pass" {
  # An empty list means the enumeration broke, not that the repo has no
  # Markdown; a gate that skips the linter and passes has looked at nothing.
  run --separate-stderr gate_in_fixture
  assert_failure 1
  assert_output ''
  [[ "${stderr}" == *'[run-lint-checks] no markdown files found - this is a failure, not a clean pass'* ]]
}

@test "lint checks: a missing .github/workflows directory is a failure, not a clean pass" {
  # The repo's CI is defined in the workflows directory; a gate that finds
  # nothing there has not checked it.
  printf '# Title\n' > "${FIXTURE}/README.md"
  git -C "${FIXTURE}" add -- 'README.md'
  mv --force -- "${FIXTURE}/.github/workflows" "${BATS_TEST_TMPDIR}/workflows"
  run --separate-stderr gate_in_fixture
  assert_failure 1
  assert_output ''
  [[ "${stderr}" == *'[run-lint-checks] no .github/workflows directory found - this is a failure, not a clean pass'* ]]
}

@test "lint checks: a missing .github directory fails actionlint, zizmor and the renovate validator" {
  printf '# Title\n' > "${FIXTURE}/README.md"
  git -C "${FIXTURE}" add -- 'README.md'
  mv --force -- "${FIXTURE}/.github" "${BATS_TEST_TMPDIR}/github"
  run --separate-stderr gate_in_fixture
  assert_failure 1
  assert_output ''
  [[ "${stderr}" == *'[run-lint-checks] no .github/workflows directory found - this is a failure, not a clean pass'* ]]
  [[ "${stderr}" == *'[run-lint-checks] no .github directory found - this is a failure, not a clean pass'* ]]
  [[ "${stderr}" == *'[run-lint-checks] no .github/renovate.json5 found - this is a failure, not a clean pass'* ]]
}

@test "lint checks: a missing default.json is a failure" {
  printf '# Title\n' > "${FIXTURE}/README.md"
  git -C "${FIXTURE}" add -- 'README.md'
  rm -- "${FIXTURE}/default.json"
  run --separate-stderr gate_in_fixture
  assert_failure 1
  [[ "${stderr}" == *'no default.json found - this is a failure, not a clean pass'* ]]
  [[ "${stderr}" != *'no .github directory found'* ]]
  [[ "${stderr}" != *'no .github/workflows directory found'* ]]
}

@test "lint checks: a missing .github/renovate.json5 is a failure" {
  printf '# Title\n' > "${FIXTURE}/README.md"
  git -C "${FIXTURE}" add -- 'README.md'
  rm -- "${FIXTURE}/.github/renovate.json5"
  run --separate-stderr gate_in_fixture
  assert_failure 1
  [[ "${stderr}" == *'no .github/renovate.json5 found - this is a failure, not a clean pass'* ]]
  [[ "${stderr}" != *'no .github directory found'* ]]
  [[ "${stderr}" != *'no .github/workflows directory found'* ]]
}

@test "lint checks: renovate-config-validator runs in strict mode on every listed config" {
  local -r validator_log="${BATS_TEST_TMPDIR}/validator.log"
  printf '# Title\n' > "${FIXTURE}/README.md"
  git -C "${FIXTURE}" add -- 'README.md'
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "${validator_log}" \
    > "${STUB_DIR}/renovate-config-validator"
  run --separate-stderr gate_in_fixture
  assert_success
  run cat "${validator_log}"
  assert_line --partial -- '--no-global --strict'
  assert_line --partial -- 'default.json'
  assert_line --partial -- '.github/renovate.json5'
  assert_line --partial -- 'examples/renovate.json5'
}

@test "lint checks: a missing examples/renovate.json5 is a failure" {
  printf '# Title\n' > "${FIXTURE}/README.md"
  git -C "${FIXTURE}" add -- 'README.md'
  git -C "${FIXTURE}" rm --quiet --force -- 'examples/renovate.json5'
  run --separate-stderr gate_in_fixture
  assert_failure 1
  [[ "${stderr}" == *'no examples/renovate.json5 found - this is a failure, not a clean pass'* ]]
}

@test "lint checks: tracked example workflows reach actionlint and zizmor by file name" {
  # Neither tool discovers examples/ on its own, and zizmor given the bare
  # directory collects nothing and fails, so each file must be named.
  local -r actionlint_log="${BATS_TEST_TMPDIR}/actionlint.log"
  local -r zizmor_log="${BATS_TEST_TMPDIR}/zizmor.log"
  printf '# Title\n' > "${FIXTURE}/README.md"
  printf 'on: push\n' > "${FIXTURE}/examples/caller.yml"
  git -C "${FIXTURE}" add -- 'README.md' 'examples/caller.yml'
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "${actionlint_log}" > "${STUB_DIR}/actionlint"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "${zizmor_log}" > "${STUB_DIR}/zizmor"
  run --separate-stderr gate_in_fixture
  assert_success
  run cat "${actionlint_log}"
  assert_line 'examples/caller.yml'
  run cat "${zizmor_log}"
  assert_line --regexp ' examples/caller\.yml$'
  refute_line --regexp 'examples/?$'
}

@test "lint checks: an examples/ directory with no workflow passes no path to actionlint or zizmor" {
  # An unmatched glob would reach the tool as a literal `examples/*.yml`.
  local -r actionlint_log="${BATS_TEST_TMPDIR}/actionlint.log"
  local -r zizmor_log="${BATS_TEST_TMPDIR}/zizmor.log"
  printf '# Title\n' > "${FIXTURE}/README.md"
  git -C "${FIXTURE}" add -- 'README.md'
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "${actionlint_log}" > "${STUB_DIR}/actionlint"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "${zizmor_log}" > "${STUB_DIR}/zizmor"
  run --separate-stderr gate_in_fixture
  assert_success
  run cat "${actionlint_log}" "${zizmor_log}"
  refute_output --partial 'examples'
}

@test "lint checks: no tracked Nix file is a failure, not a clean pass" {
  printf '# Title\n' > "${FIXTURE}/README.md"
  git -C "${FIXTURE}" add -- 'README.md'
  git -C "${FIXTURE}" rm --quiet --force -- 'flake.nix'
  run --separate-stderr gate_in_fixture
  assert_failure 1
  [[ "${stderr}" == *'[run-lint-checks] no nix files found - this is a failure, not a clean pass'* ]]
}

@test "lint checks: no tracked shell file is a failure, not a clean pass" {
  printf '# Title\n' > "${FIXTURE}/README.md"
  git -C "${FIXTURE}" add -- 'README.md'
  git -C "${FIXTURE}" rm --quiet --force -- 'run-thing'
  run --separate-stderr gate_in_fixture
  assert_failure 1
  [[ "${stderr}" == *'[run-lint-checks] no shell files found'* ]]
}

@test "lint checks: one failing linter fails the gate and the rest still run" {
  # Aggregation: typos fails, yet editorconfig-checker, which runs after it,
  # still gets its turn.
  printf '# Title\n' > "${FIXTURE}/README.md"
  git -C "${FIXTURE}" add -- 'README.md'
  printf '#!/bin/sh\nexit 1\n' > "${STUB_DIR}/typos"
  run --separate-stderr gate_in_fixture
  assert_failure 1
  [[ "${stderr}" == *'[run-lint-checks] running editorconfig-checker'* ]]
  [[ "${stderr}" == *'[run-lint-checks] one or more linters failed'* ]]
}
