# Failure issues, stuck PRs and repository problems

## Failure issues

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

## Stuck PRs

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

## Repository problems

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
