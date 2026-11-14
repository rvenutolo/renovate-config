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
  unset LOG_TAIL_LINES PR_NUMBER PR_MERGED SWEEP_MIN_AGE_HOURS SWEEP_MERGEABLE_TRIES SWEEP_RETRY_DELAY PROBLEMS_NOW
  FIXTURES="${REPO_DIR}/tests/fixtures/dashboards"
  # The mergeable-state retries would otherwise sleep between tries.
  export SWEEP_RETRY_DELAY=0
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

# The head commit of every sweep fixture PR.
readonly HEAD_SHA='0123456789abcdef0123456789abcdef01234567'

# @description Print a UTC timestamp the given number of hours ago.
# @arg $1 hours how many hours back
# @stdout the ISO 8601 timestamp
function iso_hours_ago() {
  date --utc --date="-$1 hours" '+%Y-%m-%dT%H:%M:%SZ'
}

# @description Print one open PR as the pulls list returns it: a stuck
#              Renovate PR unless the overrides say otherwise.
# @arg $1 number the PR number
# @arg $2 overrides optional jq filter applied to the PR, e.g. `.draft = true`
# @stdout the PR as compact JSON
function sweep_pr() {
  local -r number="$1" overrides="${2:-.}"
  jq --null-input --compact-output --argjson number "${number}" \
    --arg body "$(renovate_pr_body)" --arg created "$(iso_hours_ago 13)" --arg sha "${HEAD_SHA}" \
    "{number: \$number, state: \"open\", draft: false, title: \"chore(deps): update foo to v1.1.0\",
      html_url: \"https://github.com/o/r/pull/\\(\$number)\", body: \$body, created_at: \$created,
      auto_merge: {merge_method: \"squash\"}, user: {login: \"renovate[bot]\"},
      head: {ref: \"renovate/foo-1.x\", sha: \$sha, repo: {full_name: \"o/r\"}}} | ${overrides}"
}

# @description Stub the open-PR listing.
# @arg $1 prs JSON array of PRs
function stub_open_prs() {
  stub_response GET 'repos/o/r/pulls' "$1"
}

# @description Stub the per-PR lookups a sweep makes for one PR: the single-PR
#              GET (clean mergeable state), the head's combined status and
#              check runs (passing), and no comments.
# @arg $1 number the PR number
function stub_sweep_details() {
  local -r number="$1"
  stub_response GET "repos/o/r/pulls/${number}" \
    "$(jq --null-input --argjson n "${number}" '{number: $n, state: "open", mergeable_state: "clean"}')"
  stub_response GET "repos/o/r/commits/${HEAD_SHA}/status" '{"state":"success","total_count":1}'
  stub_response GET "repos/o/r/commits/${HEAD_SHA}/check-runs" \
    '{"total_count":1,"check_runs":[{"status":"completed","conclusion":"success"}]}'
  stub_response GET "repos/o/r/issues/${number}/comments" '[]'
}

# @description Stub a sweep over one PR #7 built by sweep_pr with the given
#              overrides, existing labels, no existing issue and a successful
#              issue create.
# @arg $1 overrides optional jq filter for the PR
function stub_sweep() {
  stub_open_prs "[$(sweep_pr 7 "${1:-.}")]"
  stub_sweep_details 7
  stub_labels_exist
  stub_issues '[]'
  stub_response POST 'repos/o/r/issues' '{"number":42}'
}

# @description Print an open issue as the issues list returns it, with a
#              marker line naming a PR.
# @arg $1 number the issue number
# @arg $2 marker_fields the marker fields after `renovate-failure`, e.g.
#         `pr=7 count=0`
# @stdout the issue as compact JSON
function marker_issue() {
  jq --null-input --compact-output --argjson n "$1" --arg fields "$2" \
    '{number: $n, body: "<!-- renovate-failure \($fields) -->\nold body"}'
}

# @description Stub the single-PR GET for a closed PR #7.
# @arg $1 merged_at the merge timestamp, or empty for closed unmerged
function stub_closed_pr7() {
  stub_response GET 'repos/o/r/pulls/7' "$(jq --null-input --arg m "$1" \
    '{number: 7, state: "closed", merged_at: (if $m == "" then null else $m end)}')"
}

# A Sunday afternoon inside the lock-file maintenance window, New York time.
readonly IN_WINDOW='2026-11-15T21:47:00Z'

# @description Print the Dependency Dashboard issue #3 as the issues list
#              returns it.
# @arg $1 body_file the Dashboard body
# @arg $2 overrides optional jq filter applied to the issue
# @stdout the issue as compact JSON
function dashboard_issue() {
  jq --null-input --compact-output --rawfile body "$1" \
    "{number: 3, state: \"open\", title: \"Dependency Dashboard\", user: {login: \"renovate[bot]\"},
      html_url: \"https://github.com/o/r/issues/3\", body: \$body} | ${2:-.}"
}

# @description Stub the issues listing with the given issues.
# @arg $@ issues each issue as compact JSON
function stub_issue_list() {
  stub_issues "$(printf '%s\n' "$@" | jq --slurp --compact-output '.')"
}

# @description Stub a problems run over a Dashboard body: the Dashboard as the
#              only issue, existing labels and a successful create.
# @arg $1 body_file the Dashboard body
# @arg $2 overrides optional jq filter applied to the Dashboard issue
function stub_problems() {
  stub_issue_list "$(dashboard_issue "$1" "${2:-.}")"
  stub_labels_exist
  stub_response POST 'repos/o/r/issues' '{"number":50}'
}

# @description Print a problems issue as the issues list returns it.
# @arg $1 number the issue number
# @arg $2 state `open` or `closed`
# @arg $3 body the issue body, marker line first
# @arg $4 closed_at optional close timestamp
# @stdout the issue as compact JSON
function problems_issue() {
  jq --null-input --compact-output --argjson n "$1" --arg state "$2" --arg body "$3" --arg closed "${4:-}" \
    '{number: $n, state: $state, title: "Renovate reports problems in this repository",
      user: {login: "github-actions[bot]"}, body: $body,
      closed_at: (if $closed == "" then null else $closed end)}'
}

# @description Print the body a first, issue-less in-window problems run
#              files for a Dashboard, using a throwaway stub directory.
# @arg $1 body_file the Dashboard body
# @stdout the filed issue body
function first_render() {
  local -r saved="${GH_STUB_DIR}"
  GH_STUB_DIR="${BATS_TEST_TMPDIR}/first-render"
  mkdir --parents "${GH_STUB_DIR}"
  stub_problems "$1"
  PROBLEMS_NOW="${IN_WINDOW}" "${SCRIPT}" problems > /dev/null 2>&1
  request_body POST repos/o/r/issues
  GH_STUB_DIR="${saved}"
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

@test "sweep: no open PRs and no issues writes nothing" {
  stub_open_prs '[]'
  stub_issues '[]'
  run "${SCRIPT}" sweep
  assert_success
  assert_no_issue_writes
}

@test "sweep: a stuck PR gets a labeled issue with count 0" {
  stub_sweep
  run "${SCRIPT}" sweep
  assert_success
  assert_equal "$(call_count POST repos/o/r/issues)" 1
  request_json POST repos/o/r/issues \
    | jq --exit-status '.labels == ["dependencies","renovate-failure"]
      and .title == "Renovate PR #7 is stuck: chore(deps): update foo to v1.1.0"'
  local body
  body="$(request_body POST repos/o/r/issues)"
  assert_equal "$(head --lines=1 <<< "${body}")" '<!-- renovate-failure pr=7 count=0 -->'
  assert_regex "${body}" 'https://github\.com/o/r/pull/7'
  assert_regex "${body}" '\| \[foo\]\(https://example\.com/foo\) \| dependencies \| minor \|'
  [[ "${body}" != *RELEASE_NOTES_MARKER* ]] || fail 'release notes leaked past the --- rule'
  assert_regex "${body}" '## How to unstick it'
}

@test "sweep: a repeat sweep edits the stuck issue silently" {
  stub_sweep
  stub_existing_issue 7 0
  run "${SCRIPT}" sweep
  assert_success
  assert_equal "$(call_count PATCH repos/o/r/issues/42)" 1
  assert_equal "$(call_count POST repos/o/r/issues)" 0
  assert_no_comment_calls
  assert_equal "$(head --lines=1 <<< "$(request_body PATCH repos/o/r/issues/42)")" '<!-- renovate-failure pr=7 count=0 -->'
}

@test "sweep: a PR with a failure issue is skipped" {
  stub_sweep
  stub_existing_issue 7 2
  run "${SCRIPT}" sweep
  assert_success
  assert_no_issue_writes
}

@test "sweep: a PR with auto-merge off is not stuck" {
  stub_sweep '.auto_merge = null'
  run "${SCRIPT}" sweep
  assert_success
  assert_no_issue_writes
}

@test "sweep: a draft PR is not stuck" {
  stub_sweep '.draft = true'
  run "${SCRIPT}" sweep
  assert_success
  assert_no_issue_writes
}

@test "sweep: a PR younger than the minimum age is not stuck" {
  stub_sweep ".created_at = \"$(iso_hours_ago 1)\""
  run "${SCRIPT}" sweep
  assert_success
  assert_no_issue_writes
}

@test "sweep: SWEEP_MIN_AGE_HOURS sets the minimum age" {
  export SWEEP_MIN_AGE_HOURS=2
  stub_sweep ".created_at = \"$(iso_hours_ago 3)\""
  run "${SCRIPT}" sweep
  assert_success
  assert_equal "$(call_count POST repos/o/r/issues)" 1
}

@test "sweep: a non-renovate branch is not stuck" {
  stub_sweep '.head.ref = "feature/x"'
  run "${SCRIPT}" sweep
  assert_success
  assert_no_issue_writes
}

@test "sweep: a fork PR is not stuck" {
  stub_sweep '.head.repo.full_name = "evil/r"'
  run "${SCRIPT}" sweep
  assert_success
  assert_no_issue_writes
}

@test "sweep: a PR whose head repo is gone is skipped" {
  stub_sweep '.head.repo = null'
  run "${SCRIPT}" sweep
  assert_success
  assert_no_issue_writes
}

@test "sweep: listings are paginated" {
  stub_sweep
  run "${SCRIPT}" sweep
  assert_success
  run grep --after-context=1 --extended-regexp '^CALL GET repos/o/r/(pulls|issues)\?' "${GH_STUB_DIR}/calls.log"
  assert_line --regexp '^ARGV:.* --paginate .*repos/o/r/pulls\?'
  assert_line --regexp '^ARGV:.* --paginate .*repos/o/r/issues\?'
}

@test "sweep: a long PR title is truncated to 256 characters" {
  stub_sweep '.title = ("x" * 300)'
  run "${SCRIPT}" sweep
  assert_success
  request_json POST repos/o/r/issues | jq --exit-status '(.title | length) == 256 and (.title | endswith("…"))'
}

@test "sweep: never posts a comment" {
  stub_sweep
  run "${SCRIPT}" sweep
  assert_success
  assert_no_comment_calls
}

@test "usage: an invalid SWEEP_MIN_AGE_HOURS exits 2" {
  export SWEEP_MIN_AGE_HOURS=abc
  run "${SCRIPT}" sweep
  assert_failure 2
}

@test "sweep: body reports passing CI" {
  stub_sweep
  run "${SCRIPT}" sweep
  assert_success
  local body
  body="$(request_body POST repos/o/r/issues)"
  assert_regex "${body}" '## Current state'
  [[ "${body}" == *'**CI on the head commit:** passing'* ]] || fail "${body}"
  [[ "${body}" == *'**Auto-merge:** enabled'* ]] || fail "${body}"
}

@test "sweep: body reports failing CI from a check run" {
  stub_sweep
  stub_response GET "repos/o/r/commits/${HEAD_SHA}/check-runs" \
    '{"total_count":1,"check_runs":[{"status":"completed","conclusion":"timed_out"}]}'
  run "${SCRIPT}" sweep
  assert_success
  [[ "$(request_body POST repos/o/r/issues)" == *'**CI on the head commit:** failing'* ]] || fail 'expected line missing from the issue body'
}

@test "sweep: body reports failing CI from a commit status" {
  stub_sweep
  stub_response GET "repos/o/r/commits/${HEAD_SHA}/status" '{"state":"error","total_count":1}'
  run "${SCRIPT}" sweep
  assert_success
  [[ "$(request_body POST repos/o/r/issues)" == *'**CI on the head commit:** failing'* ]] || fail 'expected line missing from the issue body'
}

@test "sweep: body reports pending CI" {
  stub_sweep
  stub_response GET "repos/o/r/commits/${HEAD_SHA}/check-runs" \
    '{"total_count":1,"check_runs":[{"status":"in_progress","conclusion":null}]}'
  run "${SCRIPT}" sweep
  assert_success
  [[ "$(request_body POST repos/o/r/issues)" == *'**CI on the head commit:** pending'* ]] || fail 'expected line missing from the issue body'
}

@test "sweep: body reports no CI" {
  stub_sweep
  stub_response GET "repos/o/r/commits/${HEAD_SHA}/status" '{"state":"pending","total_count":0}'
  stub_response GET "repos/o/r/commits/${HEAD_SHA}/check-runs" '{"total_count":0,"check_runs":[]}'
  run "${SCRIPT}" sweep
  assert_success
  [[ "$(request_body POST repos/o/r/issues)" == *'**CI on the head commit:** none'* ]] || fail 'expected line missing from the issue body'
}

@test "sweep: body reports the mergeable state" {
  stub_sweep
  stub_response GET 'repos/o/r/pulls/7' '{"number":7,"state":"open","mergeable_state":"behind"}'
  run "${SCRIPT}" sweep
  assert_success
  [[ "$(request_body POST repos/o/r/issues)" == *'**Mergeable state:** `behind`'* ]] || fail 'expected line missing from the issue body'
}

@test "sweep: a mergeable state that stays unknown is reported as unknown" {
  stub_sweep
  stub_response GET 'repos/o/r/pulls/7' '{"number":7,"state":"open","mergeable_state":null}'
  run "${SCRIPT}" sweep
  assert_success
  assert_equal "$(call_count POST repos/o/r/issues)" 1
  assert_equal "$(call_count GET repos/o/r/pulls/7)" 3
  [[ "$(request_body POST repos/o/r/issues)" == *'**Mergeable state:** `unknown`'* ]] || fail 'expected line missing from the issue body'
}

@test "sweep: a Renovate artifact comment is reported" {
  stub_sweep
  stub_response GET 'repos/o/r/issues/7/comments' \
    "$(jq --null-input '[{user: {login: "renovate[bot]"}, body: "### ⚠️ Artifact update problem\n\nRenovate failed to update an artifact"}]')"
  run "${SCRIPT}" sweep
  assert_success
  [[ "$(request_body POST repos/o/r/issues)" == *'**Artifact update problem reported by Renovate:** yes'* ]] || fail 'expected line missing from the issue body'
}

@test "sweep: a look-alike artifact comment from another user is ignored" {
  stub_sweep
  stub_response GET 'repos/o/r/issues/7/comments' \
    "$(jq --null-input '[{user: {login: "mallory"}, body: "### ⚠️ Artifact update problem\n\nfake"}]')"
  run "${SCRIPT}" sweep
  assert_success
  [[ "$(request_body POST repos/o/r/issues)" == *'**Artifact update problem reported by Renovate:** no'* ]] || fail 'expected line missing from the issue body'
}

@test "sweep: comments are read with pagination" {
  stub_sweep
  run "${SCRIPT}" sweep
  assert_success
  run grep --after-context=1 '^CALL GET repos/o/r/issues/7/comments' "${GH_STUB_DIR}/calls.log"
  assert_line --regexp '^ARGV:.* --paginate '
}

@test "sweep: an issue whose PR merged is closed as completed" {
  stub_open_prs '[]'
  stub_issues "[$(marker_issue 42 'pr=7 count=2')]"
  stub_closed_pr7 '2026-11-09T12:00:00Z'
  stub_response PATCH 'repos/o/r/issues/42' '{"number":42}'
  run "${SCRIPT}" sweep
  assert_success
  request_json PATCH repos/o/r/issues/42 \
    | jq --exit-status '.state == "closed" and .state_reason == "completed"'
  assert_regex "$(request_body PATCH repos/o/r/issues/42)" '\*\*Outcome:\*\* merged'
  assert_no_comment_calls
}

@test "sweep: an issue whose PR closed unmerged is closed as not_planned" {
  stub_open_prs '[]'
  stub_issues "[$(marker_issue 42 'pr=7 count=0')]"
  stub_closed_pr7 ''
  stub_response PATCH 'repos/o/r/issues/42' '{"number":42}'
  run "${SCRIPT}" sweep
  assert_success
  request_json PATCH repos/o/r/issues/42 \
    | jq --exit-status '.state == "closed" and .state_reason == "not_planned"'
  assert_regex "$(request_body PATCH repos/o/r/issues/42)" '\*\*Outcome:\*\* closed without merging'
}

@test "sweep: a stuck issue whose PR lost auto-merge is closed as not_planned" {
  stub_sweep '.auto_merge = null'
  stub_issues "[$(marker_issue 42 'pr=7 count=0')]"
  stub_response PATCH 'repos/o/r/issues/42' '{"number":42}'
  run "${SCRIPT}" sweep
  assert_success
  assert_equal "$(call_count PATCH repos/o/r/issues/42)" 1
  request_json PATCH repos/o/r/issues/42 \
    | jq --exit-status '.state == "closed" and .state_reason == "not_planned"'
  assert_regex "$(request_body PATCH repos/o/r/issues/42)" '\*\*Outcome:\*\* no longer stuck'
}

@test "sweep: a failure issue on a non-stuck open PR is untouched" {
  stub_sweep '.auto_merge = null'
  stub_issues "[$(marker_issue 42 'pr=7 count=1')]"
  run "${SCRIPT}" sweep
  assert_success
  assert_no_issue_writes
}

@test "sweep: every duplicate issue for a closed PR is closed" {
  stub_open_prs '[]'
  stub_issues "[$(marker_issue 42 'pr=7 count=0'), $(marker_issue 43 'pr=7 count=0')]"
  stub_closed_pr7 ''
  stub_response PATCH 'repos/o/r/issues/42' '{"number":42}'
  stub_response PATCH 'repos/o/r/issues/43' '{"number":43}'
  run "${SCRIPT}" sweep
  assert_success
  assert_equal "$(call_count PATCH repos/o/r/issues/42)" 1
  assert_equal "$(call_count PATCH repos/o/r/issues/43)" 1
}

@test "sweep: a duplicate pair on a stuck PR updates only the oldest" {
  stub_sweep
  stub_issues "[$(marker_issue 43 'pr=7 count=0'), $(marker_issue 42 'pr=7 count=0')]"
  stub_response PATCH 'repos/o/r/issues/42' '{"number":42}'
  stub_response PATCH 'repos/o/r/issues/43' '{"number":43}'
  run "${SCRIPT}" sweep
  assert_success
  assert_equal "$(call_count PATCH repos/o/r/issues/42)" 1
  assert_equal "$(call_count PATCH repos/o/r/issues/43)" 0
}

@test "sweep: a done issue is never touched" {
  stub_open_prs '[]'
  stub_issues "[$(marker_issue 42 "pr=7 count=0 artifact=${HEAD_SHA} done=1")]"
  stub_closed_pr7 '2026-11-09T12:00:00Z'
  run "${SCRIPT}" sweep
  assert_success
  assert_no_issue_writes
}

@test "sweep: a failing comments lookup is an API error" {
  stub_sweep
  stub_response GET 'repos/o/r/issues/7/comments' '{"message":"Server Error"}' 500
  run "${SCRIPT}" sweep
  assert_failure 1
  assert_equal "$(call_count POST repos/o/r/issues)" 0
}

@test "sweep: an issue whose PR cannot be found does not stop the backstop" {
  stub_open_prs '[]'
  stub_issues "[$(marker_issue 41 'pr=999 count=0'), $(marker_issue 42 'pr=7 count=1')]"
  stub_closed_pr7 '2026-11-09T12:00:00Z'
  stub_response PATCH 'repos/o/r/issues/42' '{"number":42}'
  run "${SCRIPT}" sweep
  assert_success
  assert_equal "$(call_count PATCH repos/o/r/issues/42)" 1
  assert_equal "$(call_count PATCH repos/o/r/issues/41)" 0
}

@test "sweep: a PR lookup failing other than 404 is an API error" {
  stub_open_prs '[]'
  stub_issues "[$(marker_issue 42 'pr=7 count=1')]"
  stub_response GET 'repos/o/r/pulls/7' '{"message":"Server Error"}' 500
  run "${SCRIPT}" sweep
  assert_failure 1
  assert_equal "$(call_count PATCH repos/o/r/issues/42)" 0
}

@test "problems: hosted Dashboard problems file a labeled issue" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  stub_problems "${FIXTURES}/hosted-problems.txt"
  run "${SCRIPT}" problems
  assert_success
  assert_equal "$(call_count POST repos/o/r/issues)" 1
  request_json POST repos/o/r/issues \
    | jq --exit-status '.labels == ["dependencies","renovate-failure"]
      and .title == "Renovate reports problems in this repository"'
  local body
  body="$(request_body POST repos/o/r/issues)"
  assert_regex "$(head --lines=1 <<< "${body}")" '^<!-- renovate-problems set=[0-9a-f]{16} -->$'
  [[ "${body}" == *'⚠️ WARN: Error updating flake.lock'* ]] || fail 'flake.lock problem missing'
  [[ "${body}" == *'⚠️ WARN: Package lookup failures'* ]] || fail 'lookup problem missing'
  [[ "${body}" == *'Renovate failed to look up the following dependencies'* ]] || fail 'lookup block missing'
  [[ "${body}" == *'**Dependency Dashboard:** https://github.com/o/r/issues/3'* ]] || fail 'dashboard link missing'
  [[ "${body}" == *'**Renovate logs:** https://developer.mend.io/'* ]] || fail 'mend link missing'
  [[ "${body}" != *'lock file maintenance'* ]] || fail 'an uncounted section leaked in'
}

@test "problems: main-rendered Dashboard problems are found too" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  stub_problems "${FIXTURES}/main-problems.txt"
  run "${SCRIPT}" problems
  assert_success
  local body
  body="$(request_body POST repos/o/r/issues)"
  [[ "${body}" == *'⚠️ WARN: Error updating flake.lock'* ]] || fail 'problem line missing'
  [[ "${body}" == *'⚠️ **Warning**'* ]] || fail 'warning block missing'
  [[ "${body}" == *'`example-dep`'* ]] || fail 'warning detail missing'
  [[ "${body}" == *'chore(deps): update foo to v1.1.0'* ]] || fail 'errored branch missing'
  [[ "${body}" != *'retry-branch'* ]] || fail 'checkbox comment not stripped'
  [[ "${body}" != *'tried to run on this repository'* ]] || fail 'section header captured'
  [[ "${body}" != *'encountered an error and will be retried'* ]] || fail 'errored description captured'
}

