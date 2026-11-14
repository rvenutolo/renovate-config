# The reusable failure-issue workflow, the consumer examples and this repo's
# own Renovate config: one assertion per decided property, so a silent change
# to a trigger, a permission or a gate fails by name.
#
# yq converts each workflow to JSON and jq asserts on it. .github/renovate.json5
# goes through pyjson5 instead, because yq has no JSON5 reader.

# The jq filters and the literal `${{ ... }}` strings are single-quoted on
# purpose: they are jq and GitHub expressions, not shell.
# shellcheck disable=SC2016

function setup() {
  load 'test_helper/common'
  REUSABLE="${REPO_DIR}/.github/workflows/renovate-failure-issue.yml"
  CALLER="${REPO_DIR}/examples/renovate-failure-issue.yml"
  EXAMPLE_CONFIG="${REPO_DIR}/examples/renovate.json5"
  OWN_CONFIG="${REPO_DIR}/.github/renovate.json5"
  EXAMPLES_FAILURE="${REPO_DIR}/.github/workflows/examples-pr-failure.yml"
}

# @description Assert a jq filter is true for a YAML file.
# @arg $1 string path to the YAML file
# @arg $2 string jq filter
function yaml_assert() {
  local json
  json="$(yq --output-format=json '.' "$1")"
  jq --exit-status "$2" <<< "${json}" > /dev/null
}

# @description Print the caller job's `if:` expression.
# @arg $1 string job id
# @stdout the expression
function caller_if() {
  yq --output-format=json '.' "${CALLER}" | jq --raw-output --arg job "$1" '.jobs[$job].if'
}

@test "own CI workflow: is named ci" {
  yaml_assert "${REPO_DIR}/.github/workflows/ci.yml" '.name == "ci"'
}

@test "reusable workflow: workflow_call only" {
  yaml_assert "${REUSABLE}" '.on | keys == ["workflow_call"]'
}

