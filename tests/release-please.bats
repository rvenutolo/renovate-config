# The release-please workflow and its config: one assertion per decided
# property, so a silent change to the trigger, the token or the first version
# fails by name.

# The jq filters and the literal `${{ ... }}` strings are single-quoted on
# purpose: they are jq and GitHub expressions, not shell.
# shellcheck disable=SC2016

function setup() {
  load 'test_helper/common'
  WORKFLOW="${REPO_DIR}/.github/workflows/release-please.yml"
  CONFIG="${REPO_DIR}/.release-please-config.json"
  MANIFEST="${REPO_DIR}/.release-please-manifest.json"
}

# @description Assert a jq filter is true for a YAML file.
# @arg $1 string path to the YAML file
# @arg $2 string jq filter
function yaml_assert() {
  local json
  json="$(yq --output-format=json '.' "$1")"
  jq --exit-status "$2" <<< "${json}" > /dev/null
}

@test "release-please workflow: runs on pushes to main and by hand with a required tag" {
  yaml_assert "${WORKFLOW}" '(.on | keys) == ["push", "workflow_dispatch"]
    and .on.push == {"branches": ["main"]}
    and (.on.workflow_dispatch.inputs | keys) == ["tag"]
    and .on.workflow_dispatch.inputs.tag.required == true
    and .on.workflow_dispatch.inputs.tag.type == "string"
    and (.on.workflow_dispatch.inputs.tag.description | length > 0)'
}

@test "release-please workflow: release-please runs only on a push" {
  # A manual run retries only the examples PR of a release already tagged.
  yaml_assert "${WORKFLOW}" '[.jobs[].steps[] | select(.uses // "" | startswith("googleapis/release-please-action@"))]
    | length == 1 and .[0].if == "github.event_name == '\''push'\''"'
}

@test "release-please workflow: the workflow token gets no permissions" {
  yaml_assert "${WORKFLOW}" '.permissions == {} and ([.jobs[].permissions] | all(. == {}))'
}

@test "release-please workflow: release-please uses the app token, not GITHUB_TOKEN" {
  yaml_assert "${WORKFLOW}" '[.jobs[].steps[] | select(.uses // "" | startswith("googleapis/release-please-action@"))]
    | length == 1 and .[0].with.token == "${{ steps.app-token.outputs.token }}"'
}

@test "release-please workflow: app token comes from the repo variable and secret, scoped to what release-please needs" {
  yaml_assert "${WORKFLOW}" '[.jobs[].steps[] | select(.uses // "" | startswith("actions/create-github-app-token@"))]
    | length == 1
      and .[0].id == "app-token"
      and .[0].with["client-id"] == "${{ vars.RELEASE_APP_CLIENT_ID }}"
      and .[0].with["private-key"] == "${{ secrets.RELEASE_APP_PRIVATE_KEY }}"
      and .[0].with["permission-contents"] == "write"
      and .[0].with["permission-pull-requests"] == "write"
      and .[0].with["permission-issues"] == "write"'
}

@test "release-please workflow: egress blocked except the GitHub API and git" {
  yaml_assert "${WORKFLOW}" '[.jobs[].steps[] | select(.uses // "" | startswith("step-security/harden-runner@")) | .with]
    | length == 1
      and .[0]["egress-policy"] == "block"
      and (.[0]["allowed-endpoints"] | split(" ") | map(select(. != "")) | sort) == ["api.github.com:443", "github.com:443"]'
}

@test "release-please workflow: the release-please step exposes its outputs as release" {
  yaml_assert "${WORKFLOW}" '[.jobs[].steps[] | select(.uses // "" | startswith("googleapis/release-please-action@"))]
    | length == 1 and .[0].id == "release"'
}

