# scripts/renovate-failure-issue, against the stub `gh` in
# tests/fixtures/gh-stub: each case writes the canned API responses it needs
# under GH_STUB_DIR, runs the script, and reads back what the script sent from
# the stub's calls.log and saved request bodies.
#
# Every fixture repository is `o/r`, the failing PR is #7 and its existing
# failure issue, when a case has one, is #42.
#
# setup sets SCRIPT, the script under test, and GH_STUB_DIR, and exports the
# env an `open` run needs; the close cases add theirs.

# The jq filters are single-quoted on purpose: their $variables are jq's, not
# the shell's.
# shellcheck disable=SC2016

# Cases export the env the script reads. Each @test runs in its own subshell on
# purpose, so an export never leaks into the next case, which is exactly what
# SC2030/SC2031 warn about.
# shellcheck disable=SC2030,SC2031

bats_require_minimum_version 1.5.0

readonly HOW_TO_FIX='Fix the problem on `main`, then tick the rebase checkbox in the PR; a manual rebase request overrides the schedule. Alternatively, push the fix to the Renovate branch: Renovate stops rebasing a branch with foreign commits, but GitHub auto-merge stays armed, so once CI is green the PR merges by itself as long as it is up to date with `main`.'

function setup() {
  load 'test_helper/common'
  SCRIPT="${REPO_DIR}/scripts/renovate-failure-issue"
  export GH_STUB_DIR="${BATS_TEST_TMPDIR}/gh"
  mkdir --parents "${GH_STUB_DIR}"
  export PATH="${REPO_DIR}/tests/fixtures/gh-stub:${PATH}"
  export GITHUB_REPOSITORY='o/r'
  export RUN_ID='1001'
  export RUN_URL='https://github.com/o/r/actions/runs/1001'
  export HEAD_BRANCH='renovate/foo-1.x'
  export RUN_CONCLUSION='failure'
  unset LOG_TAIL_LINES PR_NUMBER PR_MERGED
}

# @description Write one canned stub response.
# @arg $1 method HTTP method, e.g. GET
# @arg $2 path API path; any `?query` is ignored, as the stub ignores it
# @arg $3 content the response body
# @arg $4 status optional HTTP status; 400 or more makes the call fail
function stub_response() {
  local -r method="$1" path="$2" content="$3" status="${4:-}"
  local mapped="${path%%\?*}"
  mapped="${mapped//\//__}"
  mkdir --parents "${GH_STUB_DIR}/${method}"
  printf '%s\n' "${content}" > "${GH_STUB_DIR}/${method}/${mapped}.json"
  if [[ -n "${status}" ]]; then
    printf '%s\n' "${status}" > "${GH_STUB_DIR}/${method}/${mapped}.status"
  fi
}

# @description Print the Renovate-style PR body the fixtures use: the updates
#              table between the intro line and the `---` rule, release notes
#              after it.
# @stdout the PR body
function renovate_pr_body() {
  printf '%s\n' \
    'This PR contains the following updates:' \
    '' \
    '| Package | Type | Update | Change |' \
    '|---|---|---|---|' \
    '| [foo](https://example.com/foo) | dependencies | minor | `1.0.0` -> `1.1.0` |' \
    '' \
    '---' \
    '' \
    '### Release Notes' \
    '' \
    'RELEASE_NOTES_MARKER'
}

# @description Stub the pulls lookup with PR #7 in the given state.
# @arg $1 state `open` or `closed`
# @arg $2 merged_at optional merge timestamp; without it `merged_at` is null
function stub_pr() {
  local -r state="$1" merged_at="${2:-}"
  local pr
  pr="$(jq --null-input --arg state "${state}" --arg body "$(renovate_pr_body)" \
    --arg merged_at "${merged_at}" \
    '[{number: 7, state: $state, title: "chore(deps): update foo to v1.1.0",
       html_url: "https://github.com/o/r/pull/7", body: $body,
       merged_at: (if $merged_at == "" then null else $merged_at end)}]')"
  stub_response GET 'repos/o/r/pulls' "${pr}"
}