@test "problems: a clean Dashboard files nothing" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  stub_problems "${FIXTURES}/clean.txt"
  run "${SCRIPT}" problems
  assert_success
  assert_no_issue_writes
}

@test "problems: uncounted sections are ignored" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  stub_problems "${FIXTURES}/uncounted.txt"
  run "${SCRIPT}" problems
  assert_success
  assert_no_issue_writes
}

@test "problems: an issue titled Dependency Dashboard by someone else is ignored" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  stub_problems "${FIXTURES}/hosted-problems.txt" '.user.login = "mallory"'
  run "${SCRIPT}" problems
  assert_success
  assert_no_issue_writes
}

@test "problems: a Renovate issue with another title is ignored" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  stub_problems "${FIXTURES}/hosted-problems.txt" '.title = "Other"'
  run "${SCRIPT}" problems
  assert_success
  assert_no_issue_writes
}

@test "problems: Dashboard text cannot break out of the fence or mention anyone" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  printf '%s\n' '## Repository Problems' '' 'header' '' ' - ⚠️ WARN: bad ``` fence @someone' \
    > "${BATS_TEST_TMPDIR}/dashboard.md"
  stub_problems "${BATS_TEST_TMPDIR}/dashboard.md"
  run "${SCRIPT}" problems
  assert_success
  local body outside
  body="$(request_body POST repos/o/r/issues)"
  assert_regex "${body}" $'\n````+text\n'
  # Drop everything between the opening fence line and its matching close.
  outside="$(awk '
    !inside && /^````+text$/ { inside = 1; fence = substr($0, 1, length($0) - 4); next }
    inside && $0 == fence { inside = 0; next }
    !inside { print }' <<< "${body}")"
  [[ "${outside}" != *'@someone'* ]] || fail 'a mention escaped the fenced block'
}

