# DEV-759: Central organization read authentication

Linear: https://linear.app/aykua/issue/DEV-759/ci-own-ci-credential-acquisition-capability-named-auth-forwards

## CURRENT STATUS

pr_implementation_status: COMPLETE — PHASE 0 fully complete (CHUNKS 0.1 and 0.2) and PHASE 1 complete (CHUNKS 1.1 through 1.5), including the 2026-07-30 credential-audit redesign and the 2026-07-31 legacy-artifact self-heal; all gates green (490 assertions, prettier, actionlint, `nix flake check`, pull-request checks, and a manual probe dispatch in which ALL THREE probes and the credential audit passed). PR #23 remains a DRAFT awaiting human review and MUST STAY DRAFT
live_acceptance_status: NOT_APPLICABLE
current_phase: PHASE 1
current_chunk: CHUNK 1.5
valid_phases: PHASE 0, PHASE 1
next_pr_action: HUMAN TAKEOVER. The PR is ready for a human to review and land; it must remain a DRAFT until a human undrafts it. No agent work remains. Both GitHub-side gates are closed on head `03d657e` — pull-request checks all green (run 30610386952), and manual probe dispatch 30610388212 green on all three probes plus `probe-log-credential-audit`. THE MERGE BLOCKER IS CLEARED: the CHUNK 1.2 minimum-Nix guard was the only blocker, and `macos-arm64-nix-darwin` now passes it (CHUNK 0.2 landed on the host 2026-07-31). No darwin consumer will be red on merge. Merging remains time-sensitive for the credential leak — every consumer still on `ci@main` keeps re-writing the five credential artifacts onto self-hosted runners, observed live on BOTH dell-foo and admins-mac-mini on 2026-07-31 by jobs this workstream did not launch. The leak stops only when this lands on `main`
next_post_merge_action: Merge `ci-runner-mac` PR #17. See the CAVEAT in CHUNK 0.2 — the mac is deployed from an unmerged branch and a deploy-rs push from `main` would revert it to Determinate and re-break the guard

## DELIVERABLES

A reviewer can verify completion as follows:

1. Every runner in the runner map runs Nix >= 2.35.0, and CI fails fast with a named-runner error message if one does not.
2. `workflow.yml`, `setup/action.yml`, and the standalone auth action expose the mechanism-neutral `enable-org-read-access` capability. The existing `enable-github-app-auth` input remains as a deprecated alias on `workflow.yml` only.
3. App credential secrets remain optional. Callers that enable neither organization access nor SSH authentication keep the current repository-token behavior.
4. `auth/authenticate.sh` is the only implementation that writes credentials, installs URL rewrites, and configures Nix credential settings. Token minting stays a pinned action step on each surface.
5. `workflow.yml` and `setup/action.yml` invoke that single script at the same repository revision as the workflow or action the consumer selected.
6. A GitHub-hosted manual probe uses App credentials without an SSH key to clone private `infra-base`, resolve private `nix-shared` through its `git+ssh://` flake URL, and fetch an LFS-bearing input.
7. A self-hosted manual probe performs the same operations through the standalone auth action without using the setup action.
8. Credential files live under `$RUNNER_TEMP`, have mode `600`, and are removed when the job ends. The App token is limited to `contents: read`. The private key and token are not printed or uploaded.
9. Exactly one credential mechanism is written. All three `insteadOf` rewrite forms are installed, and only the `ssh://git@github.com/` form is documented as load-bearing.
10. The existing setup and workflow structural suites cover the new inputs, delegation, stale rewrite cleanup, the rewrite forms and which one is load-bearing, the minimum-Nix guard, and the absence of duplicate credential-writing logic.
11. The README documents `contents: read` and `id-token: write` as caller permissions, the preferred capability input, the deprecated alias and its removal trigger, LFS being served by the token path, and the deprecation — not removal — of `enable-ssh-agent`.
12. NOT A RELEASE GATE FOR THIS PR. Maintenance convergence on this shared implementation (read path only, pinned by SHA, write path separate) is a later DEV-754/DEV-760 step. See CONSTRAINTS for the current interim divergence.

## CONSTRAINTS

### Nix credential mechanics (verified against Nix 2.34.8 / 2.35.1 source)

- Nix shells out to the `git` binary for `git+https` and `git+ssh` flake input fetches. Global git config — `credential.helper`, `url.*.insteadOf`, `http.extraHeader` — is therefore inherited by Nix for normal, non-LFS fetches.
- CORRECTED 2026-07-30, live-verified by the manual probe run (actions/runs/30540398070). The earlier claim here — "only global and system git config apply; `actions/checkout` writes local `.git/config`, which Nix never reads" — is FALSE, and was true only of the fetch. Nix makes TWO git calls per flake input and they do not read the same configuration. The fetch runs as `git fetch -C <nix cache directory>`, outside the workspace, so it ignores local config and does use the global credential helper. The HEAD read (`readHead`) runs `git ls-remote --symref <url>` in the PROCESS working directory, which in a job is the checked-out workspace repository, so it DOES read that repository's local config.
- Consequence, observed live: `actions/checkout` leaves `http.https://github.com/.extraheader = AUTHORIZATION: basic <base64 of x-access-token:GITHUB_TOKEN>` in the workspace repository's local config. That token reads only that one repository, and an explicit Authorization header also stops git falling through to the credential helper, so the organization token is never offered on the HEAD read. Every cross-repository HEAD read answers `remote: Repository not found` / 404, Nix warns `could not read HEAD ref … using 'master'`, and the fetch then fails with `couldn't find remote ref refs/heads/master` because `infra-base` and `nix-shared` both default to `main`.
- Fixed in `auth/authenticate.sh`, which clears that one local entry — confined by the value pattern `^AUTHORIZATION:` — whenever `ORG_READ_ACCESS_ENABLED` is true. It is deliberately NOT cleared on the default path, where the repository token is exactly as narrow as the checkout credential anyway. Anything that runs `actions/checkout` after the authenticate step puts the header back, so authentication must stay ordered after every checkout on every surface.
- The only load-bearing rewrite is `url."https://github.com/".insteadOf "ssh://git@github.com/"`, because Nix strips the `git+` prefix before storing or passing the URL. Nix hands git a plain `ssh://git@github.com/...` URL, which that second form already matches. `git@github.com:` matters only for scp-form CLI clones and submodules.
- The `git+ssh://git@github.com/` form is defensive completeness, not a bug fix. Keep all three forms — the third costs one line and removes a class of doubt — but never describe it as load-bearing.
- `access-tokens` covers only the `github:`, `gitlab:` and `sourcehut:` fetchers plus curl tarball fetches. It does not cover `git+ssh` or `git+https` inputs, and does not cover `builtins.fetchurl`.
- `access-tokens` supports path-prefix scoping (`github.com/Cambridge-Vision-Technology=…`). Always use `extra-access-tokens`, which is additive; never `access-tokens`, which clobbers.
- A netrc entry for `machine github.com` does not authenticate `github:` refs, because that fetcher talks to `api.github.com`.
- TRAP, cost this workstream a wrong diagnosis on 2026-07-30. `env -u NIX_USER_CONF_FILES nix …` does NOT isolate Nix from user credentials. It does the OPPOSITE of what it reads like. `NIX_USER_CONF_FILES` OVERRIDES Nix's user-config list; unsetting it does not take user configuration out of scope, it makes Nix fall back to its DEFAULT list, whose first entry is `${XDG_CONFIG_HOME:-$HOME/.config}/nix/nix.conf` — precisely the file earlier revisions of this repository poisoned. Subtracting the variable SELECTS the leaked config instead of escaping it.
- Genuine isolation is EXPLICIT, never subtractive, and takes two parts: point `NIX_USER_CONF_FILES` at an EMPTY file, which REPLACES the default list rather than restoring it; AND pass `--option netrc-file <empty file>` on the command line, because a command-line option outranks every configuration file including `/etc/nix/nix.conf`, which the first part cannot reach. A credential-free check that omits either part is not credential-free.
- Corollary for reading any such result: a credential-free request that comes back `401 Bad credentials` is never an endpoint-discovery result. It is proof that host state reached Nix and that the isolation itself is broken. Both public A/B checks in `validate.yml` now assert this explicitly instead of falling through.

