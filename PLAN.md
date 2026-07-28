# DEV-759: Central organization read authentication

Linear: https://linear.app/aykua/issue/DEV-759/ci-own-ci-credential-acquisition-capability-named-auth-forwards

## CURRENT STATUS

pr_implementation_status: NOT_STARTED
live_acceptance_status: NOT_APPLICABLE
current_phase: PHASE 1
current_chunk: CHUNK 1.1
valid_phases: PHASE 1
next_pr_action: Implement the standalone auth action and update the existing structural contracts
next_post_merge_action: none

## DELIVERABLES

A reviewer can verify completion as follows:

1. `workflow.yml`, `setup/action.yml`, and the standalone auth action expose the mechanism-neutral `enable-org-read-access` capability. The existing `enable-github-app-auth` input remains as a deprecated alias.
2. App credential secrets remain optional. Callers that enable neither organization access nor SSH authentication keep the current repository-token behavior.
3. `auth/action.yml` is the only implementation that selects or creates a token, configures Git and Nix credentials, removes stale rewrites, and adds the three required SSH-to-HTTPS rewrites.
4. `workflow.yml` and `setup/action.yml` delegate to the auth action at the same repository revision as the workflow or action that the consumer selected.
5. A GitHub-hosted manual probe uses App credentials without an SSH key to clone private `infra-base` and resolve private `nix-shared` through its `git+ssh://` flake URL.
6. A self-hosted manual probe performs the same operations through the standalone auth action without using the setup action.
7. Credential files have mode `600`. The App token is limited to `contents: read`. The private key and token are not printed or uploaded.
8. The existing setup and workflow structural suites cover the new inputs, delegation, stale rewrite removal, all three rewrite forms, and the absence of duplicate acquisition logic.
9. The README documents `contents: read` and `id-token: write` as caller permissions, the preferred capability input, temporary optional App-secret forwarding, and the deprecated alias.
10. Maintenance must converge on this standalone action instead of retaining a second acquisition implementation. Changes to the maintenance repository remain under DEV-754 and DEV-760.

## CONSTRAINTS

- Preserve default behavior because organization consumers use this repository at `@main`.
- Keep the current App-secret path in this issue. DEV-753 can later prefer OIDC and OpenBao inside the auth action without consumer changes.
- Do not put token-minting logic in consumer repositories.
- Use the called workflow and action identity to load the selected CI revision. Do not silently delegate to a different `main` revision during pull-request validation or from pinned consumers.
- Keep the official App-token action pinned to its current v3.2.0 commit and request read-only contents permission.
- Use the existing structural suites. Do not add a new automated behavioral test suite.
- Use manual, read-only GitHub Actions probes for behavior that requires real App credentials and private repositories.

## PHASE 1 — Centralize authentication and verify it in GitHub Actions

This phase is one PR-executable unit and leaves the shared workflow ready for immediate use.

### CHUNK 1.1 — Implement the shared authentication contract

Create the standalone auth composite and make the reusable workflow and setup action delegate to it. Add the capability input and deprecated alias. Preserve repository-token, checkout, LFS, Nix installation, and optional SSH-agent defaults.

Update the existing setup and workflow structural suites alongside the implementation. Require the standalone ownership boundary, optional secrets, exact-revision delegation, stale rewrite removal, and these rewrite forms:

- `git@github.com:`
- `ssh://git@github.com/`
- `git+ssh://git@github.com/`

Completion evidence:

- The existing structural suites pass.
- Source search finds one App-token acquisition implementation.
- Source search finds no independent credential-writing or rewrite implementation in setup or workflow.
- A default call does not mint an App token or add SSH rewrites.

### CHUNK 1.2 — Add documentation and manual probes

Update the README with the stable capability contract and caller permissions. State that callers must grant `id-token: write` now even though the first acquisition source is the App secret.

Extend the existing `workflow_dispatch` validation path with manual-only, read-only probes. Keep these probes skipped during normal pull-request CI:

- Run the reusable workflow with organization access on GitHub-hosted Linux.
- Run the setup action with organization access on GitHub-hosted Linux.
- Run the standalone auth action on the self-hosted Linux runner without setup.
- Clone private `infra-base` and resolve private `nix-shared` through `git+ssh://` with App credentials and no SSH key.

Completion evidence:

- Normal pull-request validation still exercises the unchanged default path without App credentials.
- A manual dispatch against the PR branch passes all three organization-access paths.
- The Actions run contains no private key, installation token, or credential artifact.
- Each manual probe finishes within ten minutes.

### CHUNK 1.3 — Run the release gates

Format and validate the complete change, then record the manual Actions run in the pull request.

Completion evidence:

- Prettier passes.
- Actionlint passes.
- All existing shell contract tests pass.
- `nix flake check` passes.
- The normal pull-request checks pass.
- The pull request links to the successful manual probe run.

## POST-MERGE ACCEPTANCE

No separate live acceptance step is required. The manual probe runs the exact branch revision in GitHub Actions before merge, and normal push validation remains the detector for the published `main` revision.
