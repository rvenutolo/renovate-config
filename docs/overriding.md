# Overriding settings

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
