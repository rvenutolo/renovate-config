{
  description = "renovate-config — shared Renovate preset — devShell and formatter";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    systems.url = "github:nix-systems/default";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    bats-support = {
      url = "github:bats-core/bats-support";
      flake = false;
    };
    bats-assert = {
      url = "github:bats-core/bats-assert";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      systems,
      treefmt-nix,
      bats-support,
      bats-assert,
    }:
    let
      eachSystem = f: nixpkgs.lib.genAttrs (import systems) (system: f nixpkgs.legacyPackages.${system});
      treefmtEval = eachSystem (pkgs: treefmt-nix.lib.evalModule pkgs ./.treefmt.nix);
      # nixpkgs' unstable-version convention, derived from the input's own
      # lastModifiedDate so a Renovate bump of flake.lock relabels the store path
      # too. A hardcoded date silently goes stale on the first bump.
      unstableVersion =
        input:
        let
          d = input.lastModifiedDate;
        in
        "0-unstable-${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}";
    in
    {
      formatter = eachSystem (pkgs: treefmtEval.${pkgs.stdenv.hostPlatform.system}.config.build.wrapper);

      checks = eachSystem (pkgs: {
        formatting = treefmtEval.${pkgs.stdenv.hostPlatform.system}.config.build.check self;
      });

      devShells = eachSystem (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            # formatters (also wired into treefmt)
            shfmt
            prettier
            yamlfmt
            nixfmt
            taplo
            # linters
            shellcheck
            yamllint
            markdownlint-cli2
            editorconfig-checker
            typos
            actionlint
            # zizmor audits the workflows for SECURITY where actionlint audits
            # them for syntax and expression validity -- injection sinks,
            # over-broad permissions, credential persistence, environment-file
            # writes. They overlap nowhere, which is why both are here.
            #
            # Unlike `renovate` below, which lists no x86_64-darwin in
            # meta.platforms and so keeps this devShell off Intel Macs, zizmor
            # evaluates on every system in the `systems` input, aarch64-darwin
            # included: it costs this devShell no platform.
            zizmor
            # the standard nix linters, both invoked by
            # .ci/run-lint-checks. nixfmt formats these files but says nothing
            # about what they contain: statix catches antipatterns (a repeated
            # `programs.` key, for one) and deadnix catches unused bindings and
            # arguments.
            statix
            deadnix
            # commitlint is invoked by .githooks/commit-msg. Without it here,
            # check-devshell-provides fails AND every git commit dies in the
            # commit-msg hook once activate-githooks has run.
            commitlint
            # renovate, here only for its `renovate-config-validator` binary,
            # which .ci/run-lint-checks runs over the Renovate configs. Without
            # it a malformed config is not a CI failure: Renovate simply stops
            # opening dependency PRs, silently and forever. Note the cost --
            # nixpkgs' renovate lists no x86_64-darwin in meta.platforms, so
            # this devShell does not evaluate on an Intel Mac.
            renovate
            # tests / runtime
            # withLibraries, not bare bats: the wrapper exports BATS_LIB_PATH at
            # its own share/bats, so common.bash can bats_load_library and a bats
            # that is not this one fails loudly instead of silently missing them.
            (bats.withLibraries (l: [
              # From flake INPUTS pinned in flake.lock, not the nixpkgs releases:
              # nixpkgs ships bats-assert 2.1.0, which lacks assert_stderr.
              (l.bats-support.overrideAttrs (_: {
                src = bats-support;
                version = unstableVersion bats-support;
              }))
              (l.bats-assert.overrideAttrs (_: {
                src = bats-assert;
                version = unstableVersion bats-assert;
              }))
            ]))
            jq
            # tests/workflows.bats reads the workflow YAML with yq. yq-go has no
            # JSON5 reader, so the json5 package's `pyjson5` reads
            # .github/renovate.json5 for the same tests.
            yq-go
            python3Packages.json5
            git
            just
            # nix.out, NOT a bare `nix`. This package's default output is `dev`,
            # which has no bin/ at all, so a bare `nix` puts nothing on the
            # shell's PATH and the gates silently run whatever nix the host
            # ships, which need not be the locked version. .out is what makes
            # the pinned nix the one that actually runs inside the shell.
            nix.out
            coreutils
            findutils
            gnugrep
          ];

          # Activate the tracked git hooks for this clone. As a manual per-clone
          # step this silently never happens; the devShell is the one place
          # onboarding cannot skip. Tolerant of failure on purpose.
          shellHook = ''
            if hooks_repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
              "$hooks_repo_root/.ci/activate-githooks" \
                || echo 'warning: could not activate tracked git hooks' >&2
            fi
          '';
        };
      });
    };
}
