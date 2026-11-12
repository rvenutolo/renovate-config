# Run the full local verification gate
check:
    ./.ci/in-devshell ./run-all-checks

# Run the BATS suite
test *ARGS:
    ./.ci/in-devshell ./run-tests {{ ARGS }}

# Format every file via treefmt
fmt:
    nix fmt

# Activate the tracked git hooks for this clone
hooks:
    ./.ci/activate-githooks
