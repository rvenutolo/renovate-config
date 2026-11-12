# renovate-config

Shared [Renovate](https://docs.renovatebot.com/) preset, plus a reusable
GitHub Actions workflow that files an issue when CI fails on a Renovate PR.

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
- **Release age.** A release must be 7 days old before it is proposed. Some
  updates are exempt: lock-file maintenance, pins, replacements, bumps,
  rollbacks and lock-file updates have no release to wait for; digests are
  allowed to have no release timestamp; and this preset's own releases
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
- the tail of each failed job's log
- how to land a fix

A run with conclusion `failure`, `timed_out` or `startup_failure` counts as a
failure; `cancelled` is ignored. If a job's log cannot be fetched, the issue is
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
  or two emails per breakage.

Issues are only filed for PRs from branches of the same repository, never for
fork PRs.

Runs that file or update issues are serialized per Renovate branch by a
concurrency group on the caller's `open` job, so parallel failures cannot file
duplicate issues. The `close` job has no group: a group keeps only one pending
run, and a newer event would replace a pending close.

## Adopting it in a repo

1. Copy `examples/renovate.json5` to the repository root as `renovate.json5`.
2. Copy `examples/renovate-failure-issue.yml` to
   `.github/workflows/renovate-failure-issue.yml`.
3. Set the version. The examples carry placeholders (`#v0.0.0`, and an
   all-zero SHA with `# v0.0.0`), so replace them when copying: use the latest
   release tag in the `extends` line, and in both `uses:` lines of the workflow
   that release's commit SHA with the tag in a trailing comment. From then on
   Renovate keeps the pins current in the consumer. (Only in this repo's own
   `examples/` does Renovate replace the placeholders, after the first tag.)
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
  - `actions/*`
  - `step-security/harden-runner`

  An action outside the allowlist makes a workflow fail at startup.

- **Access to this repo.** The reusable workflow checks out this repository with
  the caller's token to fetch its script, so this repository must stay public
  (or be readable by every consumer).
- **Renovate app access.** The Renovate GitHub app must be installed on the
  repository.
- **Branch protection** requiring branches to be up to date before merging, and
  **auto-merge** enabled on the repository. The preset assumes both.
- **Dependabot alerts** turned on, which security-fix PRs depend on.

## Releasing

Releases are tagged by hand.

1. On `main`, run `./.ci/in-devshell ./run-all-checks` (or `just check`) and
   make sure it passes.
2. Create a signed tag and push it:

   ```bash
   git tag --sign vX.Y.Z
   git push origin vX.Y.Z
   ```

3. Consumers pick the release up through Renovate in their next window; this
   repo's own releases skip the release age. In this repo's `examples/`, Renovate
   replaces the placeholder tag and SHA after the first tag.

## Known gaps

- Renovate artifact errors, such as a failed `nix flake update`, appear only as
  Renovate's own PR comment and on the Dependency Dashboard. No issue is filed.
- A Renovate PR that is green but never merges is not detected.
- That a `startup_failure` run fires `workflow_run: completed` is not confirmed
  by GitHub's documentation. The caller's `if:` accepts it, but a startup
  failure may produce no issue.

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