# @description Stub the run's jobs list and one log per job. Each argument is
#              `<id>:<name>:<conclusion>`; each job's log is LOG_LINES lines
#              (default 3) of `<name> log line <n>`.
# @arg $@ jobs the job specs
function stub_jobs() {
  local spec id name conclusion
  local jobs='[]'
  for spec in "$@"; do
    IFS=':' read -r id name conclusion <<< "${spec}"
    jobs="$(jq --argjson id "${id}" --arg name "${name}" --arg c "${conclusion}" \
      '. + [{id: $id, name: $name, conclusion: $c}]' <<< "${jobs}")"
    stub_response GET "repos/o/r/actions/jobs/${id}/logs" \
      "$(seq --format="${name} log line %g" 1 "${LOG_LINES:-3}")"
  done
  stub_response GET "repos/o/r/actions/runs/${RUN_ID}/jobs" \
    "$(jq '{total_count: length, jobs: .}' <<< "${jobs}")"
}

# @description Stub both labels as already existing.
function stub_labels_exist() {
  stub_response GET 'repos/o/r/labels/dependencies' '{"name":"dependencies"}'
  stub_response GET 'repos/o/r/labels/renovate-failure' '{"name":"renovate-failure"}'
}

# @description Stub the open renovate-failure issue list.
# @arg $1 issues JSON array of issues
function stub_issues() {
  stub_response GET 'repos/o/r/issues' "$1"
}

# @description Stub an open failure issue #42 whose marker names the given PR,
#              plus a pull request in the same listing that a naive match would
#              also accept, and a successful PATCH of #42.
# @arg $1 pr the PR number in the marker
# @arg $2 count the failure count in the marker
function stub_existing_issue() {
  local -r pr="$1" count="$2"
  stub_issues "$(jq --null-input --arg pr "${pr}" --arg count "${count}" '[
    {number: 41, pull_request: {url: "x"},
     body: "<!-- renovate-failure pr=7 count=1 -->\nnot an issue"},
    {number: 42,
     body: "<!-- renovate-failure pr=\($pr) count=\($count) -->\nCI failed.\n\nold run https://github.com/o/r/actions/runs/999"}
  ]')"
  stub_response PATCH 'repos/o/r/issues/42' '{"number":42}'
}

# @description Stub the full happy path for a first failure on open PR #7:
#              the PR, two failed jobs, existing labels, no existing issue, and
#              a successful issue create.
function stub_first_failure() {
  stub_pr open
  stub_jobs '11:checks:failure' '12:lint:timed_out'
  stub_labels_exist
  stub_issues '[]'
  stub_response POST 'repos/o/r/issues' '{"number":42}'
}

# @description Print the body of the newest saved request for a method and path.
# @arg $1 method HTTP method
# @arg $2 path API path
# @stdout the request JSON
function request_json() {
  local -r method="$1" path="$2"
  local -a files=("${GH_STUB_DIR}/requests/"*"-${method}-${path//\//__}.json")
  [[ -f "${files[-1]}" ]] || fail "no ${method} ${path} request was sent"
  cat "${files[-1]}"
}

# @description Print the `body` field of the newest request for a method/path.
# @arg $1 method HTTP method
# @arg $2 path API path
# @stdout the issue body
function request_body() {
  request_json "$1" "$2" | jq --raw-output '.body'
}

# @description Count the stub calls with the given method and path, query
#              stripped.
# @arg $1 method HTTP method
# @arg $2 path API path
# @stdout the count
function call_count() {
  local -r method="$1" path="$2"
  local count=0 line
  [[ -f "${GH_STUB_DIR}/calls.log" ]] || {
    printf '0\n'
    return 0
  }
  while IFS= read -r line; do
    if [[ "${line}" == "CALL ${method} ${path}" || "${line}" == "CALL ${method} ${path}?"* ]]; then
      count=$((count + 1))
    fi
  done < "${GH_STUB_DIR}/calls.log"
  printf '%s\n' "${count}"
}

