# default.json, the shared Renovate preset: one jq assertion per decided
# behavior, so a silent change to any of them fails by name.
#
# Rule order is asserted where it matters: Renovate applies packageRules in
# order and a later rule wins.

# The jq filters are single-quoted on purpose: their $variables are jq's, not
# the shell's.
# shellcheck disable=SC2016

function setup() {
  load 'test_helper/common'
  PRESET="${REPO_DIR}/default.json"
}

# @description Assert a jq filter is true for default.json.
# @arg $1 string jq filter
function preset_assert() {
  jq --exit-status "$1" "${PRESET}" > /dev/null
}

@test "preset: extends config:best-practices only" {
  preset_assert '.extends == ["config:best-practices"]'
}

@test "preset: timezone is America/New_York" {
  preset_assert '.timezone == "America/New_York"'
}

@test "preset: main window is Fri 6pm–Sun 6pm" {
  preset_assert '.schedule == ["* 18-23 * * 5","* * * * 6","* 0-17 * * 0"]'
}

@test "preset: lock-file maintenance enabled, Sat 6pm–Sun 6pm, automerged" {
  preset_assert '.lockFileMaintenance == {"enabled":true,"schedule":["* 18-23 * * 6","* 0-17 * * 0"],"automerge":true}'
}

@test "preset: automerge via GitHub auto-merge, top-level" {
  preset_assert '.automerge == true and .automergeType == "pr" and .platformAutomerge == true'
}

@test "preset: no updates outside the window" {
  preset_assert '.updateNotScheduled == false'
}

@test "preset: rebases when behind base branch" {
  preset_assert '.rebaseWhen == "behind-base-branch"'
}

@test "preset: no PR limits" {
  preset_assert '.prHourlyLimit == 0 and .prConcurrentLimit == 0 and .branchConcurrentLimit == 0'
}

@test "preset: dependency dashboard on, config migration off" {
  preset_assert '.dependencyDashboard == true and .configMigration == false'
}

@test "preset: conventional chore(deps) commits" {
  preset_assert '.semanticCommits == "enabled" and .semanticCommitType == "chore" and .semanticCommitScope == "deps"'
}

@test "preset: dependencies label" {
  preset_assert '.labels == ["dependencies"]'
}

@test "preset: nix enabled" {
  preset_assert '.nix.enabled == true'
}

@test "preset: security fixes bypass schedule, grouping and release age" {
  preset_assert '.vulnerabilityAlerts == {"enabled":true,"schedule":[],"minimumReleaseAge":null,"groupName":null,"automerge":true}'
}

@test "preset: non-major batch covers every non-major type" {
  preset_assert '
    [.packageRules[] | select(.groupSlug == "all-non-major")] as $rules
    | ($rules | length) == 1
    and $rules[0].groupName == "all non-major dependencies"
    and $rules[0].matchPackageNames == ["*"]
    and (($rules[0].matchUpdateTypes | sort) == (["minor","patch","pin","pinDigest","digest","lockfileUpdate","bump","replacement"] | sort))'
}

@test "preset: majors are never grouped" {
  preset_assert '[.packageRules[] | select(has("groupName") and ((.matchUpdateTypes // []) | index("major")))] | length == 0'
}

@test "preset: 7-day release age lives in packageRules" {
  preset_assert 'has("minimumReleaseAge") | not'
  preset_assert 'any(.packageRules[]; .matchPackageNames == ["*"] and .minimumReleaseAge == "7 days")'
}

@test "preset: 7-day rule does not hold updates that have no release timestamp" {
  preset_assert '[.packageRules[] | select(.matchPackageNames == ["*"] and .minimumReleaseAge == "7 days")]
    | length == 1 and .[0].minimumReleaseAgeBehaviour == "timestamp-optional"'
}

