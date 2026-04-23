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
  cancel-in-progress: true

jobs:
  CI:
    uses: $YOURORG/ci/.github/workflows/workflow.yml@main
    permissions:
      contents: read
      id-token: write
```

<!-- prettier-ignore-start -->

> [!NOTE]
> `id-token: write` is required for FlakeHub Cache OIDC authentication.

<!-- prettier-ignore-end -->

...and you're done!
Replace `$YOURORG` with your GitHub organisation or user.

## Configuration options

| Parameter          | Description                                                                                                                                           | Default                                                                          |
| :----------------- | :---------------------------------------------------------------------------------------------------------------------------------------------------- | :------------------------------------------------------------------------------- |
| `enable-ssh-agent` | Whether to enable [`webfactory/ssh-agent`][ssh-agent] in the workflow. If you set this to `true` you need to supply a secret named `ssh-private-key`. | `false`                                                                          |
| `enable-lfs`       | Whether to enable Git LFS when checking out the repository. Set to `true` if your repository uses Git LFS for large files.                            | `false`                                                                          |
| `check-dev-shells` | Whether to validate devShells by running `nix develop --command true`. Set to `false` if your devShells are expensive or unavailable on some systems. | `true`                                                                           |
| `enable-security`  | Run the central security scan (gitleaks + trivy + semgrep + syft). Outputs SARIF to Code Scanning, summary to Actions, SBOM to Dependency graph.      | `false`                                                                          |
| `directory`        | The root directory of your flake.                                                                                                                     | `.`                                                                              |
| `fail-fast`        | Whether to cancel all in-progress jobs if any matrix job fails                                                                                        | `true`                                                                           |
| `runner-map`       | A custom mapping of [Nix system types][nix-system] to desired Actions runners                                                                         | `{ "aarch64-darwin": "macos-arm64-nix-darwin", "x86_64-linux": "x86_64-linux" }` |

## Example configurations

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

#### Private SSH keys

Configure an SSH agent with a secret private key for private repository support.

```yaml
jobs:
  CI:
    uses: $YOURORG/ci/.github/workflows/workflow.yml@main
    permissions:
      contents: read
      id-token: write
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
    with:
      fail-fast: false
```

#### Security scanning

Opt in to the central security scan by passing `enable-security: true`. This runs:

- [**gitleaks**](https://github.com/gitleaks/gitleaks) — secret detection against the working tree
- [**trivy**](https://github.com/aquasecurity/trivy) — dependency CVEs + secrets + misconfig
- [**semgrep**](https://semgrep.dev/) — SAST (`p/default` + `p/owasp-top-ten` rulesets)
- [**syft**](https://github.com/anchore/syft) — SBOM generation (CycloneDX + SPDX)

Findings surface in three places:

- **Code Scanning tab** — SARIF from every scanner, one row per finding, annotations in PR diffs
- **Actions job summary** — markdown table of findings per scanner
- **Workflow artifacts** — SBOM (CycloneDX + SPDX) uploaded as `security-sbom`, 30-day retention

```yaml
jobs:
  CI:
    uses: Cambridge-Vision-Technology/ci/.github/workflows/workflow.yml@main
    permissions:
      contents: read
      id-token: write
      actions: read # required for SARIF upload to Code Scanning
      security-events: write
    with:
      enable-security: true
```

Developers run the same scanner locally from any repo root:

```bash
nix run github:Cambridge-Vision-Technology/ci#security-scan
```

Outputs land in `./out/security/` (SARIF, SBOM, summary).

##### Handling false positives

Inline markers (preferred — co-located with the code):

```javascript
// rationale: AWS documentation example credentials; non-functional placeholders.
// nosemgrep
AWS_ACCESS_KEY_ID: "AKIAIOSFODNN7EXAMPLE", // gitleaks:allow
```

File-based ignores at repo root (`.gitleaksignore`, `.semgrepignore`, `.trivyignore`) — each
entry **must** be preceded by a `# rationale:` comment. CI fails if any entry lacks one:

```
# .gitleaksignore
# rationale: historical recorded API responses, already rotated
abc123def456:path/to/file.json:generic-api-key:42
```

## Notes

This workflow uses Determinate Nix (`DeterminateSystems/determinate-nix-action`) with FlakeHub Cache for binary caching, along with `actions/checkout` and `webfactory/ssh-agent`.

[nix]: https://zero-to-nix.com
[nix-system]: https://zero-to-nix.com/concepts/system-specificity
[runners]: https://docs.github.com/en/actions/using-github-hosted-runners
[runners-large]: https://docs.github.com/en/actions/using-github-hosted-runners/using-larger-runners/about-larger-runners
[runners-large-macos]: https://docs.github.com/en/actions/using-github-hosted-runners/using-larger-runners/about-larger-runners#about-macos-larger-runners
[ssh-agent]: https://github.com/webfactory/ssh-agent
[workflow-access]: https://docs.github.com/en/actions/sharing-automations/reusing-workflows#using-self-hosted-runners
