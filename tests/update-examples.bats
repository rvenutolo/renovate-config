# scripts/update-examples, run against a copy of the real examples/ under
# BATS_TEST_TMPDIR so the repo's own files are never touched.

bats_require_minimum_version 1.5.0

function setup() {
  load 'test_helper/common'
  SCRIPT="${REPO_DIR}/scripts/update-examples"
  ROOT="${BATS_TEST_TMPDIR}/root"
  mkdir --parents "${ROOT}"
  cp --recursive "${REPO_DIR}/examples" "${ROOT}/examples"
  CONFIG="${ROOT}/examples/renovate.json5"
  CALLER="${ROOT}/examples/renovate-failure-issue.yml"
  NEW_SHA='0123456789abcdef0123456789abcdef01234567'
}

@test "rewrites the extends tag" {
  run "${SCRIPT}" v9.8.7 "${NEW_SHA}" "${ROOT}"
  assert_success
  run grep --count '#v' "${CONFIG}"
  assert_output '1'
  run grep --fixed-strings 'github>rvenutolo/renovate-config#v9.8.7' "${CONFIG}"
  assert_success
}

@test "rewrites every uses: pin in the caller" {
  run "${SCRIPT}" v9.8.7 "${NEW_SHA}" "${ROOT}"
  assert_success
  local pins updated
  pins="$(grep --count 'renovate-failure-issue.yml@' "${CALLER}")"
  updated="$(grep --count --fixed-strings "renovate-failure-issue.yml@${NEW_SHA}  # v9.8.7" "${CALLER}")"
  [[ "${pins}" == 4 ]]
  [[ "${updated}" == "${pins}" ]]
  run grep --count --extended-regexp 'renovate-failure-issue\.yml@[0-9a-f]{40}' "${CALLER}"
  assert_output "${pins}"
}

@test "changes nothing else" {
  local -r before="${BATS_TEST_TMPDIR}/before"
  mkdir --parents "${before}"
  cp "${CONFIG}" "${CALLER}" "${before}/"
  run "${SCRIPT}" v9.8.7 "${NEW_SHA}" "${ROOT}"
  assert_success
  local file
  for file in renovate.json5 renovate-failure-issue.yml; do
    diff \
      <(sed --regexp-extended 's/#v[0-9]+\.[0-9]+\.[0-9]+/#vX/; s/@[0-9a-f]{40}  # v[0-9]+\.[0-9]+\.[0-9]+/@SHA  # vX/' "${before}/${file}") \
      <(sed --regexp-extended 's/#v[0-9]+\.[0-9]+\.[0-9]+/#vX/; s/@[0-9a-f]{40}  # v[0-9]+\.[0-9]+\.[0-9]+/@SHA  # vX/' "${ROOT}/examples/${file}")
  done
}

@test "exits 3 when already pinned" {
  run "${SCRIPT}" v9.8.7 "${NEW_SHA}" "${ROOT}"
  assert_success
  run "${SCRIPT}" v9.8.7 "${NEW_SHA}" "${ROOT}"
  assert_failure 3
}

@test "rejects malformed tag or sha and leaves the files untouched" {
  local -r good_sha="${NEW_SHA}"
  local -r snapshot="${BATS_TEST_TMPDIR}/snapshot"
  mkdir --parents "${snapshot}"
  cp "${CONFIG}" "${CALLER}" "${snapshot}/"
  local tag sha
  for tag in 'v1.2' '1.2.0' 'v1.2.0.' 'v1.2.0$' 'v1.2.0-rc.1'; do
    run "${SCRIPT}" "${tag}" "${good_sha}" "${ROOT}"
    assert_failure 1
  done
  for sha in "${good_sha:1}" "${good_sha^^}" "${good_sha}0" "${good_sha:0:39}g"; do
    run "${SCRIPT}" v1.2.0 "${sha}" "${ROOT}"
    assert_failure 1
  done
  cmp "${snapshot}/renovate.json5" "${CONFIG}"
  cmp "${snapshot}/renovate-failure-issue.yml" "${CALLER}"
}

@test "rejects a wrong argument count" {
  run "${SCRIPT}" v1.2.0
  assert_failure 1
}

@test "fails when the config has no pinned reference and writes nothing" {
  sed --in-place 's/#v[0-9.]*//' "${CONFIG}"
  local -r snapshot="${BATS_TEST_TMPDIR}/caller-before"
  cp "${CALLER}" "${snapshot}"
  run "${SCRIPT}" v9.8.7 "${NEW_SHA}" "${ROOT}"
  assert_failure 1
  cmp "${snapshot}" "${CALLER}"
}

@test "fails when the caller has no pinned reference" {
  sed --in-place 's/renovate-failure-issue\.yml@/renovate-failure-issue.yml#/' "${CALLER}"
  run "${SCRIPT}" v9.8.7 "${NEW_SHA}" "${ROOT}"
  assert_failure 1
}