### Git LFS

- Nix implements the Git LFS protocol itself. LFS fetches do not go through the `git` binary, so `credential.helper` and `http.extraHeader` have no effect on them.
- `getLfsEndpointUrl` reads the remote through libgit2, which applies `insteadOf` at lookup time. Rewrites are therefore visible to the LFS path.
- Trap: installing the https rewrite makes a `git+ssh` LFS input silently take the unauthenticated https branch instead of the working `ssh git-lfs-authenticate` branch. This is a live defect today whenever `enable-ssh-agent` and `enable-github-app-auth` are both set.
- The https LFS branch sends no Authorization header, but LFS HTTP calls go through `filetransfer.cc`, which sets `CURLOPT_NETRC_FILE` unconditionally. `netrc-file` therefore does authenticate LFS over https. URL-embedded credentials also work; `lfs.url` is an alternative endpoint override.
- Version gate: Nix < 2.35.0 builds a malformed LFS endpoint (missing `.git`) and receives HTTP 422 from GitHub before auth is evaluated. Fixed in 2.35.0 by PR #15891 (issue #15285). HTTPS LFS with a token therefore requires Nix >= 2.35.0. 2.35.1 is the patch release to pin. See OPEN QUESTIONS for the untested `.git`-suffix workaround.

### Runner fleet (live-verified)

- `dell-foo` (100.103.224.23), label `x86_64-linux`: now Nix 2.35.1 (was 2.34.7) since CHUNK 0.1; upstream, NixOS 25.05, no Determinate. Owned by `dev-infra` (/Volumes/Git/dev-infra/main); label in `services/runner.nix`, host in `hosts/physical/dell-foo/default.nix`. Version is pinned by the `nix-pin` module in `nix-shared`, not by this host.
- `admins-mac-mini` (100.83.22.123), label `macos-arm64-nix-darwin`: now Nix 2.35.1 (was 2.34.7 via Determinate Nix 3.21.2) since CHUNK 0.2, verified on the host 2026-07-31. `nix --version` reports `nix (Nix) 2.35.1` — upstream form, no Determinate wrapper. `determinate-nixd` is ABSENT and `/nix/determinate` and `/nix/var/determinate/` are gone. Owned by `ci-runner-mac` (/Volumes/Git/ci-runner-mac), now `nix.enable = true` under nix-darwin, pinned by the SAME `nix-shared` `nix-pin` module as dell-foo.
- Determinate Nix has no 2.35-based release. Latest 3.21.7/3.21.8 are still upstream 2.34.8. Moot for our fleet as of CHUNK 0.2 — no runner runs Determinate any more.
- The GCP `runner-1`..`runner-4` fleet has been offline 29-46 days and a `retire-gcp-fleet` branch exists in dev-infra. Treat as retired.
- GitHub-hosted runners already receive Nix 2.35.1 through the `cachix/install-nix-action` v31.11.0 pin already present in `workflow.yml` and `setup/action.yml`. No change is needed in this repository for them.
- `workflow.yml` skips Nix installation when Nix is already present (the `Detect existing Nix` step), so CI never upgrades a self-hosted runner. Each runner's own configuration repository is the only lever.
- Both runners currently have empty `access-tokens`.
- CORRECTED 2026-07-31, checked on the host. dell-foo has NO system netrc at all: `/etc/nix/netrc` DOES NOT EXIST, and nothing in `/etc/nix/nix.conf` or any NixOS module sets `netrc-file`. The earlier entry here claiming a system `netrc-file = /etc/nix/netrc` on dell-foo was wrong, and the CHUNK 1.5 diagnosis built on it was wrong with it.
- SUPERSEDED 2026-07-31 by CHUNK 0.2: NEITHER runner has a system netrc now. The mac's `/nix/var/determinate/netrc` was Determinate's and left with Determinate. `git grep -i netrc` over `ci-runner-mac` returns nothing on either branch — the host never had a repo-managed netrc. Attic cache auth there uses a sops secret (`config.sops.secrets.attic_token`), not netrc; FlakeHub is not a substituter on that host.
- What actually held the stale credential on dell-foo was this repository's own leftovers in the RUNNER USER's home — `$HOME/.netrc`, `$HOME/.git-credentials`, a global `credential.helper`, and `netrc-file = /tmp/netrc` in the USER `nix.conf` — not any machine-owner or system state. See the SECURITY entry under "Defects in the pre-CHUNK-1.1 `workflow.yml`".
- CONFIRMED 2026-07-31: `admins-mac-mini` carries the SAME five legacy artifacts, in the runner HOME `/opt/github-runner/admin-mac-mini` — NOT the passwd HOME `/var/lib/github-runner`. Same distinct-work-dir trap as dell-foo; look in the runner's work directory, not the account home.

### The SSH path is dead organization-wide (live-verified 2026-07-29)