# @description Fail if calls.log records any write to an issues path.
function assert_no_issue_writes() {
  if [[ -f "${GH_STUB_DIR}/calls.log" ]]; then
    run grep --extended-regexp '^CALL (POST|PATCH) repos/o/r/issues' "${GH_STUB_DIR}/calls.log"
    assert_failure
  fi
}

# @description Fail if calls.log records any comment being posted. Reading
#              comments is allowed.
function assert_no_comment_calls() {
  if [[ -f "${GH_STUB_DIR}/calls.log" ]]; then
    run grep '^CALL POST .*comments' "${GH_STUB_DIR}/calls.log"
    assert_failure
  fi
}

@test "open: PR already closed with no failure issue creates no issue" {
  stub_pr closed
  stub_jobs '11:checks:failure'
  stub_labels_exist
  stub_issues '[]'
  run "${SCRIPT}" open
  assert_success
  assert_equal "$(call_count POST repos/o/r/issues)" 0
  assert_no_issue_writes
}

@test "open: PR already merged closes its failure issue as completed without comment" {
  stub_pr closed '2026-11-10T12:00:00Z'
  stub_jobs '11:checks:failure'
  stub_labels_exist
  stub_existing_issue 7 2
  run "${SCRIPT}" open
  assert_success
  assert_equal "$(call_count POST repos/o/r/issues)" 0
  assert_equal "$(call_count PATCH repos/o/r/issues/42)" 1
  request_json PATCH repos/o/r/issues/42 \
    | jq --exit-status '.state == "closed" and .state_reason == "completed"'
  local body
  body="$(request_body PATCH repos/o/r/issues/42)"
  assert_regex "${body}" '\*\*Outcome:\*\* merged'
  assert_equal "$(head --lines=1 <<< "${body}")" '<!-- renovate-failure pr=7 count=2 -->'
  assert_no_comment_calls
}

@test "open: PR closed unmerged closes its failure issue as not_planned" {
  stub_pr closed
  stub_jobs '11:checks:failure'
  stub_labels_exist
  stub_existing_issue 7 1
  run "${SCRIPT}" open
  assert_success
  assert_equal "$(call_count POST repos/o/r/issues)" 0
  request_json PATCH repos/o/r/issues/42 \
    | jq --exit-status '.state == "closed" and .state_reason == "not_planned"'
  assert_regex "$(request_body PATCH repos/o/r/issues/42)" '\*\*Outcome:\*\* closed without merging'
  assert_no_comment_calls
}

@test "open: no PR for branch is a no-op" {
  stub_response GET 'repos/o/r/pulls' '[]'
  stub_jobs '11:checks:failure'
  stub_labels_exist
  stub_issues '[]'
  run "${SCRIPT}" open
  assert_success
  assert_no_issue_writes
  run grep --extended-regexp '^CALL (POST|PATCH|PUT|DELETE) ' "${GH_STUB_DIR}/calls.log"
  assert_failure
}

@test "open: the branch is URL-encoded in the PR lookup" {
  export HEAD_BRANCH='renovate/a&b c'
  stub_response GET 'repos/o/r/pulls' '[]'
  run "${SCRIPT}" open
  assert_success
  run grep --fixed-strings --line-regexp \
    'CALL GET repos/o/r/pulls?head=o:renovate%2Fa%26b%20c&state=all' "${GH_STUB_DIR}/calls.log"
  assert_success
}

