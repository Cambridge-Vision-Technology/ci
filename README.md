# Nix CI

Your one-stop shop for effortless [Nix] CI in GitHub Actions.

- Automatically builds on all the architectures your flake supports.
- Runs `nix flake check` on every platform in your runner map.

## Usage

Create an Actions workflow in your project at `.github/workflows/ci.yml`, copy in this text...

```yaml
on:
  pull_request:
  workflow_dispatch:
  push:
    branches:
      - main
      - master
    tags:
      - v?[0-9]+.[0-9]+.[0-9]+*

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

jobs:
  CI:
    uses: $YOURORG/ci/.github/workflows/workflow.yml@main
    permissions:
      contents: read
      pages: write
      id-token: write
```

<!-- prettier-ignore-start -->

> [!IMPORTANT]
> All three permissions are required, including for callers without documentation.
> `contents: read` lets the job check out your repository.
> `id-token: write` is required **now**, even though the credential source today is a GitHub App secret rather than OIDC: only the *caller* can grant OIDC, and a reusable workflow can never hold more permission than the workflow that called it.
> Granting it up front means the move to an STS (DEV-753) does not force a second organisation-wide sweep of every call site.
> `pages: write` grants the separate private documentation publication job. GitHub validates reusable-workflow permissions before runtime app detection; a no-app skip cannot bypass this validation.

<!-- prettier-ignore-end -->

...and you're done!
Replace `$YOURORG` with your GitHub organisation or user.

## Private documentation publication

The standard reusable workflow owns documentation generation, artifact transfer
and publication. The sole content opt-in is `apps.<system>.docs` on the first
system in the runner map. The repository owns the generator and its content
checks. `nix run .#docs` must generate a fresh static site at `.out/docs/`,
relative to `directory`. It must not publish, provision hosting, change site
visibility or start a preview server. Keep optional preview/PDF commands separate.
CI is renderer-neutral; the canonical template uses Inkwell. Do not copy a
publisher workflow, add a publisher manifest or pass output-directory settings.

If the app is absent, CI explicitly skips generation/publication, even with an
existing `.out/docs/`. Evaluation failures fail the build rather than masquerade
as absence. A present app runs once, after successful local build gates on the
selected system. Failed generation or missing/empty/unsafe output fails the
gate. The artifact needs a usable `index.html` and ordinary files/directories,
not links, devices, sockets or Git metadata. Publish only intended documentation,
never fixtures, recordings, secrets or patient data.

The selected job retains the pinned shared tooling source without Git metadata,
removes its temporary checkout, and completes authentication/LFS/SSH setup before
evaluating the consumer. No-app callers do not fetch the tooling's private
inputs. Detection uses the Git-tracked flake source, not ignored output or local
configuration files. Generation keeps the existing 60-minute build-job cap; its subprocess
also has a 60-minute ceiling and a 16 MiB captured-output buffer limit.
Toolchain builds/downloads are not reported as scenario execution time.

PRs retain `documentation-RUN_ID-RUN_ATTEMPT` for seven days without replacing
the live site. A successful default-branch push publishes only the exact retained
site after all build jobs succeed. The binding records repository, source
revision, run/attempt, shared-workflow identity, selected system and every file's
SHA-256. Download uses the producer's artifact ID; verification precedes the
Pages archive upload. Content is not rebuilt during deployment.

Owners must separately enable a workflow-built **private** Pages site associated
with their own repository, using the necessary GitHub Enterprise capability.
Restrict `github-pages` to the default branch and do not configure caller
concurrency to cancel a default-branch deployment. CI checks `public=false` and
`build_type=workflow`; a missing/denied/public site is a named setup blocker.
It never creates a site, changes protections or falls back to public Pages.
GitHub can initially return an HTTP metadata URL for a private `*.pages.github.io`
site while its HTTPS endpoint already works. CI validates that metadata and uses
only the corresponding HTTPS URL, with certificate verification. It does not
request HTTP or change the HTTPS-enforcement setting. Anonymous HTTPS access must
produce a recognizable authentication redirect before creation and after actual
deployment success. The private Pages `/pages/auth` handoff additionally needs
the `x-pages-private: 1` marker and exactly one Location header. Public responses,
unavailable TLS, lookalike routes, ambiguous headers or a changed site fail closed.
The evidence retains GitHub's raw returned page URL; the environment link uses
the validated HTTPS target. The returned deployment ID is logged before evidence
recording so recording failures do not hide the operation needed for recovery.
Docs-enabled callers need authorized read access to the shared tooling's private
`purs-nix` and `purescript-platform` inputs and their locked dependencies; use
the existing organization-read capability or authorized SSH access. The publisher
uses only the caller's Pages/OIDC authority, not the read App token.

