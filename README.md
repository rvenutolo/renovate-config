# renovate-config

Shared [Renovate](https://docs.renovatebot.com/) preset, plus a reusable
GitHub Actions workflow that files an issue when CI fails on a Renovate PR,
when a Renovate PR is still stuck open after the weekly update window, and when
Renovate reports problems on its Dependency Dashboard.

The preset is `default.json`. Consuming repositories extend it with one line,
pinned to a release tag.

## Documentation

- [Adopting it in a repo](docs/adopting.md): prerequisites and the start-to-finish walkthrough.
- [What the preset does](docs/preset.md): the preset's behavior and why.
- [Failure issues](docs/issues.md): failure issues, stuck PRs, repository problems and known gaps.
- [Overriding settings](docs/overriding.md): changing the preset in a consuming repo.
- [Releasing](docs/releasing.md): how releases are cut and how the examples follow them.
- [Development](docs/development.md): working on this repo.