@test "open: first failure creates labeled issue with marker" {
  stub_first_failure
  run "${SCRIPT}" open
  assert_success
  assert_equal "$(call_count POST repos/o/r/issues)" 1
  request_json POST repos/o/r/issues \
    | jq --exit-status '.labels == ["dependencies","renovate-failure"]
      and .title == "Renovate PR #7 failed CI: chore(deps): update foo to v1.1.0"'

  local body
  body="$(request_body POST repos/o/r/issues)"
  assert_equal "$(head --lines=1 <<< "${body}")" '<!-- renovate-failure pr=7 count=1 -->'
  assert_regex "${body}" 'https://github\.com/o/r/pull/7'
  assert_regex "${body}" 'https://github\.com/o/r/actions/runs/1001'
  assert_regex "${body}" 'checks'
  assert_regex "${body}" 'lint'
  assert_regex "${body}" '\| \[foo\]\(https://example\.com/foo\) \| dependencies \| minor \|'
  assert_regex "${body}" '\|---\|---\|---\|---\|'
  [[ "${body}" != *RELEASE_NOTES_MARKER* ]] || fail 'release notes leaked past the --- rule'
  assert_regex "${body}" 'How to land a fix'
  [[ "${body}" == *"${HOW_TO_FIX}"* ]] || fail 'fix instructions differ from the spec copy'
}

@test "open: missing labels are created, existing ones tolerated" {
  stub_pr open
  stub_jobs '11:checks:failure'
  stub_issues '[]'
  stub_response POST 'repos/o/r/issues' '{"number":42}'
  # No label GET fixture, so both lookups 404; the create then races a
  # concurrent one and loses.
  stub_response POST 'repos/o/r/labels' \
    '{"message":"Validation Failed","errors":[{"resource":"Label","code":"already_exists","field":"name"}]}' 422
  run "${SCRIPT}" open
  assert_success
  assert_equal "$(call_count POST repos/o/r/labels)" 2
  local names
  names="$(jq --slurp --compact-output '[.[].name] | sort' \
    "${GH_STUB_DIR}/requests/"*-POST-repos__o__r__labels.json)"
  assert_equal "${names}" '["dependencies","renovate-failure"]'
  assert_equal "$(call_count POST repos/o/r/issues)" 1
}

@test "open: existing labels are not re-created" {
  stub_first_failure
  run "${SCRIPT}" open
  assert_success
  assert_equal "$(call_count POST repos/o/r/labels)" 0
}

@test "open: a label lookup failing other than 404 is an API error" {
  stub_first_failure
  stub_response GET 'repos/o/r/labels/dependencies' '{"message":"Server Error"}' 500
  run "${SCRIPT}" open
  assert_failure 1
  assert_equal "$(call_count POST repos/o/r/issues)" 0
}

@test "open: second failure edits body and increments count" {
  export RUN_ID='2002' RUN_URL='https://github.com/o/r/actions/runs/2002'
  stub_pr open
  stub_jobs '11:checks:failure'
  stub_labels_exist
  stub_existing_issue 7 1
  run "${SCRIPT}" open
  assert_success
  assert_equal "$(call_count PATCH repos/o/r/issues/42)" 1
  assert_equal "$(call_count POST repos/o/r/issues)" 0
  local body
  body="$(request_body PATCH repos/o/r/issues/42)"
  assert_equal "$(head --lines=1 <<< "${body}")" '<!-- renovate-failure pr=7 count=2 -->'
  assert_regex "${body}" 'https://github\.com/o/r/actions/runs/2002'
  [[ "${body}" != *'runs/999'* ]] || fail 'the old run link survived the edit'
}

@test "open: never posts a comment" {
  stub_first_failure
  run "${SCRIPT}" open
  assert_success
  assert_no_comment_calls

  # A fresh stub directory, so the second scenario starts with no calls.
  export GH_STUB_DIR="${BATS_TEST_TMPDIR}/gh-repeat"
  mkdir --parents "${GH_STUB_DIR}"
  stub_pr open
  stub_jobs '11:checks:failure'
  stub_labels_exist
  stub_existing_issue 7 3
  run "${SCRIPT}" open
  assert_success
  assert_equal "$(call_count PATCH repos/o/r/issues/42)" 1
  assert_no_comment_calls
}