Deployments are serialized per repository without cancelling an active deploy.
The publisher validates GitHub's required returned deployment ID (string or exact
integer), constructs status requests for that ID within the known repository,
and never follows the returned status URL as a routing instruction. It does not
guess an ID from the run or revision. It polls that actual operation, rechecks
private configuration/target URL and requires a
recognizable GitHub authentication redirect for unauthenticated HTTPS access.
Network errors and public responses cannot report success. A failed or uncertain
operation is a blocker: reconcile the recorded deployment and last verified
artifact before retrying or advancing another publication. A Git revert does not
restore or remove hosted content. The owner separately signs in and verifies the
intended rendering; API/denial checks do not prove that human observation.
Publication is neither specification approval nor automated acceptance.
The retained record also binds producer/Pages artifact IDs, the binding-file
digest and last observed deployment status. Documented file-sync, Pages-update
and CDN-purge states continue polling. `deployment_attempt_error` gets bounded
status-read retries without another creation request; exhaustion, terminal
failure or an unknown state fails verification. OIDC request authorization and
the deployment JWT use stdin transport, not credential-bearing argv.
The producer's run attempt is part of the binding. After reconciling a failed
publication, rerun the full workflow to generate a current-attempt artifact;
a failed-job-only rerun must not reuse an artifact from an older attempt.