@test "reusable workflow: declares the inputs the caller passes" {
  yaml_assert "${REUSABLE}" '.on.workflow_call.inputs
    | (keys | sort) == (["mode","run-id","run-url","head-branch","run-conclusion","pr-number","pr-merged"] | sort)
      and .mode.required == true
      and ([to_entries[] | select(.key != "mode") | .value.required // false] | all(. == false))
      and ([.[].type] | all(. == "string"))'
}

@test "reusable workflow: checks out itself at job.workflow_sha" {
  yaml_assert "${REUSABLE}" '[.jobs[].steps[] | select(.uses // "" | startswith("actions/checkout@")) | .with]
    | length == 1
      and .[0].repository == "${{ job.workflow_repository }}"
      and .[0].ref == "${{ job.workflow_sha }}"
      and .[0]["persist-credentials"] == false'
}

@test "reusable workflow: egress blocked except GitHub and the job-log blob hosts" {
  # The job-logs endpoint redirects to numbered productionresultssa<N> hosts,
  # so without the wildcard every issue would lose its log tail.
  yaml_assert "${REUSABLE}" '[.jobs[].steps[] | select(.uses // "" | startswith("step-security/harden-runner@")) | .with]
    | length == 1
      and .[0]["egress-policy"] == "block"
      and (.[0]["allowed-endpoints"] | split(" ") | map(select(. != "")) | sort)
        == (["api.github.com:443","github.com:443","codeload.github.com:443","*.blob.core.windows.net:443"] | sort)'
}

@test "reusable workflow: uses only actions/* and harden-runner" {
  local uses
  uses="$(yq --output-format=json '.' "${REUSABLE}" | jq --raw-output '.jobs[].steps[] | .uses // empty')"
  [[ -n "${uses}" ]]
  local ref
  while IFS= read -r ref; do
    [[ "${ref}" =~ ^(actions/[^@]+|step-security/harden-runner)@[0-9a-f]{40}$ ]] \
      || fail "disallowed or unpinned uses: ${ref}"
  done <<< "${uses}"
}

@test "reusable workflow: no input expression inside run:" {
  yaml_assert "${REUSABLE}" '[.jobs[].steps[] | select(has("run")) | .run]
    | length > 0 and all(contains("${{") | not)'
}

@test "reusable workflow: runs the script with the mode from env" {
  yaml_assert "${REUSABLE}" '[.jobs[].steps[] | select(has("run"))]
    | length == 1
      and (.[0].run | contains(".renovate-config/scripts/renovate-failure-issue \"${MODE}\""))
      and .[0].env.MODE == "${{ inputs.mode }}"
      and .[0].env.GH_TOKEN == "${{ github.token }}"'
}

@test "caller example: triggers on ci completion, PR close, two weekly schedules and manual dispatch" {
  yaml_assert "${CALLER}" '.on.workflow_run.workflows == ["ci"]
    and .on.workflow_run.types == ["completed"]
    and .on.pull_request_target.types == ["closed"]
    and .on.schedule == [{"cron":"17 14 * * 1"},{"cron":"47 19 * * 0"}]
    and (.on | has("workflow_dispatch"))'
}

@test "caller example: top-level permissions are empty" {
  yaml_assert "${CALLER}" '.permissions == {}'
}

@test "caller example: open job grants exactly issues write, actions read, pull-requests read" {
  yaml_assert "${CALLER}" '.jobs.open.permissions == {"issues":"write","actions":"read","pull-requests":"read"}'
}

@test "caller example: close job grants exactly issues write, pull-requests read" {
  yaml_assert "${CALLER}" '.jobs.close.permissions == {"issues":"write","pull-requests":"read"}'
}

@test "caller example: sweep job grants exactly issues write, pull-requests read, checks read, statuses read" {
  yaml_assert "${CALLER}" '.jobs.sweep.permissions == {"issues":"write","pull-requests":"read","checks":"read","statuses":"read"}'
}

@test "caller example: sweep and problems each run only on their own cron or manual dispatch" {
  local job cron expr
  for job in 'sweep:17 14 \* \* 1' 'problems:47 19 \* \* 0'; do
    cron="${job#*:}" job="${job%%:*}"
    expr="$(caller_if "${job}")"
    assert_regex "${expr}" "github\.event_name == 'schedule' && github\.event\.schedule == '${cron}'"
    assert_regex "${expr}" "github\.event_name == 'workflow_dispatch'"
  done
}

@test "caller example: problems job grants exactly issues write" {
  yaml_assert "${CALLER}" '.jobs.problems.permissions == {"issues":"write"}'
}

@test "caller example: problems job has its own non-cancelling concurrency group" {
  yaml_assert "${CALLER}" '.jobs.problems.concurrency.group == "renovate-failure-issue-problems"
    and .jobs.problems.concurrency["cancel-in-progress"] == false'
}

@test "caller example: sweep job has its own non-cancelling concurrency group" {
  yaml_assert "${CALLER}" '.jobs.sweep.concurrency.group == "renovate-failure-issue-sweep"
    and .jobs.sweep.concurrency["cancel-in-progress"] == false'
}

@test "caller example: open gates on renovate branch, failure conclusions and same-repo head" {
  local expr
  expr="$(caller_if open)"
  assert_regex "${expr}" "startsWith\(github\.event\.workflow_run\.head_branch, 'renovate/'\)"
  assert_regex "${expr}" 'github\.event\.workflow_run\.head_repository\.full_name == github\.repository'
  local conclusion
  for conclusion in failure timed_out startup_failure; do
    assert_regex "${expr}" "[\"']${conclusion}[\"']"
  done
  refute_regex "${expr}" 'cancelled'
}

@test "caller example gates on same-repo head" {
  local expr
  expr="$(caller_if close)"
  assert_regex "${expr}" 'github\.event\.pull_request\.head\.repo\.full_name == github\.repository'
  assert_regex "${expr}" "startsWith\(github\.event\.pull_request\.head\.ref, 'renovate/'\)"
}

@test "caller example: each job calls the reusable workflow in its own mode" {
  yaml_assert "${CALLER}" '.jobs.open.with.mode == "open" and .jobs.close.with.mode == "close"
    and .jobs.sweep.with.mode == "sweep" and .jobs.problems.with.mode == "problems"
    and ([.jobs[].uses] | length == 4 and all(startswith("rvenutolo/renovate-config/.github/workflows/renovate-failure-issue.yml@")))'
}

@test "caller example: no workflow-level concurrency" {
  yaml_assert "${CALLER}" 'has("concurrency") | not'
}

@test "caller example: open job concurrency keyed on branch, not cancelling" {
  yaml_assert "${CALLER}" '.jobs.open.concurrency.group == "renovate-failure-issue-${{ github.event.workflow_run.head_branch || github.event.pull_request.head.ref }}"
    and .jobs.open.concurrency["cancel-in-progress"] == false'
}

@test "caller example: close job has no concurrency group" {
  yaml_assert "${CALLER}" '.jobs.close | has("concurrency") | not'
}

@test "caller example: reusable workflow pinned by SHA with tag comment" {
  run grep --count --extended-regexp \
    '^[[:space:]]+uses: rvenutolo/renovate-config/\.github/workflows/renovate-failure-issue\.yml@[0-9a-f]{40}  # v[0-9]+\.[0-9]+\.[0-9]+$' \
    "${CALLER}"
  assert_success
  assert_output '4'
}

@test "renovate.json5 example: extends the tag-pinned preset" {
  run grep --fixed-strings 'github>rvenutolo/renovate-config#v' "${EXAMPLE_CONFIG}"
  assert_success
}

@test "own config: Renovate does not target examples/" {
  # update-examples repoints the examples at each release, so no manager may
  # also try to bump them.
  local json
  json="$(pyjson5 --as-json "${OWN_CONFIG}")"
  jq --exit-status '[.. | strings | select(contains("examples"))] | length == 0' \
    <<< "${json}" > /dev/null
}

@test "examples: copyable as-is" {
  [[ "$(head --lines=1 "${CALLER}")" == 'name: renovate-failure-issue' ]]
  run grep --ignore-case --extended-regexp 'placeholder|v0\.0\.0' "${EXAMPLE_CONFIG}"
  assert_failure 1
  run grep --extended-regexp '0{40}' "${CALLER}" "${EXAMPLE_CONFIG}"
  assert_failure 1
}

@test "examples: both files pin the same release" {
  local tag
  tag="$(grep --only-matching --extended-regexp 'renovate-config#v[0-9]+\.[0-9]+\.[0-9]+' "${EXAMPLE_CONFIG}" | sed 's/.*#//')"
  [[ -n "${tag}" ]]
  local -r pin='renovate-failure-issue\.yml@[0-9a-f]{40}  # v[0-9]+\.[0-9]+\.[0-9]+$'
  local comments shas
  comments="$(grep --extended-regexp "${pin}" "${CALLER}" | sed 's/.*# //' | sort --unique)"
  shas="$(grep --extended-regexp "${pin}" "${CALLER}" | sed --regexp-extended 's/.*@([0-9a-f]{40}).*/\1/' | sort --unique)"
  [[ "${comments}" == "${tag}" ]]
  [[ "$(wc --lines <<< "${shas}")" == 1 ]]
}

@test "caller example: each pinned uses: line is exempt from yamllint line-length" {
  # A full workflow path plus a 40-character SHA and tag comment runs past
  # 120 characters, so a consumer's yamllint would reject the copied file.
  local -r pinned='^ *uses: rvenutolo/renovate-config/'
  local -r exempt='^ *# yamllint disable-line rule:line-length'
  local uses_lines exempt_lines
  uses_lines="$(grep --count --extended-regexp -- "${pinned}" "${CALLER}")"
  exempt_lines="$(grep --before-context=1 --extended-regexp -- "${pinned}" "${CALLER}" | grep --count --extended-regexp -- "${exempt}" || true)"
  [[ "${uses_lines}" -eq 4 ]]
  [[ "${exempt_lines}" -eq "${uses_lines}" ]]
}

@test "examples-pr-failure workflow: triggers are workflow_run on ci and pull_request_target closed" {
  yaml_assert "${EXAMPLES_FAILURE}" '(.on | keys) == ["pull_request_target","workflow_run"]
    and .on.workflow_run.workflows == ["ci"] and .on.workflow_run.types == ["completed"]
    and .on.pull_request_target.types == ["closed"]'
}

@test "examples-pr-failure workflow: no workflow-level permissions" {
  yaml_assert "${EXAMPLES_FAILURE}" '.permissions == {}'
}

@test "examples-pr-failure workflow: failed job needs an examples branch of this repository and a failed run" {
  yaml_assert "${EXAMPLES_FAILURE}" '.jobs.failed.if
    | contains("github.event_name == '"'"'workflow_run'"'"'")
    and contains("startsWith(github.event.workflow_run.head_branch, '"'"'chore/examples-'"'"')")
    and contains("github.event.workflow_run.head_repository.full_name == github.repository")
    and contains("[\"failure\", \"timed_out\"]")
    and contains("github.event.workflow_run.conclusion")
    and (contains("startup_failure") | not) and (contains("cancelled") | not)'
}

@test "examples-pr-failure workflow: closed job needs an examples branch of this repository" {
  yaml_assert "${EXAMPLES_FAILURE}" '.jobs.closed.if
    | contains("github.event_name == '"'"'pull_request_target'"'"'")
    and contains("startsWith(github.event.pull_request.head.ref, '"'"'chore/examples-'"'"')")
    and contains("github.event.pull_request.head.repo.full_name == github.repository")'
}

@test "examples-pr-failure workflow: each job grants only issues write, pull-requests read and contents read" {
  # contents: read is for the checkout of the script; a job-level grant
  # replaces the default, so a private repository needs it named.
  yaml_assert "${EXAMPLES_FAILURE}" '.jobs | length == 2 and all(.[];
    .permissions == {"issues": "write", "pull-requests": "read", "contents": "read"})'
}

@test "examples-pr-failure workflow: no step checks out a PR ref" {
  yaml_assert "${EXAMPLES_FAILURE}" '[.jobs[].steps[] | select((.uses // "") | startswith("actions/checkout@"))]
    | length == 2 and all(.[]; (.with | has("ref") | not) and .with["persist-credentials"] == false)'
}

@test "examples-pr-failure workflow: untrusted values reach run steps only through env" {
  yaml_assert "${EXAMPLES_FAILURE}" '[.jobs[].steps[] | select(has("run")) | .run]
    | length == 2 and all(.[]; contains("${{") | not)'
  yaml_assert "${EXAMPLES_FAILURE}" '.jobs.failed.steps[] | select(has("run"))
    | .env.HEAD_BRANCH == "${{ github.event.workflow_run.head_branch }}"
      and .env.RUN_URL == "${{ github.event.workflow_run.html_url }}"'
  yaml_assert "${EXAMPLES_FAILURE}" '.jobs.closed.steps[] | select(has("run"))
    | .env.PR_NUMBER == "${{ github.event.pull_request.number }}"
      and .env.PR_MERGED == "${{ github.event.pull_request.merged }}"'
}

@test "examples-pr-failure workflow: every job hardens the runner with an egress block" {
  yaml_assert "${EXAMPLES_FAILURE}" 'all(.jobs[]; .["timeout-minutes"] != null
    and (.steps[0].uses | startswith("step-security/harden-runner@"))
    and .steps[0].with["egress-policy"] == "block"
    and .steps[0].with["allowed-endpoints"] == "api.github.com:443 github.com:443")'
}

@test "examples-pr-failure workflow: both dangerous triggers carry a zizmor ignore" {
  run grep --count --extended-regexp '^  (workflow_run|pull_request_target):  # zizmor: ignore\[dangerous-triggers\]$' "${EXAMPLES_FAILURE}"
  assert_success
  assert_output '2'
}