@test "problems: a Mend link on another host is dropped" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  sed 's#https://developer.mend.io//github/o/r#https://evil.example/x#; s#https://developer.mend.io/github/o/r#https://evil.example/y#' \
    "${FIXTURES}/hosted-problems.txt" > "${BATS_TEST_TMPDIR}/dashboard.md"
  stub_problems "${BATS_TEST_TMPDIR}/dashboard.md"
  run "${SCRIPT}" problems
  assert_success
  [[ "$(request_body POST repos/o/r/issues)" != *'Renovate logs'* ]] || fail 'an off-host log link was kept'
}

@test "problems: the problem list is truncated to fit the body limit" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  {
    printf '%s\n' '## Repository Problems' '' 'header' ''
    printf ' - %s\n' "$(head --bytes=70000 /dev/zero | tr '\0' 'x')"
  } \
    > "${BATS_TEST_TMPDIR}/dashboard.md"
  stub_problems "${BATS_TEST_TMPDIR}/dashboard.md"
  run "${SCRIPT}" problems
  assert_success
  local body
  body="$(request_body POST repos/o/r/issues)"
  ((${#body} < 65536)) || fail "body is ${#body} characters"
  [[ "${body}" == *"_Problem list truncated to fit GitHub's issue size limit._"* ]] || fail 'truncation note missing'
}

@test "problems: never posts a comment" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  stub_problems "${FIXTURES}/hosted-problems.txt"
  run "${SCRIPT}" problems
  assert_success
  assert_no_comment_calls
}

@test "usage: an invalid PROBLEMS_NOW exits 2" {
  export PROBLEMS_NOW=yesterday
  run "${SCRIPT}" problems
  assert_failure 2
}

@test "problems: unchanged problems do not edit the open issue" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  local body
  body="$(first_render "${FIXTURES}/hosted-problems.txt")"
  stub_problems "${FIXTURES}/hosted-problems.txt"
  stub_issue_list "$(dashboard_issue "${FIXTURES}/hosted-problems.txt")" "$(problems_issue 40 open "${body}")"
  run "${SCRIPT}" problems
  assert_success
  assert_no_issue_writes
}