@test "open: only failed and timed-out jobs are reported" {
  stub_pr open
  stub_jobs '1:job-success:success' '2:job-failure:failure' '3:job-timed-out:timed_out' \
    '4:job-cancelled:cancelled' '5:job-skipped:skipped'
  stub_labels_exist
  stub_issues '[]'
  stub_response POST 'repos/o/r/issues' '{"number":42}'
  run "${SCRIPT}" open
  assert_success
  local body
  body="$(request_body POST repos/o/r/issues)"
  local name
  for name in job-failure job-timed-out; do
    [[ "${body}" == *"${name}"* ]] || fail "${name} missing from the body"
    [[ "${body}" == *"${name} log line 3"* ]] || fail "${name} log tail missing"
  done
  for name in job-success job-cancelled job-skipped; do
    [[ "${body}" != *"${name}"* ]] || fail "${name} reported but did not fail"
  done
}

@test "open: log tail is limited to LOG_TAIL_LINES" {
  stub_pr open
  LOG_LINES=500 stub_jobs '11:checks:failure'
  stub_labels_exist
  stub_issues '[]'
  stub_response POST 'repos/o/r/issues' '{"number":42}'
  export LOG_TAIL_LINES=10
  run "${SCRIPT}" open
  assert_success
  local body n
  body="$(request_body POST repos/o/r/issues)"
  for n in $(seq 491 500); do
    grep --quiet --fixed-strings --line-regexp "checks log line ${n}" <<< "${body}" \
      || fail "log line ${n} missing"
  done
  run grep --fixed-strings --line-regexp 'checks log line 490' <<< "${body}"
  assert_failure
}

@test "open: log tail defaults to 150 lines" {
  stub_pr open
  LOG_LINES=500 stub_jobs '11:checks:failure'
  stub_labels_exist
  stub_issues '[]'
  stub_response POST 'repos/o/r/issues' '{"number":42}'
  run "${SCRIPT}" open
  assert_success
  local body n
  body="$(request_body POST repos/o/r/issues)"
  for n in 351 425 500; do
    grep --quiet --fixed-strings --line-regexp "checks log line ${n}" <<< "${body}" \
      || fail "log line ${n} missing"
  done
  run grep --fixed-strings --line-regexp 'checks log line 350' <<< "${body}"
  assert_failure
}

@test "open: ANSI escape sequences are stripped from log tails" {
  stub_pr open
  stub_jobs '11:checks:failure'
  stub_response GET 'repos/o/r/actions/jobs/11/logs' \
    "$(printf '%s\n' $'\e[31mRED_MARKER\e[0m' $'\e[1;32mBOLD_GREEN_MARKER\e[m' $'\e[2Kcleared\e[?25h')"
  stub_labels_exist
  stub_issues '[]'
  stub_response POST 'repos/o/r/issues' '{"number":42}'
  run "${SCRIPT}" open
  assert_success
  local body
  body="$(request_body POST repos/o/r/issues)"
  grep --quiet --fixed-strings --line-regexp 'RED_MARKER' <<< "${body}" || fail 'RED_MARKER line not clean'
  grep --quiet --fixed-strings --line-regexp 'BOLD_GREEN_MARKER' <<< "${body}" \
    || fail 'BOLD_GREEN_MARKER line not clean'
  grep --quiet --fixed-strings --line-regexp 'cleared' <<< "${body}" || fail 'cleared line not clean'
  [[ "${body}" != *$'\e'* ]] || fail 'an escape character reached the body'
}

@test "open: a log containing a code fence cannot close the block early" {
  stub_pr open
  stub_jobs '11:checks:failure'
  stub_response GET 'repos/o/r/actions/jobs/11/logs' "$(printf '%s\n' 'before' '````' 'FENCE_PAYLOAD')"
  stub_labels_exist
  stub_issues '[]'
  stub_response POST 'repos/o/r/issues' '{"number":42}'
  run "${SCRIPT}" open
  assert_success
  request_body POST repos/o/r/issues > "${BATS_TEST_TMPDIR}/body.md"
  run grep --extended-regexp --line-regexp '`{5,}text' "${BATS_TEST_TMPDIR}/body.md"
  assert_success
}