All reusable-workflow callers must grant `contents: read`, `pages: write` and
`id-token: write`, even with no docs app. GitHub validates grants before runtime
conditions. The approved rollout accepts visible startup failures until
[DEV-1183](https://linear.app/aykua/issue/DEV-1183) supplies the caller grants;
that organization-wide sweep starts immediately after this shared capability
merges. A passing granted no-docs smoke caller does not prove every unswept caller
is compatible. Wider generator migrations are separate work.

The template pilot uses pre-merge local/fixture rejection checks and PR artifact
generation. No pre-merge hosted deployment has been exercised. First hosted
publication and real access verification occur after the approved template merge;
human authenticated rendering review remains a separate acceptance gate.

## Organization read access

`enable-org-read-access` declares a **capability**, not a credential.
You state that the job needs to read this organisation's repositories; this workflow decides how to obtain that.
Today it mints a short-lived GitHub App installation token limited to `contents: read`.
The mechanism can change without your workflow changing, which is why the input is named for what you need rather than for how it is satisfied.

The contract is an **environment side effect, not an output**: after the authentication step, `git` and `nix` can read organisation repositories — private flake inputs over `git+ssh://`, `git+https://` and `github:` URLs, and their Git LFS objects.
Nothing hands a token back to you, and no token-minting logic belongs in your repository.

```yaml
jobs:
  CI:
    uses: $YOURORG/ci/.github/workflows/workflow.yml@main
    permissions:
      contents: read
      pages: write
      id-token: write
    with:
      enable-org-read-access: true
    secrets:
      github-app-id: ${{ secrets.CI_FETCH_APP_ID }}
      github-app-private-key: ${{ secrets.CI_FETCH_APP_PRIVATE_KEY }}
```

The secret names are yours to choose; this repository never hard-codes them.

Forwarding the two App secrets is **temporary and optional**.
They are declared `required: false` and stay that way permanently, so callers that do not enable the capability never supply them.
They can be dropped from every call site once the token source moves to an STS (DEV-753) — at that point the job derives its own credential from its OIDC identity, and `enable-org-read-access` does not change.

<!-- prettier-ignore-start -->

> [!WARNING]
> `enable-github-app-auth` exists as a deprecated alias for `enable-org-read-access`, on the reusable workflow only — it was never published on the setup action.
> It will be removed only after the organisation-wide sweep of call sites (DEV-760), because this workflow is consumed at `@main` by roughly 27 repositories and an undeclared input is a startup failure for every call site still passing it.
> New code must use `enable-org-read-access`.

<!-- prettier-ignore-end -->

### Narrowing the scope

`org-read-repositories` is **optional**, and leaving it unset is the supported default.
Unset, the job can read **every repository in your organisation** — exactly what enabling the capability has always meant, so no existing call site changes.

Set it when the job's private dependencies are a known, fixed list, and you would rather it could not read anything else:

```yaml
jobs:
  CI:
    uses: $YOURORG/ci/.github/workflows/workflow.yml@main
    permissions:
      contents: read
      pages: write
      id-token: write
    with:
      enable-org-read-access: true
      org-read-repositories: nix-shared, infra-base
    secrets:
      github-app-id: ${{ secrets.CI_FETCH_APP_ID }}
      github-app-private-key: ${{ secrets.CI_FETCH_APP_PRIVATE_KEY }}
```

Names are comma- or newline-separated, and each is either `repository` or `owner/repository` where the owner must be your own organisation.
The input is named for the **scope of the access**, not for the mechanism: a token, an STS trust policy (DEV-753) and every plausible successor all express scope as a list of repositories, so narrowing survives the mechanism moving.

Leave it unset when the list is not knowable in advance — a flake whose inputs change, or a repository that pulls in transitive private inputs it does not name.
A narrowed job that reaches for a repository outside the list fails at fetch time with a `404`, which reads as "repository not found" rather than as a permission error.

<!-- prettier-ignore-start -->

> [!TIP]
> Narrowing is worth the maintenance only where the dependency list is stable.
> If you find yourself editing `org-read-repositories` every time a flake input moves, the honest configuration is the organisation-wide default.

<!-- prettier-ignore-end -->

## Choosing a surface

Three surfaces expose the same capability. Pick the smallest one that fits.

| Surface                          | Use when                                                                                                                                                                          |
| :------------------------------- | :-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.github/workflows/workflow.yml` | Your CI is shaped like a flake check — build every system in the runner map and run `nix flake check`. This is the reusable workflow the rest of this README describes.           |
| `setup/action.yml`               | A bespoke job that needs the same setup — authentication, Nix, optional ssh-agent, optional LFS — but is not shaped like a flake check. For example a `tofu plan` job.            |
| `auth/action.yml`                | Any job that needs credentials only, including a self-hosted job that manages its own checkout and Nix. This is what makes pasting a token-mint block into your repo unnecessary. |

All three take `enable-org-read-access` and its optional `org-read-repositories` narrowing, and run the same `auth/authenticate.sh` implementation, at the revision you selected in `uses:`.
Only `auth/action.yml` exposes an output, `org-read-token`, as an escape hatch for tools it cannot configure — `gh`, for instance, reads neither the git credential helper nor Nix's `netrc-file`.
Prefer the environment side effect.

```yaml
env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true

jobs:
  index:
    runs-on: [self-hosted, Linux, X64]
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: actions/checkout@v4
      - uses: $YOURORG/ci/auth@main
        with:
          enable-org-read-access: "true"
          github-app-id: ${{ secrets.CI_FETCH_APP_ID }}
          github-app-private-key: ${{ secrets.CI_FETCH_APP_PRIVATE_KEY }}
```

<!-- prettier-ignore-start -->

> [!IMPORTANT]
> A job on `[self-hosted, Linux, X64]` must set `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` at **workflow** level — the top-level `env:` block, as above — or `actions/create-github-app-token` will not run on that runner at all.

> [!IMPORTANT]
> Check out **before** the `auth` action, as above, and never after it.
> `actions/checkout` leaves a credential in the checked-out repository that can read that one repository and nothing else, and Nix reads a remote HEAD from the working directory, so it would answer 404 for every other repository in the organisation.
> With `enable-org-read-access` the action clears that credential; a checkout that runs afterwards puts it back.
> Your own repository stays reachable either way — `git`, `git lfs` and submodule updates authenticate through the credential helper the action installs.

<!-- prettier-ignore-end -->

## Runner requirements

Every runner must have **Nix 2.35.0 or newer**.
Below that floor Nix builds a malformed Git LFS endpoint and GitHub answers HTTP 422 before it evaluates any credential, so LFS objects cannot be fetched over the token path.

The floor is hard-coded on all three surfaces and is never an input, so a caller cannot lower it.
The guard fails the job on every platform, with no warning-only mode and no per-platform exemption, naming the runner, the version found and the version required.
GitHub-hosted runners already satisfy it — when no `nix` is present the workflow installs it from a pinned `cachix/install-nix-action`.
Self-hosted runners keep whatever Nix they already have, so they have to be upgraded in their own configuration repository.
The standalone `auth` action skips the check when `nix` is not on `PATH`, because it configures credentials and never installs Nix.

## Git LFS

Set `enable-lfs: true` when your own repository stores files in Git LFS.

LFS objects belonging to flake **inputs** are a separate path: Nix implements the LFS protocol itself and cannot call a git credential helper, so it is authenticated by a `netrc-file` while the `git` binary is authenticated by a credential helper.
Both point at job-scoped files under `$RUNNER_TEMP` at mode `600`.
An input marked `?lfs=1` therefore needs no SSH key — only `enable-org-read-access` and a runner meeting the Nix floor above.

## Configuration options

| Parameter                | Description                                                                                                                                                                                  | Default                                                                          |
| :----------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------- |
| `enable-org-read-access` | Whether the job may read every repository in your organisation, including private flake inputs and their Git LFS objects. Requires the `github-app-id` and `github-app-private-key` secrets. | `false`                                                                          |
| `enable-github-app-auth` | **Deprecated** alias for `enable-org-read-access`, on this workflow only. Removed only after the organisation-wide sweep of call sites (DEV-760); use `enable-org-read-access`.              | `false`                                                                          |
| `org-read-repositories`  | **Optional.** Comma- or newline-separated `repository` or `owner/repository` names the organisation read access is confined to. Empty means every repository in your organisation.           | `""` (organisation-wide)                                                         |
| `enable-ssh-agent`       | **Deprecated**, still accepted. Whether to enable [`webfactory/ssh-agent`][ssh-agent] in the workflow. If you set this to `true` you need to supply a secret named `ssh-private-key`.        | `false`                                                                          |
| `enable-lfs`             | Whether to enable Git LFS when checking out the repository. Set to `true` if your repository uses Git LFS for large files.                                                                   | `false`                                                                          |
| `check-dev-shells`       | Whether to validate devShells by running `nix develop --command true`. Set to `false` if your devShells are expensive or unavailable on some systems.                                        | `true`                                                                           |
| `directory`              | The root directory of your flake.                                                                                                                                                            | `.`                                                                              |
| `fail-fast`              | Whether to cancel all in-progress jobs if any matrix job fails                                                                                                                               | `true`                                                                           |
| `runner-map`             | A custom mapping of [Nix system types][nix-system] to desired Actions runners                                                                                                                | `{ "aarch64-darwin": "macos-arm64-nix-darwin", "x86_64-linux": "x86_64-linux" }` |

## Example configurations

### Job-scoped binary caches

The optional `nix-substituters` string replaces the space-separated binary cache
URLs for this job's Nix commands. Empty (the default) leaves the runner's caches
unchanged. For example, `nix-substituters: https://cache.nixos.org/` avoids an
unavailable private cache without changing the runner's persistent configuration.

The workflow appends this setting only to the mode-600 job-private Nix file
created by authentication, before the flake check and devShell validation. It
preserves the authentication settings and inherited user/system files. It does
not add trusted keys or trusted-substituters; selected caches must already be
permitted by the runner's existing trust policy. Supply cache URLs as trusted
workflow configuration, never credentials or untrusted event text. This does not
raise the job deadline or change failure gating. Removing the input restores
normal cache selection on the next job.

The sections below show configurations for some common use cases.

### Advanced usage

#### GitHub Actions Runners

##### Default runners

By default, the CI maps the Nix systems to the org's self-hosted runners:

|                                                   | macOS (Apple Silicon)                      | x86 Linux                        |
| ------------------------------------------------- | ------------------------------------------ | -------------------------------- |
| Flake `system` (Nix build platform)               | `aarch64-darwin`                           | `x86_64-linux`                   |
| [GitHub Actions Runner][runners] (workflow label) | `macos-arm64-nix-darwin` (org self-hosted) | `x86_64-linux` (org self-hosted) |

##### Custom runners

You can override the defaults by providing a custom runner map.
For example, this runner map uses a [larger GitHub-hosted runner for macOS][runners-large-macos]:

```yaml
jobs:
  CI:
    uses: $YOURORG/ci/.github/workflows/workflow.yml@main
    permissions:
      contents: read
      id-token: write
      pages: write
    with:
      runner-map: |
        {
          "aarch64-darwin": "macos-latest-xlarge"
        }
```

> [!TIP]
> Using `macos-latest-large` is currently the only way to run _current_ macOS on Intel architecture.

You can also use GitHub-hosted runners or [larger Ubuntu runners][runners-large] with bespoke specs (for example, 64 CPUs, 128GB RAM) by providing the appropriate labels in your runner map.

> [!IMPORTANT]
> Shared workflows such as the one used in this repo [can only access][workflow-access] self-hosted runners if the workflow repo (this one) is owned by the same organisation or user.
> To use this repo with your own self-hosted runners, fork the repository and point the `uses` line at your fork.
>
> This limitation does not apply to GitHub-hosted runners.

#### Private SSH keys (deprecated)

Configure an SSH agent with a secret private key for private repository support.

`enable-ssh-agent` and the `ssh-private-key` secret are **deprecated but still supported**.
They remain declared and optional, and existing callers keep working.
Prefer `enable-org-read-access`, which reaches the same repositories over HTTPS and also serves Git LFS.
Removal happens only after the organisation-wide sweep of `SSH_KEY_PRIVATE` call sites (DEV-760), so new code should not use them.

```yaml
jobs:
  CI:
    uses: $YOURORG/ci/.github/workflows/workflow.yml@main
    permissions:
      contents: read
      id-token: write
      pages: write
    with:
      enable-ssh-agent: true
    secrets:
      ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}
```

#### Continue on failure

By default, if any build in the matrix fails, the workflow will cancel all remaining in-progress jobs.
You can change this behavior by setting `fail-fast` to `false`:

```yaml
jobs:
  CI:
    uses: $YOURORG/ci/.github/workflows/workflow.yml@main
    permissions:
      contents: read
      id-token: write
      pages: write
    with:
      fail-fast: false
```

## Notes

The workflow preserves an existing machine Nix installation. Its machine-level
Attic substituters, trusted keys, daemon settings, and Nix version remain
authoritative. When a runner has no `nix` command, the workflow installs
upstream Nix with `cachix/install-nix-action`. It also uses `actions/checkout`
and optionally `webfactory/ssh-agent`.

[nix]: https://zero-to-nix.com
[nix-system]: https://zero-to-nix.com/concepts/system-specificity
[runners]: https://docs.github.com/en/actions/using-github-hosted-runners
[runners-large]: https://docs.github.com/en/actions/using-github-hosted-runners/using-larger-runners/about-larger-runners
[runners-large-macos]: https://docs.github.com/en/actions/using-github-hosted-runners/using-larger-runners/about-larger-runners#about-macos-larger-runners
[ssh-agent]: https://github.com/webfactory/ssh-agent
[workflow-access]: https://docs.github.com/en/actions/sharing-automations/reusing-workflows#using-self-hosted-runners
