# scripts/examples-pr, against the stub `gh` in tests/fixtures/gh-stub: each
# case writes the canned API responses it needs under GH_STUB_DIR, runs the
# script, and reads back what it sent from the stub's calls.log and saved
# request bodies.
#
# Every fixture repository is `o/r`, the new release is v9.8.7 at RELEASE_SHA,
# and the examples are a copy of this repository's examples/ under
# EXAMPLES_ROOT, so the real files are never rewritten.

# The jq filters are single-quoted on purpose: their $variables are jq's, not
# the shell's.
# shellcheck disable=SC2016

# Cases export the env the script reads. Each @test runs in its own subshell on
# purpose, so an export never leaks into the next case, which is exactly what
# SC2030/SC2031 warn about.
# shellcheck disable=SC2030,SC2031

bats_require_minimum_version 1.5.0

readonly RELEASE_SHA='0123456789abcdef0123456789abcdef01234567'
readonly HEAD_SHA='89abcdef0123456789abcdef0123456789abcdef'
readonly BRANCH='chore/examples-v9.8.7'
readonly HEADLINE='chore: point examples at v9.8.7'

function setup() {
  load 'test_helper/common'
  SCRIPT="${REPO_DIR}/scripts/examples-pr"
  export GH_STUB_DIR="${BATS_TEST_TMPDIR}/gh"
  mkdir --parents "${GH_STUB_DIR}"
  export PATH="${REPO_DIR}/tests/fixtures/gh-stub:${PATH}"
  export GITHUB_REPOSITORY='o/r'
  export TAG='v9.8.7'
  export SHA="${RELEASE_SHA}"
  export EXAMPLES_ROOT="${BATS_TEST_TMPDIR}/root"
  mkdir --parents "${EXAMPLES_ROOT}"
  cp --recursive "${REPO_DIR}/examples" "${EXAMPLES_ROOT}/examples"
}

# @description Write one canned stub response.
# @arg $1 method HTTP method, e.g. GET
# @arg $2 path API path; any `?query` is ignored, as the stub ignores it
# @arg $3 content the response body
function stub_response() {
  local -r method="$1" path="$2" content="$3"
  local mapped="${path%%\?*}"
  mapped="${mapped//\//__}"
  mkdir --parents "${GH_STUB_DIR}/${method}"
  printf '%s\n' "${content}" > "${GH_STUB_DIR}/${method}/${mapped}.json"
}

