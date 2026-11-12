import { createRequire } from "node:module";
import { delimiter } from "node:path";

// The preset is loaded here, not named in parserPreset, so its parser options
// can be built with issuePrefixes overridden. A parserPreset.parserOpts object
// in config does not merge into this preset: the preset exports its options
// from a function, which the config merge replaces wholesale, leaving the
// parser on a default header pattern with no `!?` that rejects `feat!: x`.
//
// The preset is resolved from NODE_PATH only, which the nix commitlint wrapper
// points at its own node_modules, so it is always the one the running
// commitlint bundles. A plain require would search every node_modules above
// this file first, and a stray copy there would silently win. Without
// NODE_PATH, or without the preset in it, this throws instead of linting
// against something else.
const NODE_PATH = process.env.NODE_PATH;
if (!NODE_PATH) {
  throw new Error(
    "commitlint.config.mjs: NODE_PATH is unset; run the devShell commitlint",
  );
}
const require = createRequire(import.meta.url);
const presetPath = require.resolve(
  "conventional-changelog-conventionalcommits",
  {
    paths: NODE_PATH.split(delimiter),
  },
);
const createPreset = require(presetPath).default;

export default {
  extends: ["@commitlint/config-conventional"],
  parserPreset: {
    // The parser reads any `#N` followed by more text, on a body line after
    // the first, as an issue reference that opens the footer, so a body that
    // cites an issue mid-paragraph trips footer-leading-blank. A prefix no
    // commit ever writes turns reference parsing off. An empty list would be
    // simpler but also stops the rule catching a real `BREAKING CHANGE:`
    // footer with no blank line above it; this form keeps that.
    parserOpts: createPreset({ issuePrefixes: ["#ref-never-used-"] }).parser,
  },
  rules: {
    // Bodies routinely carry long paths, URLs and code fences that cannot be
    // wrapped at 100 chars. Subject-length checks remain in effect.
    "body-max-line-length": [0, "always", Infinity],
  },
};
