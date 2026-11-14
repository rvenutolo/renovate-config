# Development

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
