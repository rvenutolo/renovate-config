# Releasing

Releases are cut by [release-please](https://github.com/googleapis/release-please)
(`.github/workflows/release-please.yml`, `.release-please-config.json`,
`.release-please-manifest.json`).

1. On every push to `main`, release-please keeps one release PR open. It bumps
   the version from the conventional commits since the last release: `fix:` is a
   patch, `feat:` a minor, and `!` or a `BREAKING CHANGE:` footer a major. It
   also updates `CHANGELOG.md` and `version.txt`. Other types, including
   Renovate's `chore(deps)` updates to this repo's own tooling, cut no release.
2. Merging the release PR tags `vX.Y.Z` and publishes a GitHub release.
3. The examples PR (below) points `examples/` at the new release.
4. Consumers pick the release up through Renovate in their next window; this
   repo's own releases skip the release age.

release-please runs as a GitHub App, not with the workflow token: a PR opened by
the workflow token never triggers CI, so the required `ci-ok` check could never
pass. The app needs **Contents**, **Pull requests** and **Issues** read and
write, and is installed on this repository only. Its client ID is the repository
variable `RELEASE_APP_CLIENT_ID` and its private key the repository secret
`RELEASE_APP_PRIVATE_KEY`. The workflow also needs
`googleapis/release-please-action@*` in this repository's Actions allowlist.

## The examples PR

The files in `examples/` are copied verbatim into consuming repositories, so
they always point at the latest release: the `extends` line by tag, the
workflow's `uses:` lines by commit SHA with the tag in a trailing comment.
Renovate does not touch them in this repository; a release does, through a PR.

- **Opened.** When a release is created, `.github/workflows/release-please.yml`
  runs `scripts/examples-pr open`. It rewrites both files with
  `scripts/update-examples`, commits them to `chore/examples-vX.Y.Z` through the
  GitHub API as the release app (GitHub signs the commit, so the signature rule
  on `main` holds), opens a PR titled `chore: point examples at vX.Y.Z` and turns
  on auto-merge with the merge-commit method. The `chore:` type cuts no release.
  The PR is opened by the app so CI runs on it. Any older examples PR still open
  is closed and its branch deleted, since the new release supersedes it.
- **Retried by hand.** Re-running the release workflow does not retry the
  examples PR. Run the `release-please` workflow by hand with the tag
  (`gh workflow run release-please.yml -f tag=vX.Y.Z`) to open it or re-arm its
  auto-merge; an examples PR already open is not created twice.
- **Kept up to date.** `main` requires branches to be up to date, so on every
  run, after `open` when that runs, the same workflow runs
  `scripts/examples-pr refresh`, which merges `main` into an examples PR that
  has fallen behind (in a commit GitHub signs). CI reruns and auto-merge
  proceeds.
- **Failure issue.** `.github/workflows/examples-pr-failure.yml` opens an issue
  labeled `examples-pr-failure` when CI fails or times out on an examples PR, or
  comments on the issue already open for that PR. It closes the issue, with a
  note on whether the PR merged, when the PR closes.

`open` and `refresh` act only on PRs from a `chore/examples-` branch of this
repository that the release app opened; a PR opened by anyone else, a
maintainer included, is never touched. The failure-issue jobs have no author
check: they match any `chore/examples-` PR from this repository.

### Known gaps

- A CI run that fails at startup fires no `workflow_run` event, so a failed
  examples PR whose CI never started opens no issue. The PR stays open with
  auto-merge armed.
- The failure issue's open and close jobs are serialized separately. If the PR
  closes in the narrow window while a failure run is filing its issue, that
  issue can stay open and needs closing by hand.
- If updating the examples PR's branch fails (for example on a merge
  conflict), the release-please run fails on every push until the examples PR
  is fixed or closed by hand. The release itself is unaffected, because that
  step runs after release-please.
- The examples at a release tag show the previous release, because the tagged
  commit predates the release's own SHA. Copy the examples from `main`, never
  from a tag.
