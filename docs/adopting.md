# Adopting renovate-config

Adopting the preset in a repository is one walkthrough: install the app, set
the repository up, name its CI workflow `ci`, and copy two files verbatim.

## Adopting it in a repo

1. **Install the Renovate GitHub app** on the repository.
2. **Set up the repository.**
   - **Actions allowlist.** If the repository restricts allowed actions, the
     list must include:
     - `rvenutolo/renovate-config/.github/workflows/renovate-failure-issue.yml@*`
     - `step-security/harden-runner@*`
     - `actions/checkout@*`, or the "Allow actions created by GitHub" setting,
       which allows every `actions/*` action

     An action outside the allowlist makes a workflow fail at startup.

   - **Branch protection** requiring branches to be up to date before merging,
     and **auto-merge** enabled on the repository. The preset assumes both.
   - **Dependabot alerts** turned on, which security-fix PRs depend on.
   - **Access to this repo.** The reusable workflow checks out this repository
     with the caller's token to fetch its script, so this repository must stay
     public (or be readable by every consumer).
   - **Workflow permissions.** The caller grants each job only what it needs;
     the `sweep` job adds `checks: read` and `statuses: read` to read each PR's
     CI state. Nothing needs changing in the repository's settings for these.
   - **Repository activity.** GitHub disables scheduled workflows in a public
     repository after 60 days without activity, which would stop the sweep.
     Renovate's merges normally keep a repository active.

3. **Name the repository's CI workflow exactly `ci`** (the `name:` key of its
   workflow file). The failure-issue workflow reacts to runs of the workflow
   named in its `workflows: [ci]` line; renaming the CI workflow, rather than
   editing that line, keeps the example a verbatim copy.
4. **Delete any other Renovate config:** `renovate.json`,
   `.github/renovate.json`, `.github/renovate.json5`, `.renovaterc`,
   `.renovaterc.json`, `.renovaterc.json5` or a `renovate` key in
   `package.json`. Renovate reads only the first config file it finds, so a
   leftover one can take precedence and the preset is never applied. Also
   delete any regex manager of the repository's own that reads `# renovate:`
   comments in `.github/workflows/`: the preset already matches them (see
   [What the preset does](preset.md)), and two managers on the same lines
   produce duplicate updates.
5. **Copy both examples from the `main` branch**, not from a release tag (the
   files at a tag point at the release before it), and use them verbatim:
   - `examples/renovate.json5` to the repository root as `renovate.json5`
   - `examples/renovate-failure-issue.yml` to
     `.github/workflows/renovate-failure-issue.yml`

   They already point at the latest release: the `extends` line by tag, the
   workflow's `uses:` lines by commit SHA with the tag in a trailing comment.
   From then on Renovate keeps those pins current in the consuming repository.

6. **Add repo-specific settings** under `packageRules` and elsewhere in
   `renovate.json5`. See [Overriding settings](overriding.md).

Always extend the preset with `github>`, never `local>`: Renovate can only bump
the tag of a pinned reference such as `github>rvenutolo/renovate-config#vX.Y.Z`.