@test "problems: line-ending and trailing-space noise does not change the fingerprint" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  local body
  body="$(first_render "${FIXTURES}/hosted-problems.txt")"
  sed 's/$/  \r/' "${FIXTURES}/hosted-problems.txt" > "${BATS_TEST_TMPDIR}/noisy.txt"
  stub_problems "${BATS_TEST_TMPDIR}/noisy.txt"
  stub_issue_list "$(dashboard_issue "${BATS_TEST_TMPDIR}/noisy.txt")" "$(problems_issue 40 open "${body}")"
  run "${SCRIPT}" problems
  assert_success
  assert_no_issue_writes
}

@test "problems: changed problems edit the open issue once" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  stub_problems "${FIXTURES}/hosted-problems.txt"
  stub_issue_list "$(dashboard_issue "${FIXTURES}/hosted-problems.txt")" \
    "$(problems_issue 40 open $'<!-- renovate-problems set=0000000000000000 -->\nold')"
  stub_response PATCH 'repos/o/r/issues/40' '{"number":40}'
  run "${SCRIPT}" problems
  assert_success
  assert_equal "$(call_count PATCH repos/o/r/issues/40)" 1
  assert_equal "$(call_count POST repos/o/r/issues)" 0
  local body
  body="$(request_body PATCH repos/o/r/issues/40)"
  assert_regex "$(head --lines=1 <<< "${body}")" '^<!-- renovate-problems set=[0-9a-f]{16} -->$'
  [[ "$(head --lines=1 <<< "${body}")" != *0000000000000000* ]] || fail 'fingerprint not updated'
  assert_no_comment_calls
}