@test "open: a job whose log cannot be fetched still gets an issue" {
  stub_pr open
  stub_response GET "repos/o/r/actions/runs/${RUN_ID}/jobs" \
    '{"total_count":1,"jobs":[{"id":11,"name":"checks","conclusion":"failure"}]}'
  stub_labels_exist
  stub_issues '[]'
  stub_response POST 'repos/o/r/issues' '{"number":42}'
  run "${SCRIPT}" open
  assert_success
  assert_regex "$(request_body POST repos/o/r/issues)" 'The log could not be fetched'
}

@test "open: run with no jobs renders a startup-failure note" {
  export RUN_CONCLUSION='startup_failure'
  stub_pr open
  stub_jobs
  stub_labels_exist
  stub_issues '[]'
  stub_response POST 'repos/o/r/issues' '{"number":42}'
  run "${SCRIPT}" open
  assert_success
  assert_regex "$(request_body POST repos/o/r/issues)" 'No jobs started'
}

@test "open: body is truncated below the GitHub limit" {
  stub_pr open
  local -a specs=()
  local i
  for i in 1 2 3 4 5; do
    specs+=("${i}:job-${i}:failure")
  done
  stub_jobs "${specs[@]}"
  # 50 lines of ~2 KB each: about 100 KB per job, all inside the default tail.
  local filler
  filler="$(printf 'x%.0s' $(seq 1 2040))"
  for i in 1 2 3 4 5; do
    stub_response GET "repos/o/r/actions/jobs/${i}/logs" \
      "$(seq --format="job-${i} line %g ${filler}" 1 50)"
  done
  stub_labels_exist
  stub_issues '[]'
  stub_response POST 'repos/o/r/issues' '{"number":42}'
  run "${SCRIPT}" open
  assert_success
  request_json POST repos/o/r/issues | jq --exit-status '.body | length <= 65000'
  local body
  body="$(request_body POST repos/o/r/issues)"
  assert_equal "$(head --lines=1 <<< "${body}")" '<!-- renovate-failure pr=7 count=1 -->'
  assert_equal "$(tail --lines=1 <<< "${body}")" "_Log output truncated to fit GitHub's issue size limit._"
  [[ "${body}" == *"${HOW_TO_FIX}"* ]] || fail 'truncation cut the fix instructions'
  for i in 1 2 3 4 5; do
    [[ "${body}" == *"job-${i} line 50 "* ]] || fail "job-${i} lost its last log line"
  done
}

@test "open: a small body carries no truncation note" {
  stub_first_failure
  run "${SCRIPT}" open
  assert_success
  [[ "$(request_body POST repos/o/r/issues)" != *'truncated'* ]] || fail 'spurious truncation note'
}

@test "open: a failing jobs lookup is an API error" {
  stub_pr open
  stub_labels_exist
  stub_issues '[]'
  run "${SCRIPT}" open
  assert_failure 1
  assert_no_issue_writes
}

@test "close: merged PR closes issue as completed without comment" {
  export PR_NUMBER=7 PR_MERGED=true
  stub_existing_issue 7 2
  run "${SCRIPT}" close
  assert_success
  assert_equal "$(call_count PATCH repos/o/r/issues/42)" 1
  request_json PATCH repos/o/r/issues/42 \
    | jq --exit-status '.state == "closed" and .state_reason == "completed"'
  local body
  body="$(request_body PATCH repos/o/r/issues/42)"
  assert_regex "${body}" '\*\*Outcome:\*\* merged'
  assert_equal "$(head --lines=1 <<< "${body}")" '<!-- renovate-failure pr=7 count=2 -->'
  assert_no_comment_calls
}

@test "close: unmerged PR closes issue as not_planned" {
  export PR_NUMBER=7 PR_MERGED=false
  stub_existing_issue 7 1
  run "${SCRIPT}" close
  assert_success
  request_json PATCH repos/o/r/issues/42 \
    | jq --exit-status '.state == "closed" and .state_reason == "not_planned"'
  assert_regex "$(request_body PATCH repos/o/r/issues/42)" '\*\*Outcome:\*\* closed without merging'
  assert_no_comment_calls
}