@test "preset: release-age carve-outs follow the 7-day rule" {
  preset_assert '
    (.packageRules | map(.matchPackageNames == ["*"] and .minimumReleaseAge == "7 days") | index(true)) as $age
    | (.packageRules | map(
        ((.matchUpdateTypes // []) as $t
          | (["lockFileMaintenance","pin","replacement","bump","rollback","lockfileUpdate"] | all(. as $x | $t | index($x) != null))
          and has("minimumReleaseAge") and .minimumReleaseAge == null)) | index(true)) as $none
    | $age != null and $none != null and $none > $age'
}

@test "preset: own releases exempt from release age, after the 7-day rule" {
  preset_assert '
    (.packageRules | map(.matchPackageNames == ["*"] and .minimumReleaseAge == "7 days") | index(true)) as $age
    | (.packageRules | map(
        (.matchPackageNames // []) as $n
        | ($n | index("rvenutolo/renovate-config")) != null
        and has("minimumReleaseAge") and .minimumReleaseAge == null) | index(true)) as $own
    | $age != null and $own != null and $own > $age'
}

@test "preset: pre-commit manager enabled" {
  preset_assert '."pre-commit".enabled == true'
}

@test "preset: every packageRule has a description" {
  preset_assert 'all(.packageRules[]; (.description | type) == "string" or (.description | type) == "array")'
}

@test "preset: dependency dashboard title is pinned" {
  preset_assert '.dependencyDashboardTitle == "Dependency Dashboard"'
}

@test "preset: top-level description explains each setting" {
  preset_assert '(.description | type == "array") and (.description | length >= 10)'
}

# @description Print the tool-pin regex's captures for $1 as a compact JSON
#              array, one object per match, using jq's regex engine.
# @arg $1 string text to match
function tool_pin_captures() {
  jq --compact-output --arg text "$1" \
    '.customManagers[0].matchStrings[0] as $re | [$text | capture($re; "g")]' "${PRESET}"
}

# @description Assert a jq filter is true for the tool-pin captures of $1.
# @arg $1 string text to match
# @arg $2 string jq filter over the captures array
function tool_pin_assert() {
  tool_pin_captures "$1" | jq --exit-status "$2" > /dev/null
}

@test "tool pins: manager scans workflow files only" {
  preset_assert '.customManagers[0].customType == "regex" and .customManagers[0].managerFilePatterns == ["/(^|/)\\.github/workflows/[^/]+\\.ya?ml$/"]'
}

@test "tool pins: manager has a description" {
  preset_assert '(.customManagers[0].description | type) as $t | $t == "string" or $t == "array"'
}

@test "tool pins: version only, unquoted" {
  text="$(printf '# renovate: datasource=pypi depName=pre-commit\n  PRE_COMMIT_VERSION: 4.7.0\n')"
  tool_pin_assert "${text}" 'length == 1 and .[0].datasource == "pypi" and .[0].depName == "pre-commit" and .[0].currentValue == "4.7.0" and ((.[0].currentDigest // "") == "")'
}

@test "tool pins: single-quoted value" {
  text="$(printf "# renovate: datasource=npm depName=@anthropic-ai/claude-code\n      CLAUDE_CODE_VERSION: '2.1.317'\n")"
  tool_pin_assert "${text}" 'length == 1 and .[0].currentValue == "2.1.317" and .[0].depName == "@anthropic-ai/claude-code"'
}

@test "tool pins: double-quoted value" {
  text="$(printf '# renovate: datasource=pypi depName=pytest\n  PYTEST_VERSION: "9.1.1"\n')"
  tool_pin_assert "${text}" 'length == 1 and .[0].currentValue == "9.1.1"'
}

@test "tool pins: versioning captured" {
  text="$(printf '# renovate: datasource=github-releases depName=x/y versioning=semver\n  Y_VERSION: 1.2.3\n')"
  tool_pin_assert "${text}" 'length == 1 and .[0].versioning == "semver" and .[0].depName == "x/y"'
}

@test "tool pins: version and sha256" {
  text="$(printf '# renovate: datasource=github-release-attachments depName=mvdan/sh\n  SHFMT_VERSION: v3.13.1\n  SHFMT_SHA256: fb096c5d1ac6beabbdbaa2874d025badb03ee07929f0c9ff67563ce8c75398b1\n')"
  tool_pin_assert "${text}" 'length == 1 and .[0].currentValue == "v3.13.1" and .[0].currentDigest == "fb096c5d1ac6beabbdbaa2874d025badb03ee07929f0c9ff67563ce8c75398b1"'
}

@test "tool pins: sha256 after a comment line is not captured" {
  text="$(printf '# renovate: datasource=github-release-attachments depName=mvdan/sh\n  SHFMT_VERSION: v3.13.1\n  # note\n  SHFMT_SHA256: fb096c5d1ac6beabbdbaa2874d025badb03ee07929f0c9ff67563ce8c75398b1\n')"
  tool_pin_assert "${text}" 'length == 1 and .[0].currentValue == "v3.13.1" and ((.[0].currentDigest // "") == "")'
}

@test "tool pins: sha256 after a blank line is not captured" {
  text="$(printf '# renovate: datasource=github-release-attachments depName=mvdan/sh\n  SHFMT_VERSION: v3.13.1\n\n  SHFMT_SHA256: fb096c5d1ac6beabbdbaa2874d025badb03ee07929f0c9ff67563ce8c75398b1\n')"
  tool_pin_assert "${text}" 'length == 1 and ((.[0].currentDigest // "") == "")'
}

@test "tool pins: two pins in one file match separately" {
  text="$(printf '# renovate: datasource=pypi depName=pre-commit\n  PRE_COMMIT_VERSION: 4.7.0\n# renovate: datasource=github-release-attachments depName=twpayne/chezmoi\n  CHEZMOI_VERSION: v2.74.1\n')"
  tool_pin_assert "${text}" 'length == 2 and .[0].depName == "pre-commit" and .[1].depName == "twpayne/chezmoi"'
}
