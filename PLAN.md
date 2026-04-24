# Plan: Authenticate git CLI on runner to avoid GitHub rate-limiting (#14)

## DELIVERABLES

A reviewer with no knowledge of the implementation can verify completion by checking that:

1. **Unconditional authentication step.** `.github/workflows/workflow.yml` contains a step (e.g. `Authenticate git / Nix to github.com`) that runs on *every* invocation of the reusable workflow — i.e. it is **not** guarded by `if: ${{ inputs.enable-lfs }}`.
2. **`~/.netrc` is written for the git subprocess.** The step produces a `~/.netrc` (mode 600) containing `machine github.com`, `login x-access-token`, and the value of `${{ github.token }}` as password.
3. **`/tmp/netrc` is written for Nix.** The step produces `/tmp/netrc` (mode 600) with the same credentials, and Nix is configured via `netrc-file = /tmp/netrc` (existing wiring preserved).
4. **Git credential helper is configured.** The step sets `git config --global credential.helper store` and writes `https://x-access-token:<token>@github.com` to `~/.git-credentials` (preserving existing LFS behavior).
5. **No `http.extraHeader` regression.** The workflow does not set `git config --global http.extraHeader` (already CLAUDE.md guidance — a regression guard).
6. **End-to-end: downstream flake check succeeds.** blackbriar#222 (the PR that exposed the rate-limit symptoms) passes `nix flake check` on x86_64-linux when pinned against this branch of `ci`, demonstrating the authenticated path works for transitive `builtins.fetchGit` calls (purs-nix et al.). Existing tests (`workflow-structure`, `runner-map-transform`) remain green.

---

## PHASE 1 — Authenticate git CLI and Nix to github.com

Single phase; ~half a day total. One developer.

### CHUNK 1 — Add failing BDD-style workflow assertions ✅ **Done.**

> Note: required a preparatory commit (`3142f77`) to remove obsolete flakehub-cache-action assertions that predated the auth work — those failures were unrelated to #14 and were dropped because flakehub-cache-action was intentionally removed in `0df45d0`.

**Extend `tests/workflow-structure/test.sh`** — do NOT create a new `tests/authenticate-github/` directory. `workflow-structure` is already the home for workflow-YAML contract assertions (step existence, regression guards, step-config checks). A new directory duplicates the `nix flake check` derivation wiring and slows the test suite for no gain.

Add these assertions to `tests/workflow-structure/test.sh`:

- A step named `Authenticate git / Nix to github.com` (or equivalent) **exists**.
- That step has **no `if:` condition** referencing `enable-lfs`.
- That step's `env` includes `GITHUB_TOKEN: ${{ github.token }}`.
- That step's `run` block writes `${HOME}/.netrc`, `/tmp/netrc`, `~/.git-credentials`, and sets `credential.helper store`.
- The old conditional step `Configure credentials for LFS` no longer exists (or has been renamed and ungated).
- Regression guard: no `http.extraHeader` is set globally anywhere in the workflow. (Note: the existing `Clean up stale git extraHeader config` step that *unsets* stale config must be preserved — assert presence, not absence.)

Run `nix flake check` and confirm the new assertions fail. Commit red tests.

### CHUNK 2 — Implement the unconditional auth step ✅ **Done.**

> Note: `~/.git-credentials` is now always written, not just when `enable-lfs: true`. Intentional widening (previously the file was only written under the LFS gate).

Modify `.github/workflows/workflow.yml` to replace `Configure credentials for LFS` with an unconditional `Authenticate git / Nix to github.com` step matching the sketch in the issue. Fold the now-redundant `Create netrc for Nix` bootstrap step into the new step (the new step unconditionally writes `/tmp/netrc` itself, so the bootstrap is dead code — per CLAUDE.md "delete code; don't comment out"). Preserve:

- The existing `Clean up stale git extraHeader config` step (regression guard for self-hosted runners carrying stale config from a previous workflow version).
- The `netrc-file = /tmp/netrc` wiring to `determinate-nix-action`.
- The existing `git-lfs` install + `Ensure LFS files are checked out` steps (gated on `enable-lfs`).

The new step's `run` block must start with `set -euo pipefail` (CLAUDE.md shell-safety rule; existing steps in this workflow are inconsistent here — the new step should not repeat that lapse).

The plan's statement "preserving existing LFS behavior" is slightly misleading: removing the `enable-lfs` guard means `~/.git-credentials` is now always written. That is the intended widening, not regression — call it out in the commit message.

Run `nix run .#format-fix` then `nix flake check` — new tests + existing tests all green. Commit.

### CHUNK 3 — Live verification via blackbriar#222 ✅ **Done.**

> Note: blackbriar#222 auto-merged with the temporary `@issue-14-authenticate-git-cli` pin in place while verification was running, so `blackbriar/main` briefly pointed at this branch. Revert PR opened as blackbriar#227. Verification run: https://github.com/Cambridge-Vision-Technology/blackbriar/actions/runs/24876784289

Push branch; the draft PR's own validate.yml runs end-to-end on x86_64-linux and aarch64-darwin runners — confirm green.

Then point blackbriar#222 at this branch (temporarily change its `uses:` reference to `Cambridge-Vision-Technology/ci/.github/workflows/workflow.yml@issue-14-authenticate-git-cli`) and re-run its failing `nix flake check`. Success there — specifically, the previously failing transitive `github.com/purescript/*` and `github.com/id3as/*` clones completing without 5xx / TCP drops — is the primary live-fire evidence the fix works. Revert the blackbriar branch reference before merging this PR (the consumer will pick the fix up via `@main`).

---

**Notes for the developer:**

- Tests here are workflow-YAML contract tests — that's the "user-observable surface" of a reusable workflow. Dynamic runner behavior is proven by the live CI run on the PR itself + blackbriar#222.
- Do not add backward-compat shims. Just replace the step.
- Keep the commit sequence: red test → implementation → green.