# @description Print one open PR as the pulls list returns it: this
#              repository's examples PR for v9.8.7 with auto-merge armed,
#              unless the overrides say otherwise.
# @arg $1 number the PR number
# @arg $2 overrides optional jq filter applied to the PR
# @stdout the PR as compact JSON
function examples_pr() {
  local -r number="$1" overrides="${2:-.}"
  jq --null-input --compact-output --argjson number "${number}" \
    --arg branch "${BRANCH}" --arg sha "${HEAD_SHA}" \
    "{number: \$number, node_id: \"PR_node\\(\$number)\", state: \"open\",
      auto_merge: {merge_method: \"merge\"},
      head: {ref: \$branch, sha: \$sha, repo: {full_name: \"o/r\"}}} | ${overrides}"
}

# @description Stub the open-PR listing as one page.
# @arg $1 prs JSON array of PRs
function stub_open_prs() {
  stub_response GET 'repos/o/r/pulls' "$1"
}

# @description Stub every write `open` makes on the way to a new PR: the ref
#              create, the GraphQL calls, and the PR create (#12).
function stub_open_writes() {
  stub_response POST 'repos/o/r/git/refs' "{\"ref\":\"refs/heads/${BRANCH}\"}"
  stub_response POST 'graphql' \
    '{"data":{"createCommitOnBranch":{"commit":{"oid":"ffffffffffffffffffffffffffffffffffffffff"}},"enablePullRequestAutoMerge":{"pullRequest":{"number":12}}}}'
  stub_response POST 'repos/o/r/pulls' '{"number":12,"node_id":"PR_node12","html_url":"https://github.com/o/r/pull/12"}'
}

# @description Print the newest saved request body for a method and path.
# @arg $1 method HTTP method
# @arg $2 path API path
# @stdout the request JSON
function request_json() {
  local -r method="$1" path="$2"
  local -a files=("${GH_STUB_DIR}/requests/"*"-${method}-${path//\//__}.json")
  [[ -f "${files[-1]}" ]] || fail "no ${method} ${path} request was sent"
  cat "${files[-1]}"
}

# @description Print the saved GraphQL request whose query names a mutation.
# @arg $1 mutation the mutation field name, e.g. createCommitOnBranch
# @stdout the request JSON
function graphql_request() {
  local file
  for file in "${GH_STUB_DIR}/requests/"*'-POST-graphql.json'; do
    [[ -f "${file}" ]] || continue
    if jq --exit-status --arg m "$1" '.query | contains($m)' "${file}" > /dev/null; then
      cat "${file}"
      return 0
    fi
  done
  fail "no GraphQL $1 request was sent"
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

# @description Fail if calls.log records any call other than a GET.
function assert_no_writes() {
  if [[ -f "${GH_STUB_DIR}/calls.log" ]]; then
    run grep --extended-regexp '^CALL (POST|PATCH|PUT|DELETE) ' "${GH_STUB_DIR}/calls.log"
    assert_failure
  fi
}

# @description Print a file's content decoded from the base64 a commit request
#              carries for a path.
# @arg $1 request the createCommitOnBranch request JSON
# @arg $2 path the file path in the commit
# @stdout the decoded content
function committed_file() {
  jq --raw-output --arg p "$2" '.variables.input.fileChanges.additions[] | select(.path == $p) | .contents' <<< "$1" \
    | base64 --decode
}

@test "open: creates the branch at the release sha, commits both files, opens the PR, arms merge auto-merge" {
  stub_open_prs '[]'
  stub_open_writes

  run "${SCRIPT}" open
  assert_success

  run jq --exit-status --arg sha "${RELEASE_SHA}" --arg ref "refs/heads/${BRANCH}" \
    '.sha == $sha and .ref == $ref' <<< "$(request_json POST 'repos/o/r/git/refs')"
  assert_success

  local commit
  commit="$(graphql_request createCommitOnBranch)"
  run jq --exit-status --arg sha "${RELEASE_SHA}" --arg headline "${HEADLINE}" --arg branch "${BRANCH}" '
    .variables.input
    | .expectedHeadOid == $sha
      and .message.headline == $headline
      and .branch == {repositoryNameWithOwner: "o/r", branchName: $branch}
      and ([.fileChanges.additions[].path] | sort) == ["examples/renovate-failure-issue.yml", "examples/renovate.json5"]' \
    <<< "${commit}"
  assert_success
  # The commit carries the rewritten files, not the originals.
  run committed_file "${commit}" 'examples/renovate.json5'
  assert_output --partial 'github>rvenutolo/renovate-config#v9.8.7'
  run committed_file "${commit}" 'examples/renovate-failure-issue.yml'
  assert_output --partial "renovate-failure-issue.yml@${RELEASE_SHA}  # v9.8.7"

  run jq --exit-status --arg headline "${HEADLINE}" --arg branch "${BRANCH}" '
    .title == $headline and .head == $branch and .base == "main"
      and (.body | test("release workflow"))' <<< "$(request_json POST 'repos/o/r/pulls')"
  assert_success

  run jq --exit-status '.variables == {pullRequestId: "PR_node12", mergeMethod: "MERGE"}' \
    <<< "$(graphql_request enablePullRequestAutoMerge)"
  assert_success
}

@test "open: closes an older examples PR" {
  stub_open_prs "[$(examples_pr 3 '.head.ref = "chore/examples-v1.0.0"')]"
  stub_open_writes
  stub_response PATCH 'repos/o/r/pulls/3' '{"number":3,"state":"closed"}'
  stub_response DELETE 'repos/o/r/git/refs/heads/chore/examples-v1.0.0' ''

  run "${SCRIPT}" open
  assert_success

  run jq --exit-status '.state == "closed"' <<< "$(request_json PATCH 'repos/o/r/pulls/3')"
  assert_success
  assert_equal "$(call_count DELETE 'repos/o/r/git/refs/heads/chore/examples-v1.0.0')" 1
  assert_equal "$(call_count POST 'repos/o/r/pulls')" 1
}

@test "open: re-run with its PR already open exits 0 and creates nothing" {
  stub_open_prs "[$(examples_pr 12)]"
  local before
  before="$(cat "${EXAMPLES_ROOT}/examples/"*)"

  run "${SCRIPT}" open
  assert_success
  assert_output --partial "#12"

  assert_no_writes
  assert_equal "$(cat "${EXAMPLES_ROOT}/examples/"*)" "${before}"
}

@test "open: re-run whose PR lost its auto-merge arms it again" {
  stub_open_prs "[$(examples_pr 12 '.auto_merge = null')]"
  stub_open_writes

  run "${SCRIPT}" open
  assert_success

  run jq --exit-status '.variables == {pullRequestId: "PR_node12", mergeMethod: "MERGE"}' \
    <<< "$(graphql_request enablePullRequestAutoMerge)"
  assert_success
  assert_equal "$(call_count POST 'repos/o/r/git/refs')" 0
  assert_equal "$(call_count POST 'repos/o/r/pulls')" 0
}

@test "open: leaves a fork's chore/examples- PR alone" {
  stub_open_prs "[$(examples_pr 3 '.head.ref = "chore/examples-v1.0.0" | .head.repo.full_name = "evil/r"'),
    $(examples_pr 4 '.head.repo.full_name = "evil/r"'),
    $(examples_pr 5 '.head.repo = null')]"
  stub_open_writes

  run "${SCRIPT}" open
  assert_success

  assert_equal "$(call_count PATCH 'repos/o/r/pulls/3')" 0
  assert_equal "$(call_count PATCH 'repos/o/r/pulls/4')" 0
  assert_equal "$(call_count PATCH 'repos/o/r/pulls/5')" 0
  run grep '^CALL DELETE ' "${GH_STUB_DIR}/calls.log"
  assert_failure
  # A fork's PR from the same branch name is not this release's PR.
  assert_equal "$(call_count POST 'repos/o/r/pulls')" 1
}

@test "open: a leftover branch with no PR is reset to the release sha" {
  stub_open_prs '[]'
  stub_open_writes
  stub_response GET "repos/o/r/git/ref/heads/${BRANCH}" '{"object":{"sha":"ffffffffffffffffffffffffffffffffffffffff"}}'
  stub_response PATCH "repos/o/r/git/refs/heads/${BRANCH}" '{}'

  run "${SCRIPT}" open
  assert_success

  run jq --exit-status --arg sha "${RELEASE_SHA}" '.sha == $sha and .force == true' \
    <<< "$(request_json PATCH "repos/o/r/git/refs/heads/${BRANCH}")"
  assert_success
  assert_equal "$(call_count POST 'repos/o/r/git/refs')" 0
  run jq --exit-status --arg sha "${RELEASE_SHA}" '.variables.input.expectedHeadOid == $sha' \
    <<< "$(graphql_request createCommitOnBranch)"
  assert_success
  assert_equal "$(call_count POST 'repos/o/r/pulls')" 1
}

@test "open: examples already at the release exit 0 and create nothing" {
  "${REPO_DIR}/scripts/update-examples" "${TAG}" "${SHA}" "${EXAMPLES_ROOT}"
  stub_open_prs '[]'
  stub_open_writes

  run "${SCRIPT}" open
  assert_success
  assert_output --partial 'already'

  assert_no_writes
}

@test "open: a failing update-examples fails the run before any branch exists" {
  printf '{}\n' > "${EXAMPLES_ROOT}/examples/renovate.json5"
  stub_open_prs '[]'
  stub_open_writes

  run "${SCRIPT}" open
  assert_failure

  assert_no_writes
}

@test "open: rejects a malformed tag or sha before any API call" {
  local tag
  for tag in 'v9.8' '9.8.7' 'v9.8.7/x' ''; do
    TAG="${tag}"
    run "${SCRIPT}" open
    assert_failure 2
  done
  TAG='v9.8.7'
  local sha
  for sha in '0123' "${RELEASE_SHA^^}" "${RELEASE_SHA}0" ''; do
    SHA="${sha}"
    run "${SCRIPT}" open
    assert_failure 2
  done
  [[ ! -e "${GH_STUB_DIR}/calls.log" ]] || fail 'an API call was made'
}

@test "refresh: updates a behind PR with the merge method" {
  stub_open_prs "[$(examples_pr 12)]"
  stub_response GET "repos/o/r/compare/main...${HEAD_SHA}" '{"behind_by":2,"ahead_by":1}'
  stub_response PUT 'repos/o/r/pulls/12/update-branch' '{"message":"Updating pull request branch."}'

  run "${SCRIPT}" refresh
  assert_success

  # The REST endpoint only merges; anything beyond the expected head would be
  # a different update method.
  run jq --exit-status --arg sha "${HEAD_SHA}" '. == {expected_head_sha: $sha}' \
    <<< "$(request_json PUT 'repos/o/r/pulls/12/update-branch')"
  assert_success
}

@test "refresh: leaves an up-to-date PR alone" {
  stub_open_prs "[$(examples_pr 12)]"
  stub_response GET "repos/o/r/compare/main...${HEAD_SHA}" '{"behind_by":0,"ahead_by":1}'

  run "${SCRIPT}" refresh
  assert_success

  assert_no_writes
}

@test "refresh: no examples PR is a no-op" {
  stub_open_prs "[$(examples_pr 4 '.head.repo.full_name = "evil/r"'),
    $(examples_pr 6 '.head.ref = "renovate/foo"')]"

  run "${SCRIPT}" refresh
  assert_success

  assert_no_writes
  assert_equal "$(call_count GET "repos/o/r/compare/main...${HEAD_SHA}")" 0
}

@test "an unknown or missing subcommand exits 2" {
  run "${SCRIPT}" bogus
  assert_failure 2
  run "${SCRIPT}"
  assert_failure 2
}

@test "a missing GITHUB_REPOSITORY exits 2" {
  unset GITHUB_REPOSITORY
  run "${SCRIPT}" refresh
  assert_failure 2
}
