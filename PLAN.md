# Issue #10: Add Semgrep SAST scanning job to central CI workflow

## DELIVERABLES

A third party can verify delivery by checking:

1. **Input**: `yq '.on.workflow_call.inputs["enable-semgrep"]' workflow.yml` shows `type: boolean`, `default: false`
2. **Job exists**: A `semgrep` job runs on `ubuntu-latest`, has `timeout-minutes`, and is conditional on `inputs.enable-semgrep`
3. **Nix invocation**: The semgrep job uses `determinate-nix-action` and invokes Semgrep via `nix run nixpkgs#semgrep`, not a third-party action
4. **Rule packs**: The invocation includes `--config p/default` and `--config p/owasp-top-ten`
5. **Artifact**: The job uploads a SARIF file via `actions/upload-artifact`
6. **Step summary**: The job writes a Markdown findings summary to `$GITHUB_STEP_SUMMARY`
7. **Failure**: The job exits non-zero on findings (no `|| true` suppression)
8. **Success wiring**: `success.needs` includes `semgrep`; `contains(needs.*.result, 'failure')` covers it
9. **Tests**: `tests/workflow-structure/test.sh` asserts deliverables 1, 2, 3, 4, 5, 8 structurally
10. **Docs**: `README.md` configuration table includes `enable-semgrep` with description and default
11. **Opt-out**: When `enable-semgrep` is not passed, the semgrep job is `skipped` and overall CI is unaffected
12. **`nix flake check` passes**

## PHASE 1: Implement Semgrep SAST job

### Chunk 1: Write structural tests (tests-first, must fail)

- [ ] Add tests to `tests/workflow-structure/test.sh` following the existing `pass`/`fail` pattern
- [ ] Add an `extract_semgrep_block` helper mirroring `extract_build_block`
- [ ] Tests to add:
  - `enable-semgrep` input is declared with `type: boolean` and `default: false`
  - A `semgrep` job exists in the workflow
  - `semgrep` job runs on `ubuntu-latest`
  - `semgrep` job has `timeout-minutes`
  - `semgrep` job has `if` condition referencing `inputs.enable-semgrep`
  - `semgrep` job has `security-events: write` permission (future-proofing for GHAS)
  - `semgrep` job block contains `determinate-nix-action`
  - `semgrep` job block contains `nixpkgs#semgrep`
  - `semgrep` job block contains `p/default` and `p/owasp-top-ten`
  - `semgrep` job block contains `upload-artifact`
  - `success` job `needs` includes `semgrep`
- [ ] Verify: run `test.sh` — all new tests FAIL, all existing tests still PASS

### Chunk 2: Implement workflow changes

- [ ] Add `enable-semgrep` boolean input (default `false`) to `workflow.yml` after `check-dev-shells`
- [ ] Add `semgrep` job between `build` and `success`:
  - `runs-on: ubuntu-latest`, `timeout-minutes: 15`
  - `if: ${{ inputs.enable-semgrep }}`
  - `permissions: { contents: read, security-events: write }`
  - Steps: checkout → determinate-nix-action → run `semgrep ci` via `nix run nixpkgs#semgrep` with `--config p/default --config p/owasp-top-ten --sarif --output semgrep.sarif` → parse SARIF to `$GITHUB_STEP_SUMMARY` via jq → upload-artifact for the SARIF file
- [ ] Add `semgrep` to `success.needs`
- [ ] Verify: run `test.sh` — all tests (old and new) PASS

### Chunk 3: Documentation + final check

- [ ] Add `enable-semgrep` row to the configuration table in `README.md`
- [ ] `nix run .#format-fix` then `nix flake check`
- [ ] Verify: `nix flake check` passes, README table includes the new row
