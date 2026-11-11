---
project:
  name: "ci"
  tags: ["general", "nix", "ci"]
  description: "Shared Nix CI workflow for GitHub Actions"
---

# Nix CI

Shared reusable GitHub Actions workflow for Nix projects. Automatically builds on all architectures your flake supports and runs `nix flake check` on every platform in your runner map.

## Architecture

- `.github/workflows/workflow.yml` — the reusable workflow (called by consumer repos)
- `.github/workflows/validate.yml` — self-validation CI for this repo
- `tests/` — existing contract tests run through Nix checks
- `tools/CI/Docs/` — PureScript documentation generation/publication and focused checks

## Testing

Preserve the existing shell contracts. Write new logic and checks in PureScript.
Run focused named checks during development. The final committed candidate must
pass `nix flake check` before independent review and publication.

# CI Repo Guidance

## Workflow Inputs

The reusable workflow accepts these inputs: `enable-ssh-agent`, `directory`, `fail-fast`, `runner-map`, `enable-lfs`, `check-dev-shells`. The `runner-map` input is a JSON object mapping nix system names to GitHub runner labels.

## Test Structure

Existing shell contracts under `tests/*/test.sh` remain executable references.
Documentation CLI/mechanism checks live in `tools/CI/Docs/`, with narrow inputs
declared in `tools/inputs.json`. `tests/documentation/` holds the workflow schema;
`tests/docs-smoke/` is the real PR artifact fixture. Use the named
`docs-generation`, `docs-publication`, `docs-workflow` and source/lint checks.
Do not add test logic to shell scripts or weaken their retained assertions.

## Formatting

Use `prettier` for YAML/JSON/Markdown formatting. Use `actionlint` for workflow linting. Both are available in the devshell.