- `SSH_KEY_PRIVATE` authenticates as GitHub user `cvt-service`, which is not an organization member and can read nothing. `ssh -T` returns "Hi cvt-service!"; `git ls-remote` fails "Repository not found" for the wiki, `dev-infra`, `infra-state-production` and `nix-shared`. The account was created 2025-02-26 and holds no organization membership.
- Consequence: consumers are not being kept working by `ssh-private-key`. Workflows carrying the App block are green because of the App token, not because of SSH.
- Retiring `enable-ssh-agent` is therefore far lower risk than "preserve default behavior" implied. Nothing that works today stops working.
- HARD CONSTRAINT on what "retire" means (DEV-754 criterion #5 correction, 2026-07-29): DEPRECATE AND KEEP ACCEPTING. `enable-ssh-agent` and the `ssh-private-key` secret must remain DECLARED and OPTIONAL until DEV-760's organization-wide sweep completes. NEVER remove them in this PR.
- Two independent reasons: an undeclared input in a reusable-workflow call is a startup failure for 27 consumers; and once the organization secret is deleted, `secrets.SSH_KEY_PRIVATE` resolves empty and `webfactory/ssh-agent` fails hard.

### The GitHub App (verified 2026-07-29)

- App is `cvt-ci-fetch`, App ID 4413847, permissions `contents: read` + `metadata: read`, installed organization-wide. Organization secrets are `CI_FETCH_APP_ID` / `CI_FETCH_APP_PRIVATE_KEY`.
- Our surfaces deliberately expose generic `github-app-id` / `github-app-private-key` input names and do NOT hard-code those secret names. Keep it that way.
- An App installation token CAN clone `*.wiki.git`, despite Apps having no wiki permission. Settled empirically in dev-infra#157.

### Cross-repository boundaries

- DIRECTION (not a gate for this PR): `maintenance` eventually converges on this auth composite for the READ path only. The write path — `AUTO_UPDATE_APP_ID`, used for PR creation and auto-merge — does not converge. A read-only composite that grew a write mode would hold the union of both permission sets. Convergence lands under DEV-754/DEV-760, after this PR.
- KNOWN INTERIM DIVERGENCE (verified 2026-07-29): maintenance PR #51 is open and builds a different implementation — mechanism-named input `security-use-ci-fetch-app`, repo-scoped token, `GIT_CONFIG_GLOBAL` redirection, NO `insteadOf` rewrites (it swaps flake URLs to `git+https` at the call site), and still `determinate-nix-action@v3`. Accepted as interim; reconcile at convergence time, not now. Do not block this PR on it.
- CONDITION at convergence: `maintenance` must pin this composite BY SHA, never `@main`. Both repositories are consumed unpinned by roughly 29 repositories and currently fail independently; a `@main` dependency between them would correlate the blast radius.
- STANDING CONSTRAINT: `ci` must NEVER consume anything from `maintenance`. Verified 2026-07-29 that it does not today. Adding a `maintenance.yml` to this repository later would create a cycle between the two repositories every other repository depends on.
- FACT (code search, 2026-07-29): no other auth composite exists anywhere in the organization. No duplication risk in creating this one.
- SCHEDULE PRESSURE, informational only, changes no deliverable here: DEV-762 opened 2026-07-29 — `dev-infra` cd-apply cannot read the wiki and production apply is blocked. If it cannot wait for this PR, a temporary fourth copy of the mint block gets pasted there. Expect it as a cleanup target at DEV-760 sweep time.

### Defects in the pre-CHUNK-1.1 `workflow.yml` — all fixed by CHUNK 1.1, kept as the regression list

- Three redundant credential mechanisms are written (`~/.netrc`, `~/.git-credentials`, `credential.helper store`) where one suffices.
- `netrc-file` is set in the user `nix.conf`, which clobbers any system `netrc-file` because the setting is scalar and user config wins. Historically that broke FlakeHub and cache auth on the Determinate-managed mac runner; since CHUNK 0.2 no runner has a system netrc, so the clobber has no victim left. The rule stands anyway — use additive settings and never override a machine-owner value.
- The fixed path `/tmp/netrc` lets concurrent jobs on self-hosted runners clobber each other, and credential files are never cleaned up, so tokens outlive the job. Use `$RUNNER_TEMP` and clean up.
- SECURITY, CONFIRMED LIVE 2026-07-31 on dell-foo. That last item is not theoretical and is not merely hygiene. `origin/main`'s `setup/action.yml` and `workflow.yml` wrote FIVE credential artifacts and removed NONE of them: `$HOME/.netrc`, `/tmp/netrc`, `$HOME/.git-credentials`, a GLOBAL `credential.helper store` bound to that file, and `netrc-file = /tmp/netrc` in the user `nix.conf`. On a self-hosted runner `$HOME` and `/tmp` persist between jobs, so a plaintext `ghs_` App installation token sat in the runner user's home directory long after the job that minted it ended. It has since expired — installation tokens live one hour — so this is a disclosed-and-dead credential, not a live one, but the exposure window was real and unbounded by anything except the token's own lifetime.
- DELIVERABLE 8's "the private key and token are not printed or uploaded" was therefore effectively VIOLATED on self-hosted runners by the pre-CHUNK-1.1 code. Not through the logs, which were clean, and not through artifacts, which were never uploaded — through persistent on-disk state on a shared machine, which the deliverable's wording did not anticipate. Read deliverable 8 as covering on-disk residue as well; CHUNK 1.1's self-heal is what makes it true.
- Second-order consequence, and the reason a stale token is worse than a merely untidy one: the leftover `netrc-file` and global credential helper are read by EVERY later job on that runner, including jobs that ask for no organization access at all. Those jobs then send an expired token where they would otherwise have sent nothing, and GitHub answers `401 Bad credentials` — even for a PUBLIC repository, which is otherwise unauthenticated. A dead credential is not inert; it converts anonymous success into authenticated failure.
- ONGOING, and the reason merging is time-sensitive: this is not a one-off residue to be cleaned once. Every consumer still calling `ci@main` re-writes all five artifacts on every self-hosted run. On dell-foo on 2026-07-31 the HOME artifacts were observed freshly written, and `/tmp/netrc` was observed absent and then present again roughly ten minutes later, by jobs this workstream did not launch. Until this lands on `main`, each such job re-arms the leak with a live one-hour token. The self-heal cleans a runner only as of the last job that ran the NEW script on it.
- CONFIRMED ON BOTH RUNNERS 2026-07-31. `admins-mac-mini` carries all five artifacts too, under the runner HOME `/opt/github-runner/admin-mac-mini`, and they were likewise observed being actively rewritten by in-flight jobs running `origin/main`'s old code. They match CHUNK 1.1's exact-shape removal criteria, and `/tmp/netrc` there is runner-owned, so the self-heal removes every one of them on the first run of the new script. NO host access is needed for the mac either.
- `enable-ssh-agent` and `enable-github-app-auth` are mutually destructive: the rewrite is installed before ssh-agent starts, and it breaks LFS as described above.
- `setup/action.yml` has no `insteadOf` rewrite and no stale-rewrite cleanup. It has drifted from `workflow.yml` on the one mechanism that matters.
- No `access-tokens` are set when Nix is pre-installed, so `github:` refs hit the 60/hr anonymous API limit on self-hosted runners.
- `|| true` appears in two places, violating the fail-fast rule in CLAUDE.md. `git config --unset-all` exits 5 when the key is absent; branch on that specific status.
- App installation tokens expire in one hour, but build `timeout-minutes` is 120.

### GitHub Actions delegation mechanics (verified)

- Expressions are forbidden in `uses:`.
- A composite action cannot reference a sibling action with `uses: ./auth` — `./` resolves against the caller's `GITHUB_WORKSPACE`.
- `github.action_path` is supported for reaching sibling files in the same repository at the exact revision, in composite actions only.
- `job.workflow_repository` and `job.workflow_sha` (shipped April 2026) let a called reusable workflow check out its own repository at its own revision, with no hard-coded repository and with the fork path preserved. They are not available on GitHub Enterprise Server.
- There is no OIDC claim identifying a composite action; only `workflow_ref` and `job_workflow_ref` exist. A standalone auth action can therefore never reach OIDC assurance parity with the reusable-workflow path.

### Implementation shape

- `auth/authenticate.sh` is the single implementation. `auth/action.yml` is a thin composite wrapper for standalone consumers. `setup/action.yml` invokes the script via `"$GITHUB_ACTION_PATH/../auth/authenticate.sh"`. `workflow.yml` checks out `job.workflow_repository` at `job.workflow_sha` into a workspace subpath, invokes the same script, then removes the checkout.
- Token minting stays a pinned `uses: actions/create-github-app-token` step on each surface, because a script cannot invoke an action. Deliverable 4's "one implementation" scope is credential writing, rewrites and Nix configuration — not token minting.
- This shape is orchestrator judgment, not a user decision. Flag it for review; the user may overturn it.
- Pre-checkout stale cleanup (`http.extraHeader`, `url.*.insteadOf`) stays inline on each surface, because it must run before `actions/checkout` while delegation requires a checkout to exist. This is deliberate, not drift. It is GLOBAL scope only.
- The matching POST-checkout cleanup of the LOCAL `http.https://github.com/.extraheader` that `actions/checkout` writes lives in the shared script, not inline, because `auth/action.yml` never performs the checkout it has to undo — a consumer does. `persist-credentials: false` was rejected for exactly that reason: it fixes only the two surfaces that own a checkout, changes the default path for no gain, and leaves the standalone action broken.
- The shared script receives `ORG_READ_ACCESS_ENABLED`, named for the capability, not `ORG_READ_INSTALL_URL_REWRITES`, named for one of the two mechanisms it now governs.
- The minimum Nix version floor is hard-coded, never a consumer input, so consumers cannot lower it.
- The auth capability outputs nothing as its primary contract. Its contract is an environment side effect: after this step, `git` and `nix` can read organization repositories. `gh` is deliberately NOT covered — `auth/authenticate.sh` sets no `GH_TOKEN` or `GITHUB_TOKEN` and writes no `hosts.yml`, and `gh` reads neither the git credential helper nor Nix's `netrc-file`. That is exactly the case the `org-read-token` output on `auth/action.yml` exists for. Any escape-hatch output is named `org-read-token`, never `token`.
- Keep the official App-token action pinned to its current v3.2.0 commit and request read-only contents permission.
- Preserve default behavior, because organization consumers use this repository at `@main`. The SSH path is exempt: it authenticates nothing today, so retiring it preserves behavior by definition.
- Do not put token-minting logic in consumer repositories.
- Use the existing structural suites in `tests/`. Do not add a new automated behavioral test suite.
- Use manual, read-only GitHub Actions probes for behavior that requires real App credentials and private repositories.

### Testing reality

- `flake.nix` exposes only `devShells`. There is no `checks` output, so `nix flake check` does not execute the `tests/` suites. They run solely from the `Run shell contract tests` step in `validate.yml`, and locally by executing `tests/*/test.sh` directly. Completion evidence must reflect this, or a `checks` output must be added first.
- The three existing shell contract suites are `tests/runner-map-transform`, `tests/setup-action-structure`, `tests/workflow-structure`. `tests/smoke` is not a suite — it is the flake fixture the `ci` job in `validate.yml` builds, and it carries no `test.sh`.
- Any LFS or auth probe requires a cold cache. `rm -rf ~/.cache/nix/gitv3` first, or the result is a false green. This has happened in practice.

### Forward compatibility (record only; do not implement now)

- OpenBao has no GitHub App secrets engine and its JWT auth is an external plugin. "OpenBao mints GitHub tokens" is a dead end. Phrase future work as "an STS".
- DEV-753: OpenBao is tailnet-only. GitHub-hosted runners cannot reach it at all; a narrow hosted-runner ingress would be its own piece of future work. Reinforces "an STS" rather than "OpenBao".
- Octo STS (Chainguard, OSS, self-hostable) is the credible target: OIDC to short-lived App installation token, trust policy in git, eliminating the App private key entirely.
- SPIRE does not apply to ephemeral GitHub runners — there is no GitHub Actions node attestor. GitHub OIDC is the attestation root.
- Immutable subject claims auto-enforce from 2026-07-15 for new and renamed repositories. Future trust policies must bind on `repository_owner_id`, `repository_id` or `job_workflow_ref`, never a string match on `sub`.

### External dependencies (handled by the user, not chunks here)

- Rotating a leaked PAT in the workstation `nix.conf`.
- MOOT since CHUNK 0.2: ~~Re-authenticating the mac runner's expired Determinate token.~~ Determinate is gone from the host.
- RESOLVED in practice: the mac deploy path worked — CHUNK 0.2 was delivered by a deploy-rs push to `admins-mac-mini`. The `mac-mini-ts` SSH alias is no longer blocking.
- OUTSTANDING: merge `ci-runner-mac` PR #17. Until then the mac runs an unmerged branch and a `main` deploy reverts it. See the CHUNK 0.2 CAVEAT.

### Known defect outside this ticket (not a chunk; needs its own ticket)

- `dev-infra` `services/runner.nix:108` grants the runner NOPASSWD sudo through a hard-coded `${pkgs.nix}/bin/nix`, which resolves through `nixpkgs-physical` to Nix 2.28.5 — a different binary from `/run/current-system/sw/bin/nix`, now 2.35.1.
- Consequence: any CI step using `sudo nix` runs 2.28.5, or fails the sudo rule because the path does not match.
- Pre-existing, blamed to commit `363a91ef` (2026-03-20). Not caused by CHUNK 0.1 and out of scope for DEV-759.

## OPEN QUESTIONS

Recorded, not decided. Do not act on these without live evidence.

- Does adding a `.git` suffix to LFS flake input URLs make the endpoint well-formed on Nix < 2.35.0? OVERTAKEN BY EVENTS as far as this ticket is concerned — CHUNK 0.2 upgraded the mac, so no runner is below the floor and nothing depends on the answer. Retained only as a possible fallback for a future sub-floor host. Source-traced but NOT empirically verified. The credential-free public-repository repro in CHUNK 1.4 is consistent with it, because that URL deliberately lacks the suffix.

## PHASE 0 — Raise all CI runners to Nix >= 2.35.0 — COMPLETE (CHUNKS 0.1 AND 0.2)

Prerequisite for everything in PHASE 1. Without it the uniform HTTPS token path cannot serve LFS. Work happened in external repositories, each on its own branch with its own PR.

BOTH self-hosted runners now meet the floor: `x86_64-linux` (dell-foo) and `macos-arm64-nix-darwin` (admins-mac-mini), both on Nix 2.35.1. The CHUNK 1.2 guard passes on both, so no consumer is red on merge.

### CHUNK 0.1 — dell-foo to Nix >= 2.35.0 — COMPLETE

Delivered externally and in parallel, not by this workstream.

- `dell-foo` is live on Nix 2.35.1, verified on the host. System generation 13, 2026-07-29.
- Delivered by `nix-shared` PR #38 (merged, commit `ef576c6`), which changed `modules/nix-pin.nix` to pin `nixVersions.nix_2_35` from a dedicated `nixpkgs-nix` flake input, plus `dev-infra` PR #159 (merged, commit `bb7da39`), which bumped the `nix-shared` input.
- KEY FACT for future work: the fleet-wide lever for Nix version is the `nix-pin` module in `nix-shared`, not per-host `nix.package`. CORRECTED 2026-07-31 — `dell-foo` is NO LONGER the only `nix-pin` consumer. CHUNK 0.2 put `admins-mac-mini` on the same lever via `darwinModules.nix-pin`, so there are now two consumers, one NixOS and one darwin.
- `nixos-unstable`'s default `pkgs.nix` was still 2.34.8, so the `nixVersions.nix_2_35` attribute must be named explicitly. A plain `pkgs.nix` silently stays below the floor.
- `nix-shared` PR #38 also added `darwin-nix-pin` and `nixos-nix-pin` checks, because nixpkgs drops old `nixVersions.nix_2_*` attributes as a series ages out, so a future input bump could otherwise silently evaluate the pin away. New self-hosted hosts inherit the 2.35 floor by construction.
- The runner label `x86_64-linux` is unchanged and the runner is online.

### CHUNK 0.2 — admins-mac-mini to Nix >= 2.35.0 — COMPLETE

Delivered externally, not by this workstream. The chosen option was the Determinate-to-upstream migration, not waiting for a Determinate 2.35 release.

LIVE-VERIFIED ON THE HOST 2026-07-31:

- `nix --version` reports `nix (Nix) 2.35.1` — the upstream form, with no Determinate wrapper in the string.
- `determinate-nixd` is ABSENT; `/nix/determinate` and `/nix/var/determinate/` are gone.
- Nix is now managed by nix-darwin via `nix-shared`'s `darwinModules.nix-pin` — the SAME fleet-wide lever used for dell-foo in CHUNK 0.1. See the corrected KEY FACT under CHUNK 0.1: there are now two `nix-pin` consumers, not one.
- The runner is online and registered, label `macos-arm64-nix-darwin` unchanged, and a post-migration `ci / build (aarch64-darwin)` job has already succeeded.
- The CHUNK 1.2 guard was executed ON the host using the runner SERVICE's own PATH, not a login shell's: exit 0, "meets the required minimum 2.35.0".

Delivered by `ci-runner-mac` commit `029a869` "feat(nix): migrate to upstream nix 2.35 via nix-shared nix-pin", which sets `nix.enable = true`, moves every `nix.custom.conf` setting to `nix.settings.*`, and adds a `nix-upstream` check asserting nix >= 2.35.

CAVEAT — READ BEFORE TOUCHING THE MAC. `ci-runner-mac` PR #17 is OPEN, NOT MERGED. The host was deployed from the branch `dev/nix-upstream-migration` via deploy-rs push, so the running system does not correspond to any commit on `main`. A deploy-rs push from `main` would REVERT the mac to Determinate Nix 2.34.7 and re-break the CHUNK 1.2 guard, reddening every darwin job. PR #17 should be merged. Until it is, the green state here is branch-deployed and reversible by any routine `main` deploy.

Consequences and corrections:

- The `aarch64-darwin` LFS-over-token gap is now closable. See CHUNK 1.4 — a darwin probe is POSSIBLE but has NOT been run.
- The earlier "darwin consumers are red until this lands" text is obsolete. It has landed; they are green. See CHUNK 1.2's completion evidence.
- This repository's own PR CI was never affected: `validate.yml` uses `macos-latest`, which gets Nix 2.35.1 from the pinned `cachix/install-nix-action` v31.11.0.
- The `.git`-suffix question in OPEN QUESTIONS is now moot as a way to avoid this chunk. Keep it recorded only as a possible fallback for any future sub-floor host.

Prior art that made this cheap, in `nix-shared`, NOT `mac-workstation`:

- `nix-shared` `scripts/migrate-to-upstream.sh` (PR #36, merged 2026-07-13, commit `41de888`).
- `nix-shared` `docs/nix-implementation-standard.md` (PR #34, commit `a88c733`) standardises the organization on upstream CppNix and DEPRECATES the darwin `determinate.nix` module. This migration executes that policy.

Completion evidence:

- `ci-runner-mac` change deployed to `admins-mac-mini`. PARTIAL — deployed and verified, but from an UNMERGED branch. See the CAVEAT.
- `nix --version` on `admins-mac-mini` reports >= 2.35.0. VERIFIED — 2.35.1.
- The runner label `macos-arm64-nix-darwin` is unchanged and the runner is online. VERIFIED, with a post-migration darwin CI job green.
- STRUCK, moot exactly as already struck for dell-foo: ~~FlakeHub and cache authentication still work after the change, with the system `netrc-file` intact.~~ There is no system `netrc-file` to keep intact. `git grep -i netrc` over `ci-runner-mac` returns nothing on either branch; the host never had a repo-managed netrc, and the only one that ever existed was Determinate's, which left with Determinate. Attic auth uses a sops secret (`config.sops.secrets.attic_token`), not netrc, and FlakeHub is not a substituter there. Post-migration jobs succeed, so cache auth demonstrably works.

## PHASE 1 — Centralize authentication in this repository

One PR-executable unit that leaves the shared workflow ready for immediate use.

Self-hosted probes as shipped run on `x86_64-linux` (dell-foo, Nix 2.35.1) only, because at the time it was the sole self-hosted runner meeting the 2.35.0 floor. Since CHUNK 0.2, `admins-mac-mini` also meets it, so darwin probe coverage is now possible — see CHUNK 1.4. It has not been added. The guard itself is NOT scoped that way — it ships enforced on every platform, darwin included.

### CHUNK 1.1 — Implement the shared authentication contract — COMPLETE

Verified: 205 assertions at first completion; 477 across the three shell contract suites after the 2026-07-31 self-heal extension; actionlint, prettier and shellcheck clean; sandbox-verified against real Nix.

Notes a future developer needs and cannot read off the code:

- EXTENDED 2026-07-31. Writing no credential into `HOME` was necessary but NOT sufficient, because `origin/main` already had — and every runner that ever ran it still carries. `auth/authenticate.sh` therefore also REMOVES the five legacy artifacts listed in CONSTRAINTS, and this is the one thing it does to machine-owner files.
- The removal is UNCONDITIONAL and runs FIRST, on the DEFAULT path too. Unconditional because the job that suffers most from a stale token is precisely the one that asked for no organization access — it inherits someone else's expired credential and gets a 401 from a public repository. Gating the cleanup on `ORG_READ_ACCESS_ENABLED` would skip the machines that need it. First, because everything after it either writes the replacement credentials or points Nix at them, and none of that may race a stale file still named by Nix's default user-config list.
- Ours is distinguished from a machine owner's BY EXACT SHAPE, never by filename and never by machine name. The netrc entry must be exactly `machine github.com` / `login x-access-token` / `password <token>` and nothing else — a `github.com` entry with any other login is the owner's own credential, an entry carrying any further key was not written by us, and any other machine is none of our business. The git-credentials line must match `^https://x-access-token:[^@/]*@github\.com/?$`. The `nix.conf` setting must be `netrc-file` valued exactly `/tmp/netrc`. Everything else in every one of those files survives verbatim, and a file we did not modify keeps its original inode, mode, owner and mtime.
- A file left holding nothing after our entry is removed is DELETED rather than left as an empty stub the machine owner never asked for. A file that survives is rewritten by redirection into the existing path, not by moving a temporary over it, so the owner's inode, mode and ownership are preserved.
- `/tmp/netrc` is the exception with no shape check, because the fixed path is this repository's own invention and no machine owner has a claim on it. When it belongs to ANOTHER user it is REPORTED LOUDLY and is NOT fatal: `/tmp` is sticky, so only its owner can unlink it, and failing hard would red every job on the runner forever over a file no job is able to remove. Only the runner owner can clear that case.
- This fix needs NO host access and NO `dev-infra` change. It is self-healing: the first job to run the new script on any runner cleans that runner. CONFIRMED on dell-foo 2026-07-31 — before the run, the runner's job HOME (`/var/lib/github-runner/dell-foo-work`, which is NOT the passwd HOME) held `.netrc` with a `login x-access-token` entry, `.git-credentials` with the matching line, and a `nix.conf` whose only setting was `netrc-file = /tmp/netrc`; after it, all three are gone, `/tmp/netrc` is gone, and the global `credential.helper` is only the job-scoped `store --file=…/_temp/github-org-read-credentials.*`. The bare `store` helper is gone.
- HARD REQUIREMENT discovered live, and the reason the first self-heal revision failed: EVERY filter must be bash builtins alone. A self-hosted runner service runs with a curated PATH, not a login shell's. dell-foo's carries coreutils, git, grep, sed, jq and curl and carries NEITHER gawk NOR diffutils, so an `awk` filter and a `cmp` comparison were `command not found` on precisely the machine holding the leaked credential. A login shell there DOES resolve `awk` through `/run/current-system/sw/bin`, which is why this cannot be checked by sshing in and running `command -v`. Check the runner service's own `Environment=PATH`.
- Filtering in bash also removed a defect the awk version carried: it staged the filtered copy under `RUNNER_TEMP`, writing the very token being removed back to disk in order to remove it. Nothing is staged now.
- Change detection needs no `cmp` either. Only the filter that recognised its own handiwork may authorise a rewrite, and it says so by raising `legacy_removed_entry`, so a file we changed nothing in is never opened for writing. Verified by inode equality.
- Credentials are split BY CONSUMER, deliberately. Git uses `credential.helper store --file=` pointing at a `$RUNNER_TEMP` file. Nix's LFS/curl path uses `netrc-file`, because LFS transfers cannot call a credential helper. One mechanism per consumer, no overlap. This is not the redundancy the old `workflow.yml` had.
- Nix settings are injected by exporting `NIX_USER_CONF_FILES` through `$GITHUB_ENV`, NOT by writing `$HOME/.config/nix/nix.conf`. The script reproduces Nix's XDG default list so machine-owner settings still apply after ours.
- `.github/actionlint.yaml` exists solely because actionlint 1.7.12 does not yet know `job.workflow_repository` / `job.workflow_sha`. The suppression is scoped to those two property names in `workflow.yml` only; a bogus property is still reported.
- Known cosmetic, not a defect: if one job invokes the script twice (setup + auth), `NIX_USER_CONF_FILES` accumulates a stale path. Nix tolerates missing entries silently.

Original scope, for reference: create `auth/authenticate.sh` and the thin `auth/action.yml` wrapper. Make `workflow.yml` and `setup/action.yml` invoke that single script at the consumer-selected revision. Add the `enable-org-read-access` capability input, with `enable-github-app-auth` retained as a deprecated alias on `workflow.yml` only — `setup/action.yml` never published that input, so it gains no alias.

Fix every live defect listed in CONSTRAINTS: one credential mechanism, all three `insteadOf` rewrite forms installed together with only the `ssh://` form treated as load-bearing, additive `extra-access-tokens` with path-prefix scoping, `$RUNNER_TEMP` paths with mode 600 and cleanup, no clobbering of a Determinate-managed `netrc-file`, no `|| true`, and deprecation of `enable-ssh-agent` in favor of the uniform token path — deprecated and still declared and accepted, never removed.

Every `if:` currently gated on `inputs.enable-github-app-auth` becomes alias-aware, including the `install-nix-action` token selection expression. The suites currently assert the split step names `Authenticate git / Nix to github.com (repository token)` and `(GitHub App token)` and run a `required_setup_steps` parity loop over both surfaces — this chunk rewrites those assertions rather than merely extending them.

Completion evidence:

- All three shell contract suites pass when run directly.
- Source search finds one credential-writing and rewrite implementation.
- Source search finds no independent credential-writing or rewrite implementation in `setup/action.yml` or `workflow.yml`.
- Source search finds no `|| true`, and finds all three rewrite forms only inside the single implementation.
- A default call mints no App token and installs no rewrites.
- The pre-checkout stale cleanup remains inline on both surfaces and is asserted as intentional.

### CHUNK 1.2 — Fail-fast minimum Nix version guard — COMPLETE

Verified: 270 assertions across the three shell contract suites; actionlint, prettier and shellcheck clean; all three guard bodies independently executed.

Notes a future developer needs and cannot read off the code:

- The floor 2.35.0 is a hard-coded literal on all three surfaces — `workflow.yml`, `setup/action.yml`, `auth/action.yml`. It is never an input, so consumers cannot lower it.
- Enforced identically on every platform. No soft warning, no platform exemption.
- `auth/action.yml` skips the check when `nix` is absent from PATH (explicit `command -v nix`), because that action configures credentials only and never installs Nix. It fails hard when nix IS present and below the floor. Its guard runs BEFORE the token mint, so an unsupported runner costs no minted credential.
- The parser extracts the TRAILING upstream version, so Determinate's `nix (Determinate Nix 3.21.2) 2.34.7` correctly yields 2.34.7.
- Comparison is component-wise numeric with base-10 forcing. A lexical compare would wrongly pass 2.9.0.
- `RUNNER_LABEL` is `matrix.systems.runner` (the real label) on `workflow.yml`, but `runner.name` on the two composites, because there is no label context inside a composite action.

Original scope, for reference: add the hard-coded floor of 2.35.0. A runner below the floor fails the job with a message naming the runner label, the version found, and the version required. No `|| true`, no soft warning, no consumer input that could lower the floor.

Completion evidence:

- Both structural suites assert the guard exists on both surfaces and that the floor is a literal, not an input reference.
- A guard message referencing runner label, found version, and required version is asserted by the suites.
- Real CI on `x86_64-linux` (dell-foo, Nix 2.35.1) passes the guard.
- `macos-arm64-nix-darwin` is NOT exempt (user decision), and as of CHUNK 0.2 it PASSES the guard on Nix 2.35.1. Verified by executing the guard body on the host under the runner service's own PATH — exit 0, "meets the required minimum 2.35.0" — and by a post-migration `ci / build (aarch64-darwin)` job succeeding. The forcing function worked and is spent; darwin is no longer red, and this is no longer a merge blocker for PR #23.

### CHUNK 1.3 — README

Document the capability contract, caller permissions (`contents: read` and `id-token: write`, required now even though the first acquisition source is the App secret), the deprecated alias and the trigger for its removal, LFS now being served by the token path, and the deprecation of `enable-ssh-agent` (still accepted; removal only after DEV-760's sweep).

NEW REQUIREMENT (DEV-757): document that on `[self-hosted, Linux, X64]` the caller must set `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` at WORKFLOW level, or `actions/create-github-app-token` will not run there. Driven by `dev-infra`'s `build_workstation_index` job. The README now documents that string; nothing else in this repository sets it.

Completion evidence:

- README states the caller permissions block.
- README states `enable-org-read-access` as the preferred input and `enable-github-app-auth` as deprecated, with a removal trigger.
- README states that LFS inputs no longer need SSH.
- The inputs table marks `enable-ssh-agent` deprecated but still accepted; it does not claim removal.
- README states the `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` workflow-level requirement for self-hosted Linux X64 callers.

### CHUNK 1.4 — Manual probes — COMPLETE

Verified: 477 assertions across the three shell contract suites (8 runner-map-transform, 192 setup-action-structure, 277 workflow-structure); actionlint and prettier clean; the pull-request exclusion traced through both gate terms and through the audit's `always()`.

Notes a future developer needs and cannot read off the code:

- The probes are gated on `github.event_name == 'workflow_dispatch' && inputs.run-org-read-probes`, and the input defaults to false. Neither a pull request nor a plain manual dispatch creates a probe job.
- The LFS repository is `purescript-dedup` (~9 MB of objects), chosen over `oz` (295 MB) to stay inside the ten-minute budget.
- The probes make SSH UNUSABLE — `SSH_AUTH_SOCK: ""` and `GIT_SSH_COMMAND: "false"` — rather than merely unused, so a `git+ssh` pass cannot mask a broken HTTPS path.
- They clear the fetcher cache as well as `gitv3`. The fetcher cache memoises `fetchGit` by URL and revision and would short-circuit every fetch on its own.
- The fixture flake at `tests/org-read-probe` deliberately has NO committed `flake.lock`. A lock would let Nix serve the tree from the local store with no network fetch, defeating the probe.
- `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` has to be workflow-level, which also affects `lints` and `setup-composite-smoke` on the normal pull-request path by forcing Node 24 for their JavaScript actions. Low risk, but a behaviour change whose only beneficiary is probe 3.
- The public-repository A/B check matches the surrounding Nix error phrase (`HTTP error 403` / `exceeded its LFS budget`, and `HTTP error 422`), never a bare three-digit number. The log carries store paths and URLs, and a store hash containing `403` with no `422` present would read as a false green.
- CORRECTED 2026-07-31. The A/B check's isolation was `env -u NIX_USER_CONF_FILES`, which SELECTED the poisoned user `nix.conf` instead of escaping it — see the TRAP entry in CONSTRAINTS. It is now explicit: `NIX_USER_CONF_FILES` pointed at an EMPTY file, plus `--option netrc-file <empty>` and `--option access-tokens ""` on the command line so no configuration file, system one included, can put a credential back.
- The A/B check now also fails closed on `HTTP error 401` / `Bad credentials`. A request that carries no credential cannot be rejected for its credential, so a 401 means the isolation leaked and no result in that run means anything. Previously a 401 fell through to the generic fail-closed branch and read as an unexplained red, which is what sent the 2026-07-30 diagnosis down the wrong path.
- REDESIGNED 2026-07-30. The credential audit is no longer a step inside each probe. It is a separate job, `probe-log-credential-audit`, that `needs:` all three probes and reads their logs after they complete.
- Two defects forced this, both found by live runs. (1) A job cannot read its own log: `GET /actions/jobs/{id}/logs` answers 404 for an in-progress job, so the in-job check failed closed on every run and could never pass. (2) The runner echoes every `run:` body into the job log, so the old check's own source line carrying the literal `PRIVATE KEY` would have matched itself — a guaranteed FALSE-POSITIVE leak the moment the 404 was fixed.
- The audit is gated `always() && github.event_name == 'workflow_dispatch' && inputs.run-org-read-probes`. `always()` keeps a leak in a FAILED probe catchable; `always()` overrides only the implicit needs-succeeded condition, never an explicit term, so the same dispatch gate still keeps it off pull requests.
- It fails closed on five distinct unscannable conditions — job list unreadable, paginated job list, no job matching an audited name, an audited job not completed, a completed log unreadable after retries — all prefixed `AUDIT INCOMPLETE, NOT A LEAK` so a red can never be misread as a leak. Only a log read in full can report `CREDENTIAL LEAK`.
- It holds no App credential, needs no Nix, and the probes gave up their `actions: read` grant. It is also strictly wider than what it replaces: it scans probe 1's NESTED jobs, which could never have carried a step at all.
- A suite assertion guards that the scan literals appear in no source the audit reads — `validate.yml` outside the audit job, plus `workflow.yml`, `setup/action.yml`, `auth/action.yml` and `auth/authenticate.sh` — so defect 2 cannot regress.
- NEW OPTION, NOT DONE, recorded 2026-07-31. A fourth probe on `macos-arm64-nix-darwin` is now POSSIBLE: CHUNK 0.2 put that runner on Nix 2.35.1, so it meets the floor the earlier exclusion was based on. It would close the `aarch64-darwin` LFS-over-token gap, which is still unproven. This has NOT been implemented and is NOT claimed as done. Anyone adding it must also fold the new job name into `probe-log-credential-audit`'s audited-name list, or the audit fails closed on "no job matching an audited name". Note the CAVEAT in CHUNK 0.2 first — the mac's 2.35.1 currently comes from an unmerged branch deploy.

DEVIATION from the original scope — probe 1 cannot do what the other two do:

- GitHub rejects `steps`, `env` AND `timeout-minutes` on a job that calls a reusable workflow with `uses:`; only `name`, `uses`, `with`, `secrets`, `needs`, `if` and `permissions` are allowed. Verified empirically against actionlint, each key independently.
- Probe 1 therefore cannot clear the Nix caches, cannot disable SSH, cannot set a timeout, and cannot run the public-repository A/B check.
- Its mitigations: it runs on `ubuntu-latest`, a fresh virtual machine with no pre-existing Nix cache and no SSH key or agent, so the cold cache and the absence of SSH hold by construction; it inherits `workflow.yml`'s build timeout; and `workflow.yml`'s own hard-coded 2.35.0 guard fails the job outright below the floor, which is the condition the A/B check would otherwise detect.
- Probes 2 and 3 DO clear both `~/.cache/nix/gitv3` and the fetcher cache as their first step, and DO make SSH unusable.

Original scope, for reference: extend the existing `workflow_dispatch` validation path with manual-only, read-only probes, gated on `github.event_name == 'workflow_dispatch'` plus an explicit opt-in input so ordinary dispatches of `validate.yml` do not pay for them.

- Reusable workflow with organization access on GitHub-hosted Linux.
- Setup action with organization access on GitHub-hosted Linux.
- Standalone auth action on the self-hosted `x86_64-linux` runner (dell-foo, Nix 2.35.1), without the setup action. No darwin probe was in scope, because CHUNK 0.2 was deferred when this shipped.
- NEW REQUIREMENT (DEV-757): the self-hosted probe must set `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` at WORKFLOW level, otherwise `actions/create-github-app-token` will not run on `[self-hosted, Linux, X64]`. This probe is the proof that `dev-infra`'s `build_workstation_index` job can adopt the standalone action.
- Each probe clones private `infra-base`, resolves private `nix-shared` through its `git+ssh://` flake URL with App credentials and no SSH key, and resolves at least one LFS-bearing input.
- Every probe that can run steps clears the Nix git and fetcher caches first. Without this the result is a false green. See the DEVIATION above for probe 1.

Testing method:

- Isolate the Nix LFS endpoint bug from auth concerns with a credential-free public-repository A/B before interpreting any private-repository result. Command: `nix eval --impure --raw --extra-experimental-features "nix-command flakes" --expr '(builtins.fetchGit { url = "https://github.com/Apress/repo-with-large-file-storage"; ref = "master"; lfs = true; }).outPath'`. The URL deliberately lacks a `.git` suffix, which is what triggers the bug.
- On Nix < 2.35 expect HTTP 422. On >= 2.35 expect HTTP 403 "exceeded its LFS budget", which is a SUCCESS signal — a real GitHub LFS API response means endpoint discovery worked.
- CRITICAL: a passing `git+ssh` fetch proves NOTHING here. Always test over HTTPS.

Completion evidence:

- Normal pull-request validation still exercises the unchanged default path without App credentials.
- A manual dispatch against the PR branch passes all three organization-access paths.
- Probe logs show the cold-cache step ran before any fetch, on the two probes that can carry steps.
- The Actions run contains no private key, installation token, or credential artifact.
- Each manual probe finishes within ten minutes, except probe 1, which cannot declare a timeout and inherits `workflow.yml`'s.

### CHUNK 1.5 — Release gates — COMPLETE

Every gate is closed on head `03d657e`, verified 2026-07-31.

MERGE BLOCKER CLEARED 2026-07-31. The only outstanding blocker was the CHUNK 1.2 minimum-Nix guard failing on `macos-arm64-nix-darwin`. CHUNK 0.2 landed on that host and it now passes the guard, so no darwin consumer goes red on merge. PR #23 is ready for a human to review and land, and must stay a DRAFT until a human undrafts it. Carry forward the CHUNK 0.2 CAVEAT: `ci-runner-mac` PR #17 is still open, so the mac's compliance is branch-deployed until that merges.

WITHDRAWN DIAGNOSIS, 2026-07-31. This chunk previously recorded probe 3's red as an environment defect outside this repository — a stale entry in dell-foo's system `/etc/nix/netrc`, referred to by `netrc-file` in `/etc/nix/nix.conf`, to be fixed by `dev-infra`. That is WRONG in every part and is retracted:

- `/etc/nix/netrc` does not exist on dell-foo, and no system configuration there sets `netrc-file` at all.
- The stale credential was in the RUNNER USER's home, and this repository's own `origin/main` put it there. `setup/action.yml` and `workflow.yml` wrote `$HOME/.netrc`, `/tmp/netrc`, `$HOME/.git-credentials`, a global `credential.helper store` and `netrc-file = /tmp/netrc` in the user `nix.conf`, and cleaned up none of them. `$HOME` and `/tmp` persist across jobs on a self-hosted runner.
- The A/B check's `env -u NIX_USER_CONF_FILES` did not isolate Nix from that state; it made Nix fall back to its default user-config list and read the poisoned file. See the TRAP entry in CONSTRAINTS.
- There is NO `dev-infra` action item and NO host-side fix required. CHUNK 1.1's self-heal removes the artifacts on every invocation including the default path, so the first job to run the new script on a runner cleans it. The fix needs no host access.

Completion evidence:

- Prettier passes. VERIFIED — `prettier --check .` reports all matched files conform.
- Actionlint passes. VERIFIED — clean, with the scoped `.github/actionlint.yaml` suppression still the only exception.
- All three shell contract suites pass when run directly; `nix flake check` does not execute them. VERIFIED — 490 assertions, 0 failures: 8 runner-map-transform, 205 setup-action-structure, 277 workflow-structure. The runner-map suite needs `yq`, so run it as CI does, under `nix shell nixpkgs#yq-go`. The count rose from 477 with the regression guards that fail if any cleanup function shells out at all, or if a filtered copy is ever staged on disk.
- `nix flake check` passes. VERIFIED — `devShells` only, as CONSTRAINTS records; it evaluates no suite.
- The normal pull-request checks pass. VERIFIED — run 30610386952 on head `03d657e`, all green: `lints`, both `setup-composite-smoke` platforms, and the full `ci` matrix. The four probe jobs correctly report `skipping` on a pull request.
- The pull request links to the successful manual probe run. VERIFIED — dispatch 30610388212 on head `03d657e` is green in every job, including all three probes and `probe-log-credential-audit`.
- Probe 3, the self-hosted standalone-auth probe, PASSES. All twelve steps succeeded. It proved: no SSH is reachable (no agent socket, `GIT_SSH_COMMAND=false`, no key on disk); private `infra-base` clones over HTTPS on App credentials alone; private `nix-shared` resolves through its `git+ssh://` flake URL, which only the `insteadOf` rewrite can make work without SSH; a private Git-LFS-bearing input fetches over the token path; and the credential-free public A/B answers `HTTP error 403` "exceeded its LFS budget" while smudging `LargeFile.zip` — a real GitHub LFS API response, so endpoint discovery works — with NO 401, which is the direct refutation of the withdrawn diagnosis.
- The self-heal is observable in that run's log: `authenticate.sh: removed /tmp/netrc, a token-bearing file earlier revisions of this repository left at a fixed path`, followed by the checkout-header clear. Nothing token-bearing survived the job: `_temp` is empty afterwards.

## POST-MERGE ACCEPTANCE

No separate live acceptance step is required. The manual probe runs the exact branch revision in GitHub Actions before merge, and normal push validation remains the detector for the published `main` revision.