@test "problems: duplicate open issues keep the oldest and close the rest" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  stub_problems "${FIXTURES}/hosted-problems.txt"
  stub_issue_list "$(dashboard_issue "${FIXTURES}/hosted-problems.txt")" \
    "$(problems_issue 41 open $'<!-- renovate-problems set=0000000000000000 -->\nold')" \
    "$(problems_issue 40 open $'<!-- renovate-problems set=0000000000000000 -->\nold')"
  stub_response PATCH 'repos/o/r/issues/40' '{"number":40}'
  stub_response PATCH 'repos/o/r/issues/41' '{"number":41}'
  run "${SCRIPT}" problems
  assert_success
  request_json PATCH repos/o/r/issues/40 | jq --exit-status '.state == null'
  request_json PATCH repos/o/r/issues/41 | jq --exit-status '.state == "closed" and .state_reason == "not_planned"'
  assert_regex "$(request_body PATCH repos/o/r/issues/41)" '\*\*Outcome:\*\* duplicate'
  assert_regex "$(head --lines=1 <<< "$(request_body PATCH repos/o/r/issues/41)")" ' resolved=1 -->$'
}

@test "problems: cleared problems close the issue as completed and mark it resolved" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  stub_problems "${FIXTURES}/clean.txt"
  stub_issue_list "$(dashboard_issue "${FIXTURES}/clean.txt")" \
    "$(problems_issue 40 open $'<!-- renovate-problems set=0123456789abcdef -->\nold')"
  stub_response PATCH 'repos/o/r/issues/40' '{"number":40}'
  run "${SCRIPT}" problems
  assert_success
  assert_equal "$(call_count PATCH repos/o/r/issues/40)" 1
  request_json PATCH repos/o/r/issues/40 | jq --exit-status '.state == "closed" and .state_reason == "completed"'
  local body
  body="$(request_body PATCH repos/o/r/issues/40)"
  assert_equal "$(head --lines=1 <<< "${body}")" '<!-- renovate-problems set=0123456789abcdef resolved=1 -->'
  assert_regex "${body}" '\*\*Outcome:\*\* Renovate no longer reports problems'
}

