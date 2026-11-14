# What the preset does

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
- **pre-commit.** Hook `rev:` values in `.pre-commit-config.yaml` are updated,
  including SHA pins with a version comment. Renovate ships this manager
  disabled, so the preset turns it on; it does nothing in a repo without that
  file.
- **Tool pins in workflows.** A tool a workflow installs by version is updated
  when it is annotated like this:

  ```yaml
  env:
    # renovate: datasource=github-release-attachments depName=mvdan/sh
    SHFMT_VERSION: v3.13.1
    SHFMT_SHA256: fb096c5d1ac6beabbdbaa2874d025badb03ee07929f0c9ff67563ce8c75398b1
  ```

  The comment names the datasource and package, and may end with
  `versioning=<scheme>`. The `<NAME>_VERSION:` line must come directly after
  it; its value may be quoted. The `<NAME>_SHA256:` line is optional and must
  come directly after the version line. With it and the
  `github-release-attachments` datasource, Renovate updates the version and the
  sha256 together, so the download stays verified. A sha256 separated from its
  version by any other line is ignored.

The preset extends `config:best-practices` and still sets every behavior above
explicitly, so an upstream change to that preset cannot silently alter one. The
reasons for each setting are in the `description` fields of `default.json`.