# @description Print the position of the only step in the release-please job
#              that a jq filter selects; fail when not exactly one does.
# @arg $1 string jq filter, applied to each step, that is true for the wanted
#      one
# @stdout the zero-based step index
function step_index() {
  local json
  json="$(yq --output-format=json '.' "${WORKFLOW}")"
  jq --exit-status --raw-output \
    "[.jobs[\"release-please\"].steps | to_entries[] | select(.value | $1) | .key]
     | if length == 1 then .[0] else error(\"expected one matching step, got \\(length)\") end" \
    <<< "${json}"
}

@test "release-please workflow: a release or a manual run opens the examples PR, values only via env" {
  # On a manual run the release step is skipped, so SHA is empty and the
  # script resolves the tag itself.
  yaml_assert "${WORKFLOW}" '[.jobs[].steps[] | select(.run // "" | contains("scripts/examples-pr open"))]
    | length == 1
      and .[0].if == "steps.release.outputs.release_created == '\''true'\'' || github.event_name == '\''workflow_dispatch'\''"
      and .[0].env == {
        "GH_TOKEN": "${{ steps.app-token.outputs.token }}",
        "APP_SLUG": "${{ steps.app-token.outputs.app-slug }}",
        "TAG": "${{ inputs.tag || steps.release.outputs.tag_name }}",
        "SHA": "${{ steps.release.outputs.sha }}"
      }
      and (.[0].run | contains("${{") | not)'
}

@test "release-please workflow: every run refreshes the examples PR, values only via env" {
  # Unconditional, so an examples PR that open found or created behind main is
  # brought up to date in the same run.
  yaml_assert "${WORKFLOW}" '[.jobs[].steps[] | select(.run // "" | contains("scripts/examples-pr refresh"))]
    | length == 1
      and (.[0] | has("if") | not)
      and .[0].env == {
        "GH_TOKEN": "${{ steps.app-token.outputs.token }}",
        "APP_SLUG": "${{ steps.app-token.outputs.app-slug }}"
      }
      and (.[0].run | contains("${{") | not)'
}

@test "release-please workflow: the scripts come from a checkout that keeps no credentials" {
  local checkout open refresh
  checkout="$(step_index '(.uses // "" | startswith("actions/checkout@")) and .with["persist-credentials"] == false')"
  open="$(step_index '.run // "" | contains("scripts/examples-pr open")')"
  refresh="$(step_index '.run // "" | contains("scripts/examples-pr refresh")')"
  ((checkout < open && open < refresh))
}

@test "release-please workflow: checks out the pushed commit, or the tag on a manual run" {
  # inputs.tag is empty on a push, which leaves the default ref.
  yaml_assert "${WORKFLOW}" '[.jobs[].steps[] | select(.uses // "" | startswith("actions/checkout@"))]
    | length == 1 and .[0].with.ref == "${{ inputs.tag }}"'
}

@test "release-please workflow: reads the dotfile config and manifest" {
  yaml_assert "${WORKFLOW}" '[.jobs[].steps[] | select(.uses // "" | startswith("googleapis/release-please-action@"))]
    | length == 1
      and .[0].with["config-file"] == ".release-please-config.json"
      and .[0].with["manifest-file"] == ".release-please-manifest.json"'
}

@test "release-please config: one simple-type package at the root" {
  jq --exit-status '.packages | keys == ["."] and .["."]["release-type"] == "simple"' "${CONFIG}" > /dev/null
}

@test "release-please config: the version is never pinned" {
  # A release-as pin overrides the commits and would propose the same version
  # on every release PR; versions come from conventional commits.
  jq --exit-status '.packages["."] | has("release-as") | not' "${CONFIG}" > /dev/null
}

# @description Assert a release-please manifest maps only the root package,
#              if anything, to a semver version.
# @arg $1 string path to the manifest
function manifest_shape_ok() {
  jq --exit-status 'type == "object"
    and (keys - ["."] | length == 0)
    and ([.[]] | all(type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$")))' "$1" > /dev/null
}

@test "release-please manifest: maps only the root package to a semver version" {
  # release-please rewrites this file on every release, so the test pins its
  # shape, not a value: empty before the first release, then the root
  # package's current version.
  manifest_shape_ok "${MANIFEST}"
}

@test "release-please manifest: the shape check accepts a released version" {
  printf '{".":"1.0.0"}\n' > "${BATS_TEST_TMPDIR}/manifest.json"
  manifest_shape_ok "${BATS_TEST_TMPDIR}/manifest.json"
}

@test "release-please manifest: the shape check rejects a non-root package" {
  printf '{"pkg":"1.0.0"}\n' > "${BATS_TEST_TMPDIR}/manifest.json"
  run manifest_shape_ok "${BATS_TEST_TMPDIR}/manifest.json"
  assert_failure
}