@test "problems: a hand-closed issue with the same problems is not re-filed" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  local body
  body="$(first_render "${FIXTURES}/hosted-problems.txt")"
  stub_problems "${FIXTURES}/hosted-problems.txt"
  stub_issue_list "$(dashboard_issue "${FIXTURES}/hosted-problems.txt")" \
    "$(problems_issue 40 closed "${body}" '2026-11-10T12:00:00Z')"
  run "${SCRIPT}" problems
  assert_success
  assert_no_issue_writes
}

@test "problems: a hand-closed issue with different problems gets a new issue" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  stub_problems "${FIXTURES}/hosted-problems.txt"
  stub_issue_list "$(dashboard_issue "${FIXTURES}/hosted-problems.txt")" \
    "$(problems_issue 40 closed $'<!-- renovate-problems set=0000000000000000 -->\nold' '2026-11-10T12:00:00Z')"
  run "${SCRIPT}" problems
  assert_success
  assert_equal "$(call_count POST repos/o/r/issues)" 1
}

@test "problems: only the latest closed issue decides a hand-close" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  local body
  body="$(first_render "${FIXTURES}/hosted-problems.txt")"
  stub_problems "${FIXTURES}/hosted-problems.txt"
  stub_issue_list "$(dashboard_issue "${FIXTURES}/hosted-problems.txt")" \
    "$(problems_issue 40 closed "${body}" '2026-11-01T12:00:00Z')" \
    "$(problems_issue 41 closed $'<!-- renovate-problems set=0000000000000000 -->\nold' '2026-11-10T12:00:00Z')"
  run "${SCRIPT}" problems
  assert_success
  assert_equal "$(call_count POST repos/o/r/issues)" 1
}