@test "close: no matching issue is a no-op" {
  export PR_NUMBER=7 PR_MERGED=true
  stub_issues '[]'
  run "${SCRIPT}" close
  assert_success
  assert_equal "$(call_count PATCH repos/o/r/issues/42)" 0
  assert_no_issue_writes
}

@test "close: issue for a different PR is untouched" {
  export PR_NUMBER=7 PR_MERGED=true
  stub_existing_issue 8 1
  run "${SCRIPT}" close
  assert_success
  assert_equal "$(call_count PATCH repos/o/r/issues/42)" 0
  assert_equal "$(call_count PATCH repos/o/r/issues/41)" 0
}

@test "close: a PR number that only prefixes the marker's does not match" {
  export PR_NUMBER=7 PR_MERGED=true
  stub_existing_issue 77 1
  run "${SCRIPT}" close
  assert_success
  assert_equal "$(call_count PATCH repos/o/r/issues/42)" 0
}

@test "close: a marker with an artifact field still matches" {
  export PR_NUMBER=7 PR_MERGED=true
  stub_issues '[{"number":42,"body":"<!-- renovate-failure pr=7 count=1 artifact=0123456789abcdef0123456789abcdef01234567 -->\nx"}]'
  stub_response PATCH 'repos/o/r/issues/42' '{"number":42}'
  run "${SCRIPT}" close
  assert_success
  assert_equal "$(call_count PATCH repos/o/r/issues/42)" 1
}

@test "close: a done issue is left alone" {
  export PR_NUMBER=7 PR_MERGED=true
  stub_issues '[{"number":42,"body":"<!-- renovate-failure pr=7 count=0 artifact=0123456789abcdef0123456789abcdef01234567 done=1 -->\nx"}]'
  run "${SCRIPT}" close
  assert_success
  assert_no_issue_writes
}

@test "open: a stuck issue (count 0) becomes a failure issue with count 1" {
  stub_pr open
  stub_jobs '11:checks:failure'
  stub_labels_exist
  stub_existing_issue 7 0
  run "${SCRIPT}" open
  assert_success
  assert_equal "$(head --lines=1 <<< "$(request_body PATCH repos/o/r/issues/42)")" '<!-- renovate-failure pr=7 count=1 -->'
  request_json PATCH repos/o/r/issues/42 | jq --exit-status '.title | startswith("Renovate PR #7 failed CI: ")'
}

@test "usage: unknown subcommand exits 2" {
  run "${SCRIPT}" reopen
  assert_failure 2
  run "${SCRIPT}"
  assert_failure 2
}

@test "usage: missing required env exits 2 naming the variable" {
  unset RUN_URL
  run --separate-stderr "${SCRIPT}" open
  assert_failure 2
  [[ "${stderr}" == *RUN_URL* ]] || fail "stderr does not name RUN_URL: ${stderr}"

  export PR_MERGED=true
  run --separate-stderr "${SCRIPT}" close
  assert_failure 2
  [[ "${stderr}" == *PR_NUMBER* ]] || fail "stderr does not name PR_NUMBER: ${stderr}"
}

@test "usage: an invalid PR_MERGED exits 2" {
  export PR_NUMBER=7 PR_MERGED=yes
  run --separate-stderr "${SCRIPT}" close
  assert_failure 2
  [[ "${stderr}" == *PR_MERGED* ]] || fail "stderr does not name PR_MERGED: ${stderr}"
}

@test "usage: an invalid RUN_CONCLUSION exits 2" {
  export RUN_CONCLUSION=cancelled
  run --separate-stderr "${SCRIPT}" open
  assert_failure 2
  [[ "${stderr}" == *RUN_CONCLUSION* ]] || fail "stderr does not name RUN_CONCLUSION: ${stderr}"
}
