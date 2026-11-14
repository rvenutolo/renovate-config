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

@test "preset: every packageRule has a description" {
  preset_assert 'all(.packageRules[]; (.description | type) == "string" or (.description | type) == "array")'
}

@test "preset: dependency dashboard title is pinned" {
  preset_assert '.dependencyDashboardTitle == "Dependency Dashboard"'
}

@test "preset: top-level description explains each setting" {
  preset_assert '(.description | type == "array") and (.description | length >= 10)'
}