@test "problems: problems returning after a resolved close file a new issue" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  local body
  body="$(first_render "${FIXTURES}/hosted-problems.txt")"
  body="$(sed '1s/ -->$/ resolved=1 -->/' <<< "${body}")"
  stub_problems "${FIXTURES}/hosted-problems.txt"
  stub_issue_list "$(dashboard_issue "${FIXTURES}/hosted-problems.txt")" \
    "$(problems_issue 40 closed "${body}" '2026-11-10T12:00:00Z')"
  run "${SCRIPT}" problems
  assert_success
  assert_equal "$(call_count POST repos/o/r/issues)" 1
}

@test "problems: outside the window an open issue is never edited or closed" {
  export PROBLEMS_NOW='2026-11-16T14:17:00Z'
  local fixture
  for fixture in clean.txt hosted-problems.txt; do
    stub_problems "${FIXTURES}/${fixture}"
    stub_issue_list "$(dashboard_issue "${FIXTURES}/${fixture}")" \
      "$(problems_issue 40 open $'<!-- renovate-problems set=0000000000000000 -->\nold')"
    run "${SCRIPT}" problems
    assert_success
  done
  assert_no_issue_writes
}

@test "problems: outside the window a new problem still files an issue" {
  export PROBLEMS_NOW='2026-11-16T14:17:00Z'
  stub_problems "${FIXTURES}/hosted-problems.txt"
  run "${SCRIPT}" problems
  assert_success
  assert_equal "$(call_count POST repos/o/r/issues)" 1
}

@test "problems: no Dashboard closes the open problems issue as not_planned" {
  export PROBLEMS_NOW='2026-11-16T14:17:00Z'
  stub_issue_list "$(problems_issue 40 open $'<!-- renovate-problems set=0123456789abcdef -->\nold')"
  stub_response PATCH 'repos/o/r/issues/40' '{"number":40}'
  run "${SCRIPT}" problems
  assert_success
  request_json PATCH repos/o/r/issues/40 | jq --exit-status '.state == "closed" and .state_reason == "not_planned"'
  assert_regex "$(request_body PATCH repos/o/r/issues/40)" '\*\*Outcome:\*\* Dependency Dashboard not found'
}

@test "problems: the window boundaries are exact across DST" {
  local spec now expected
  for spec in \
    '2026-10-31T21:59:00Z out' '2026-10-31T22:00:00Z in' \
    '2026-11-01T22:59:00Z in' '2026-11-01T23:00:00Z out' \
    '2026-11-07T22:59:00Z out' '2026-11-07T23:00:00Z in' \
    '2026-03-14T22:00:00Z in' \
    '2026-10-25T21:59:00Z in' '2026-10-25T22:00:00Z out'; do
    now="${spec% *}" expected="${spec#* }"
    export GH_STUB_DIR="${BATS_TEST_TMPDIR}/window-${now//:/}"
    mkdir --parents "${GH_STUB_DIR}"
    stub_problems "${FIXTURES}/clean.txt"
    stub_issue_list "$(dashboard_issue "${FIXTURES}/clean.txt")" \
      "$(problems_issue 40 open $'<!-- renovate-problems set=0123456789abcdef -->\nold')"
    stub_response PATCH 'repos/o/r/issues/40' '{"number":40}'
    PROBLEMS_NOW="${now}" run "${SCRIPT}" problems
    assert_success
    if [[ "${expected}" == 'in' ]]; then
      assert_equal "$(call_count PATCH repos/o/r/issues/40)" 1
    else
      assert_equal "$(call_count PATCH repos/o/r/issues/40)" 0
    fi
  done
}

@test "problems: the window matches the preset's lock-file maintenance schedule" {
  jq --exit-status '.timezone == "America/New_York"
    and .lockFileMaintenance.schedule == ["* 18-23 * * 6", "* 0-17 * * 0"]' \
    "${REPO_DIR}/default.json" > /dev/null
}

@test "sweep: problems issues are never touched by the per-PR modes" {
  stub_open_prs '[]'
  stub_issue_list "$(problems_issue 40 open $'<!-- renovate-problems set=0123456789abcdef -->\nold')"
  run "${SCRIPT}" sweep
  assert_success
  assert_no_issue_writes
}

@test "problems: problems returning after a not-found close file a new issue" {
  export PROBLEMS_NOW='2026-11-16T14:17:00Z'
  stub_issue_list "$(problems_issue 40 open $'<!-- renovate-problems set=0123456789abcdef -->\nold')"
  stub_response PATCH 'repos/o/r/issues/40' '{"number":40}'
  run "${SCRIPT}" problems
  assert_success
  local closed
  closed="$(request_body PATCH repos/o/r/issues/40)"
  assert_regex "$(head --lines=1 <<< "${closed}")" ' resolved=1 -->$'
}

