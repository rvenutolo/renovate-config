# Adopting renovate-config

Adopting the preset in a repository is: set the repository up, name its CI
workflow `ci`, and copy two files verbatim. Read [Prerequisites](#prerequisites)
first, then follow [Adopting it in a repo](#adopting-it-in-a-repo).

## Prerequisites

For each consuming repository:

- **Renovate app access.** The Renovate GitHub app must be installed on the
  repository.
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
- **Branch protection** requiring branches to be up to date before merging, and
  **auto-merge** enabled on the repository. The preset assumes both.
- **Dependabot alerts** turned on, which security-fix PRs depend on.
- **Workflow permissions.** The caller grants each job only what it needs; the
  `sweep` job adds `checks: read` and `statuses: read` to read each PR's CI
  state. Nothing needs changing in the repository's settings for these.
- **Repository activity.** GitHub disables scheduled workflows in a public
  repository after 60 days without activity, which would stop the sweep.
  Renovate's merges normally keep a repository active.
- **A CI workflow named exactly `ci`.** The failure-issue workflow reacts to
  runs of the workflow named in its `workflows: [ci]` line. Name the
  repository's CI workflow `ci` (the `name:` key of its workflow file) rather
  than editing that line, so the example stays a verbatim copy.

## Adopting it in a repo

Copy both files from the `main` branch, not from a release tag: the files at a
tag point at the release before it, while `main` points at the latest release.

1. Copy `examples/renovate.json5` to the repository root as `renovate.json5`,
   and delete any other Renovate config: `renovate.json`,
   `.github/renovate.json`, `.github/renovate.json5`, `.renovaterc`,
   `.renovaterc.json`, `.renovaterc.json5` or a `renovate` key in
   `package.json`. Renovate reads only the first config file it finds, so a
   leftover one can take precedence and the preset is never applied.
2. Copy `examples/renovate-failure-issue.yml` to
   `.github/workflows/renovate-failure-issue.yml`.
3. Add repo-specific settings under `packageRules` and elsewhere in
   `renovate.json5`. See [Overriding settings](overriding.md).

Both files are used as copied: they already point at the latest release (the
`extends` line by tag, the workflow's `uses:` lines by commit SHA with the tag
in a trailing comment). From then on Renovate keeps those pins current in the
consuming repository.

Always extend the preset with `github>`, never `local>`: Renovate can only bump
the tag of a pinned reference such as `github>rvenutolo/renovate-config#vX.Y.Z`.
