# The release-please workflow and its config: one assertion per decided
# property, so a silent change to the trigger, the token or the first version
# fails by name.

# The jq filters and the literal `${{ ... }}` strings are single-quoted on
# purpose: they are jq and GitHub expressions, not shell.
# shellcheck disable=SC2016

function setup() {
  load 'test_helper/common'
  WORKFLOW="${REPO_DIR}/.github/workflows/release-please.yml"
  CONFIG="${REPO_DIR}/release-please-config.json"
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

@test "release-please workflow: runs only on pushes to main" {
  yaml_assert "${WORKFLOW}" '.on == {"push": {"branches": ["main"]}}'
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

@test "release-please workflow: egress blocked except the GitHub API" {
  yaml_assert "${WORKFLOW}" '[.jobs[].steps[] | select(.uses // "" | startswith("step-security/harden-runner@")) | .with]
    | length == 1
      and .[0]["egress-policy"] == "block"
      and (.[0]["allowed-endpoints"] | split(" ") | map(select(. != "")) | sort) == ["api.github.com:443"]'
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