@test "problems: outside the window a hand-closed issue is never followed by a new one" {
  export PROBLEMS_NOW='2026-11-16T14:17:00Z'
  stub_problems "${FIXTURES}/hosted-problems.txt"
  stub_issue_list "$(dashboard_issue "${FIXTURES}/hosted-problems.txt")" \
    "$(problems_issue 40 closed $'<!-- renovate-problems set=0000000000000000 -->\nold' '2026-11-15T22:30:00Z')"
  run "${SCRIPT}" problems
  assert_success
  assert_no_issue_writes
}

@test "problems: closing a reopened resolved issue keeps a single resolved field" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  stub_problems "${FIXTURES}/clean.txt"
  stub_issue_list "$(dashboard_issue "${FIXTURES}/clean.txt")" \
    "$(problems_issue 40 open $'<!-- renovate-problems set=0123456789abcdef resolved=1 -->\nold')"
  stub_response PATCH 'repos/o/r/issues/40' '{"number":40}'
  run "${SCRIPT}" problems
  assert_success
  assert_equal "$(head --lines=1 <<< "$(request_body PATCH repos/o/r/issues/40)")" \
    '<!-- renovate-problems set=0123456789abcdef resolved=1 -->'
}

@test "problems: markup after a Mend link never reaches the issue" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  sed 's#https://developer.mend.io//github/o/r#https://developer.mend.io/<details><summary>x</summary>#; s#https://developer.mend.io/github/o/r#https://developer.mend.io/<img src=x>#' \
    "${FIXTURES}/hosted-problems.txt" > "${BATS_TEST_TMPDIR}/dashboard.md"
  stub_problems "${BATS_TEST_TMPDIR}/dashboard.md"
  run "${SCRIPT}" problems
  assert_success
  local logs
  logs="$(grep --fixed-strings '**Renovate logs:**' <<< "$(request_body POST repos/o/r/issues)" || true)"
  [[ "${logs}" != *'<'* ]] || fail "markup reached the log link: ${logs}"
}

@test "problems: the Dashboard and problems issues come from narrowed listings" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  stub_problems "${FIXTURES}/hosted-problems.txt"
  run "${SCRIPT}" problems
  assert_success
  run grep '^CALL GET repos/o/r/issues?' "${GH_STUB_DIR}/calls.log"
  assert_line 'CALL GET repos/o/r/issues?state=open&creator=renovate%5Bbot%5D&per_page=100'
  assert_line 'CALL GET repos/o/r/issues?state=all&labels=renovate-failure&per_page=100'
  refute_line 'CALL GET repos/o/r/issues?state=all&per_page=100'
}

@test "problems: the log link is the Dashboard's View logs link" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  stub_problems "${FIXTURES}/hosted-problems.txt"
  run "${SCRIPT}" problems
  assert_success
  run grep --fixed-strings '**Renovate logs:**' <<< "$(request_body POST repos/o/r/issues)"
  assert_output '**Renovate logs:** https://developer.mend.io//github/o/r'
}

@test "problems: a Dashboard without a View logs link gets no log link" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  printf '%s\n' '[portal](https://developer.mend.io/github/o/r)' '' '## Repository Problems' '' 'header' '' \
    ' - ⚠️ WARN: Error updating flake.lock' > "${BATS_TEST_TMPDIR}/dashboard.md"
  stub_problems "${BATS_TEST_TMPDIR}/dashboard.md"
  run "${SCRIPT}" problems
  assert_success
  [[ "$(request_body POST repos/o/r/issues)" != *'Renovate logs'* ]] || fail 'a non-log link was labeled as the logs'
}

@test "problems: missing time zone data is an error, not a silent UTC window" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  stub_problems "${FIXTURES}/hosted-problems.txt"
  mkdir --parents "${BATS_TEST_TMPDIR}/no-zoneinfo"
  TZDIR="${BATS_TEST_TMPDIR}/no-zoneinfo" run "${SCRIPT}" problems
  assert_failure 1
  assert_output --partial 'time zone data for America/New_York'
  assert_no_issue_writes
}

@test "problems: a lookup warning cannot break out of the fence or mention anyone" {
  export PROBLEMS_NOW="${IN_WINDOW}"
  printf '%s\n' '---' '' '> ⚠️ **Warning**' '> ' \
    '> Renovate failed to look up the following dependencies: `x` ``` @someone.' \
    '> ' '> Files affected: `flake.nix`' '' '---' > "${BATS_TEST_TMPDIR}/dashboard.md"
  stub_problems "${BATS_TEST_TMPDIR}/dashboard.md"
  run "${SCRIPT}" problems
  assert_success
  local body outside
  body="$(request_body POST repos/o/r/issues)"
  [[ "${body}" == *'@someone'* ]] || fail 'the lookup warning was not copied'
  outside="$(awk '
    !inside && /^````+text$/ { inside = 1; fence = substr($0, 1, length($0) - 4); next }
    inside && $0 == fence { inside = 0; next }
    !inside { print }' <<< "${body}")"
  [[ "${outside}" != *'@someone'* ]] || fail 'a mention escaped the fenced block'
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
