# renovate-config

Shared [Renovate](https://docs.renovatebot.com/) preset, plus a reusable
GitHub Actions workflow that files an issue when CI fails on a Renovate PR,
when a Renovate PR is still stuck open after the weekly update window, and when
Renovate reports problems on its Dependency Dashboard.

The preset is `default.json`. Consuming repositories extend it with one line,
pinned to a release tag.

## What the preset does

- **Weekend window.** Updates are proposed from Friday 6pm to Sunday 6pm
  (America/New_York). The window spans the whole weekend because each merge
  leaves the remaining PRs behind `main`, and only a Renovate run rebases them,
  so a week's chain needs about one run per PR. The hosted app runs each repo
  about every 4 hours, which gives the window roughly 12 runs. Nothing touches a
  Renovate branch outside the window, except security fixes and a manual rebase
  request (the PR's rebase checkbox): a PR that fails CI waits until it is fixed
  or until the next window.
- **Lock-file maintenance** runs Saturday 6pm to Sunday 6pm, so the lock file is
  regenerated once, on top of most of the week's merged updates.
- **One batch, separate majors.** Every non-major update (minor, patch, pin,
  digest and similar) goes into a single PR named "all non-major dependencies".
  Each major update gets its own PR. To batch majors too:
  - for every consumer, add `major` to the batch rule's `matchUpdateTypes` in
    this repo's `default.json` and cut a release;
  - for one repo, add a later local `packageRules` entry with
    `matchPackageNames: ['*']`, `matchUpdateTypes: ['major']`,
    `groupName: 'all non-major dependencies'` and
    `groupSlug: 'all-non-major'`.
- **Automerge.** Every update type, majors included, merges through GitHub
  auto-merge once CI is green. Branches are rebased whenever they fall behind
  the base branch. There are no PR count limits inside the window.
- **Security fixes** ignore the schedule, the batch and the release age: each
  gets its own PR right away and automerges. They rely on Dependabot alerts
  being enabled for the repo.
- **Release age.** A release must be 7 days old before it is proposed. An
  update whose source publishes no release timestamp, as is common for
  digests, is not held: it is proposed without waiting. Some updates are
  exempt: lock-file maintenance, pins, replacements, bumps, rollbacks and
  lock-file updates have no release to wait for; and this preset's own releases
  (`rvenutolo/renovate-config`) skip the wait so they reach consumers in the
  next window.
- **Dependency Dashboard** stays on as the overview of pending and held updates.
- **Config migration PRs are off.** They come from a separate code path that
  can ignore the schedule and automerge. A needed migration shows up as a
  Dependency Dashboard checkbox instead.
- **Conventional commits.** Commit messages and PR titles look like
  `chore(deps): ...`, and PRs carry the `dependencies` label.
- **Nix.** `flake.lock` inputs are updated.

The preset extends `config:best-practices` and still sets every behavior above
explicitly, so an upstream change to that preset cannot silently alter one. The
reasons for each setting are in the `description` fields of `default.json`.

### Failure issues

When CI fails on a Renovate PR, the reusable workflow
`.github/workflows/renovate-failure-issue.yml` files one issue for that PR. The
issue is labeled `dependencies` and `renovate-failure` and contains:

- a link to the PR and the list of updates in it
- a link to the failed run and the names of the failed jobs
- the last 150 lines of each failed job's log, with ANSI color codes removed
  (shortened further if the issue would exceed GitHub's size limit)
- how to land a fix

A run with conclusion `failure` or `timed_out` counts as a failure; `cancelled`
is ignored. If a job's log cannot be fetched, the issue is
still filed, with a note in that job's section.

Job-log downloads redirect to numbered Azure Blob hosts, which is why the
workflow's egress policy allows `*.blob.core.windows.net:443`.

Emails are kept to a minimum:

- A repeat failure of the same PR edits the existing issue (body and title)
  and does not comment.
- When the PR closes, merged or not, the issue records the outcome and closes
  without a comment. It closes as completed if the PR merged and as not planned
  otherwise.
- A failed run that is processed after its PR closed files nothing and closes
  the PR's issue the same way, so the issue ends up closed whichever run comes
  last.
- GitHub emails when an issue opens and may email when it closes, so expect one
  or two emails per breakage, per stuck PR, and per new set of Dashboard
  problems.

Issues are only filed for PRs from branches of the same repository, never for
fork PRs.

Runs that file or update issues are serialized per Renovate branch by a
concurrency group on the caller's `open` job, so parallel failures cannot file
duplicate issues. The `close` job has no group: a group keeps only one pending
run, and a newer event would replace a pending close.

### Stuck PRs

Once a week, after the update window, the caller's `sweep` job looks for
Renovate PRs that should have merged but did not. It runs on Monday at 14:17
UTC (9:17am EST, 10:17am EDT), set by the cron `17 14 * * 1` in the caller.
A consumer may change it, along with the same string in the `sweep` job's `if:`;
the sweep can also be run by hand from the Actions tab.

A PR counts as stuck when it is open, its branch is a `renovate/*` branch of
the same repository, it is not a draft, GitHub auto-merge is still enabled on
it, and it was opened at least 12 hours earlier. A PR taken off auto-merge on
purpose is never reported.

Each stuck PR gets one issue, with the same labels as a failure issue and a
title of the form `Renovate PR #12 is stuck: ...`. The issue contains:

- a link to the PR and the list of updates in it
- when the PR was opened and when the sweep looked
- the CI state of the PR's head commit (passing, pending, failing or none)
- GitHub's mergeable state for the PR, such as `behind` or `dirty`
- whether Renovate reported an artifact update problem on the PR
- how to unstick it

A PR that already has a failure issue is skipped. A sweep that finds the PR
still stuck rewrites its issue without a comment; if CI later fails on the PR,
the same issue becomes its failure issue. The sweep also closes, without a
comment, every issue whose PR has closed (covering a missed `close` run) and
every stuck issue whose PR no longer counts as stuck. A stuck issue closed by
hand while its PR stays stuck is filed again by the next sweep.

### Repository problems

Some Renovate failures leave no PR to attach an issue to. A failed
`nix flake update`, for example, leaves nothing to commit, so Renovate only
lists the error on its Dependency Dashboard issue. Every Sunday at 19:47 UTC
(2:47pm EST, 3:47pm EDT), set by the cron `47 19 * * 0`, the caller's
`problems` job reads the Dashboard and files one issue for the whole
repository, titled `Renovate reports problems in this repository`, with the
same labels as the other issues.

It counts three things on the Dashboard: the "Repository Problems" list, the
block naming dependencies Renovate failed to look up, and the "Errored"
updates. Pending, scheduled, blocked and informational lists are not problems.
Renovate's text is copied into a code block, so nothing in it renders as a
mention or a link.

Renovate only lists a problem tied to a schedule, such as a lock-file update,
on runs inside that schedule; outside it the problem drops off the Dashboard.
So the issue follows the Dashboard only inside the lock-file maintenance
window, Saturday 6pm to Sunday 6pm New York time, which is why the check runs
on Sunday afternoon, hours before the window closes:

- Problems listed: the issue is created, or rewritten without a comment when
  the problems change.
- No problems listed: the issue closes.
- A run outside the window (by hand) can create the issue but never rewrites
  or closes it.

Closing the issue by hand silences exactly the problems it listed: the next
check files a new issue only if the list has changed. If the Dashboard is
turned off or closed, an open problems issue closes.

The check depends on a few settings the preset makes:

- The Dependency Dashboard must stay enabled, under its default title
  `Dependency Dashboard` (the preset pins it).
- `suppressNotifications: ["dependencyLookupWarnings"]` hides the
  lookup-failure block from the Dashboard, and so from the issue.
- A consumer that moves `lockFileMaintenance.schedule` still gets closes only
  inside the preset's window, and should keep the Sunday cron inside the
  window too.

## Adopting it in a repo

1. Copy `examples/renovate.json5` to the repository root as `renovate.json5`,
   and delete any other Renovate config: `renovate.json`,
   `.github/renovate.json`, `.github/renovate.json5`, `.renovaterc`,
   `.renovaterc.json`, `.renovaterc.json5` or a `renovate` key in
   `package.json`. Renovate reads only the first config file it finds, so a
   leftover one can take precedence and the preset is never applied.
2. Copy `examples/renovate-failure-issue.yml` to
   `.github/workflows/renovate-failure-issue.yml`.
3. Set the version. The examples carry placeholders (`#v0.0.0`, and an
   all-zero SHA with `# v0.0.0`), so replace them when copying: use the latest
   release tag in the `extends` line, and in both `uses:` lines of the workflow
   that release's commit SHA with the tag in a trailing comment. Take the SHA of
   the commit the tag points to, which also holds if the tag is annotated:

   ```bash
   git rev-parse 'vX.Y.Z^{commit}'
   ```

   From then on Renovate keeps the pins current in the consumer. (Only in this
   repo's own `examples/` does Renovate replace the placeholders, after the
   first release.)

4. In the workflow, change `workflows: [ci]` to the name of the repository's
   own CI workflow.
5. Add repo-specific settings under `packageRules` and elsewhere in
   `renovate.json5`.

Always extend the preset with `github>`, never `local>`: Renovate can only bump
the tag of a pinned reference such as `github>rvenutolo/renovate-config#vX.Y.Z`.

## Overriding settings

Rules in a consumer's own `packageRules` come after the preset's, and a later
rule wins.

- **Release age:** override it in a `packageRules` entry, never as a top-level
  `minimumReleaseAge`. `config:best-practices` contains a `packageRules` entry
  that sets a release age, and a top-level value loses to it.

  ```json5
  packageRules: [
    {
      matchPackageNames: ['some-package'],
      minimumReleaseAge: '14 days',
    },
  ],
  ```

- **Opt a package out of the batch:** give it its own `groupName` in a local
  rule, or a different `groupName` to put it in another group.
- **Anything else** (automerge, labels, schedule) can be overridden by setting
  the same key in the consumer's `renovate.json5`. The lock-file maintenance
  schedule is a separate key, `lockFileMaintenance.schedule`; overriding
  `schedule` alone leaves lock-file maintenance on Saturday and Sunday.

## Prerequisites

For each consuming repository:

- **Actions allowlist.** If the repository restricts allowed actions, the list
  must include:
  - `rvenutolo/renovate-config/.github/workflows/renovate-failure-issue.yml@*`
  - `step-security/harden-runner@*`
  - `actions/checkout@*`, or the "Allow actions created by GitHub" setting,
    which allows every `actions/*` action

  An action outside the allowlist makes a workflow fail at startup.

- **Access to this repo.** The reusable workflow checks out this repository with
  the caller's token to fetch its script, so this repository must stay public
  (or be readable by every consumer).
- **Renovate app access.** The Renovate GitHub app must be installed on the
  repository.
- **Branch protection** requiring branches to be up to date before merging, and
  **auto-merge** enabled on the repository. The preset assumes both.
- **Dependabot alerts** turned on, which security-fix PRs depend on.
- **Workflow permissions.** The caller grants each job only what it needs; the
  `sweep` job adds `checks: read` and `statuses: read` to read each PR's CI
  state. Nothing needs changing in the repository's settings for these.
- **Repository activity.** GitHub disables scheduled workflows in a public
  repository after 60 days without activity, which would stop the sweep.
  Renovate's merges normally keep a repository active.

## Releasing

Releases are cut by [release-please](https://github.com/googleapis/release-please)
(`.github/workflows/release-please.yml`, `release-please-config.json`,
`.release-please-manifest.json`).

1. On every push to `main`, release-please keeps one release PR open. It bumps
   the version from the conventional commits since the last release: `fix:` is a
   patch, `feat:` a minor, and `!` or a `BREAKING CHANGE:` footer a major. It
   also updates `CHANGELOG.md` and `version.txt`. Other types, including
   Renovate's `chore(deps)` updates to this repo's own tooling, cut no release.
2. Merging the release PR tags `vX.Y.Z` and publishes a GitHub release.
3. Consumers pick the release up through Renovate in their next window; this
   repo's own releases skip the release age. In this repo's `examples/`, Renovate
   replaces the placeholder tag and SHA after the first release.

release-please runs as a GitHub App, not with the workflow token: a PR opened by
the workflow token never triggers CI, so the required `ci-ok` check could never
pass. The app needs **Contents**, **Pull requests** and **Issues** read and
write, and is installed on this repository only. Its client ID is the repository
variable `RELEASE_APP_CLIENT_ID` and its private key the repository secret
`RELEASE_APP_PRIVATE_KEY`. The workflow also needs
`googleapis/release-please-action@*` in this repository's Actions allowlist.

## Known gaps

- An artifact error on a PR that does open gets no issue of its own. For a
  manager whose package file still changes, Renovate opens the PR with an
  artifact-problem comment and does not list it on the Dashboard. If the PR
  stays open, its stuck issue notes the comment; if CI passes and it merges,
  nothing is reported. (A failed `nix flake update`, which leaves no PR, is
  reported by the Sunday problems issue.)
- A CI run that fails at startup, such as one using an action outside the
  Actions allowlist, fires no `workflow_run` event, so it gets no failure issue.
  The PR stays open with auto-merge armed, and the next sweep files a stuck
  issue for it.

## Development

The dev shell supplies every tool.

| Task            | Command                              | Shortcut     |
| --------------- | ------------------------------------ | ------------ |
| Enter the shell | `nix develop`                        |              |
| All checks      | `./.ci/in-devshell ./run-all-checks` | `just check` |
| BATS suite      | `./.ci/in-devshell ./run-tests`      | `just test`  |
| Format          | `nix fmt`                            | `just fmt`   |
| Activate hooks  | `./.ci/activate-githooks`            | `just hooks` |

Inside `nix develop`, run `./run-all-checks` and `./run-tests` directly.
`just` is an optional convenience; nothing requires it.
