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

> [!NOTE] > `id-token: write` is required for FlakeHub Cache OIDC authentication.

...and you're done!
Replace `$YOURORG` with your GitHub organisation or user.

## Configuration options

| Parameter          | Description                                                                                                                                           | Default                                                                                                      |
| :----------------- | :---------------------------------------------------------------------------------------------------------------------------------------------------- | :----------------------------------------------------------------------------------------------------------- |
| `enable-ssh-agent` | Whether to enable [`webfactory/ssh-agent`][ssh-agent] in the workflow. If you set this to `true` you need to supply a secret named `ssh-private-key`. | `false`                                                                                                      |
| `enable-lfs`       | Whether to enable Git LFS when checking out the repository. Set to `true` if your repository uses Git LFS for large files.                            | `false`                                                                                                      |
| `directory`        | The root directory of your flake.                                                                                                                     | `.`                                                                                                          |
| `fail-fast`        | Whether to cancel all in-progress jobs if any matrix job fails                                                                                        | `true`                                                                                                       |
| `runner-map`       | A custom mapping of [Nix system types][nix-system] to desired Actions runners                                                                         | `{ "aarch64-darwin": "macos-latest", "x86_64-linux": "ubuntu-latest", "aarch64-linux": "ubuntu-24.04-arm" }` |

## Example configurations

The sections below show configurations for some common use cases.

### Advanced usage

#### GitHub Actions Runners

##### Standard and larger runners

By default, the CI maps the Nix systems to their equivalent GitHub-hosted runners:

|                                                   | macOS (Apple Silicon)                | ARM Linux                            | x86 Linux                   |
| ------------------------------------------------- | ------------------------------------ | ------------------------------------ | --------------------------- |
| Flake `system` (Nix build platform)               | `aarch64-darwin`                     | `aarch64-linux`                      | `x86_64-linux`              |
| [GitHub Actions Runner][runners] (workflow label) | `macos-latest` (using Apple Silicon) | `ubuntu-24.04-arm` (using ARM Linux) | `ubuntu-latest` (using x86) |

##### Non-standard runners

You can also use several types of non-standard runners by providing a custom runner map.
For example, this runner map enables the [larger GitHub runners for macOS][runners-large-macos]:

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

The other two types of runners are those provisioned on your own infrastructure, and [larger Ubuntu (not macOS) runners][runners-large] with bespoke specs (for example, 64 CPUs, 128GB RAM) hosted by GitHub.
Confusingly, GitHub sometimes refers to both of these as "self-hosted" runners.

> [!IMPORTANT]
> Shared workflows such as the one used in this repo [can only access][workflow-access] non-standard runners if the workflow repo (this one) is owned by the same organisation or user.
> To use this repo with non-standard runners, fork the repository and point the `uses` line at your fork.
>
> This limitation does not apply to larger macOS runners hosted by GitHub.

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

## Notes

This workflow uses Determinate Nix (`DeterminateSystems/determinate-nix-action`) with FlakeHub Cache for binary caching, along with `actions/checkout` and `webfactory/ssh-agent`.

[nix]: https://zero-to-nix.com
[nix-system]: https://zero-to-nix.com/concepts/system-specificity
[runners]: https://docs.github.com/en/actions/using-github-hosted-runners
[runners-large]: https://docs.github.com/en/actions/using-github-hosted-runners/using-larger-runners/about-larger-runners
[runners-large-macos]: https://docs.github.com/en/actions/using-github-hosted-runners/using-larger-runners/about-larger-runners#about-macos-larger-runners
[ssh-agent]: https://github.com/webfactory/ssh-agent
[workflow-access]: https://docs.github.com/en/actions/sharing-automations/reusing-workflows#using-self-hosted-runners
