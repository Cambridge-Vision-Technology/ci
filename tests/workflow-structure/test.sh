#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/workflow.yml"

passed=0
failed=0

pass() {
  echo "PASS: $1"
  passed=$((passed + 1))
}

fail() {
  echo "FAIL: $1"
  failed=$((failed + 1))
}

# --- Helper: extract the build job block ---
# Captures everything between "  build:" and the next top-level job key
extract_build_block() {
  local in_build=false
  while IFS= read -r line; do
    if [[ "$line" == "  build:" ]] || [[ "$line" == "  build: "* ]]; then
      in_build=true
      continue
    fi
    if $in_build; then
      if [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z_][a-zA-Z0-9_-]*: ]] && ! [[ "$line" =~ ^[[:space:]]{3,} ]]; then
        break
      fi
      echo "$line"
    fi
  done < "$WORKFLOW"
}

# --- No unwanted FlakeHub references ---

if grep -qi 'flakehub-push' "$WORKFLOW"; then
  fail "workflow still references flakehub-push"
else
  pass "no flakehub-push references"
fi

if grep -i 'flake-iter' "$WORKFLOW" | grep -v 'DEPRECATED' | grep -v 'flake-iter-flakeref:' | grep -qi 'flake-iter'; then
  fail "workflow still references flake-iter (outside deprecated inputs)"
else
  pass "no flake-iter references (outside deprecated inputs)"
fi

if grep -qi 'flake-checker-action' "$WORKFLOW"; then
  fail "workflow still references flake-checker-action"
else
  pass "no flake-checker-action references"
fi

# --- All jobs have timeout-minutes ---

# Extract job names (top-level keys under "jobs:") and check each has timeout-minutes
job_names=()
in_jobs=false
while IFS= read -r line; do
  if [[ "$line" =~ ^jobs: ]]; then
    in_jobs=true
    continue
  fi
  if $in_jobs; then
    if [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z_][a-zA-Z0-9_-]*:[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z_][a-zA-Z0-9_-]*: ]]; then
      if ! [[ "$line" =~ ^[[:space:]]{3,} ]]; then
        job_name="$(echo "$line" | sed 's/^  //;s/:.*//')"
        job_names+=("$job_name")
      fi
    fi
  fi
done < "$WORKFLOW"

all_have_timeout=true
jobs_without_timeout=()
for job in "${job_names[@]}"; do
  in_target_job=false
  found_timeout=false
  while IFS= read -r line; do
    if [[ "$line" == "  ${job}:" ]] || [[ "$line" == "  ${job}: "* ]]; then
      in_target_job=true
      continue
    fi
    if $in_target_job; then
      if [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z_][a-zA-Z0-9_-]*: ]] && ! [[ "$line" =~ ^[[:space:]]{3,} ]]; then
        break
      fi
      if [[ "$line" =~ timeout-minutes ]]; then
        found_timeout=true
      fi
    fi
  done < "$WORKFLOW"

  if ! $found_timeout; then
    all_have_timeout=false
    jobs_without_timeout+=("$job")
  fi
done

if $all_have_timeout; then
  pass "all jobs have timeout-minutes"
else
  fail "jobs missing timeout-minutes: ${jobs_without_timeout[*]}"
fi

# --- Build job contains nix flake check ---

build_block="$(extract_build_block)"

if echo "$build_block" | grep -q 'nix flake check'; then
  pass "build job contains 'nix flake check'"
else
  fail "build job does not contain 'nix flake check'"
fi

# --- Build job contains devShell validation ---

if echo "$build_block" | grep -q 'nix develop.*--command true'; then
  pass "build job contains devShell validation step"
else
  fail "build job does not contain devShell validation step"
fi

# --- check-dev-shells input is declared ---

if grep -q 'check-dev-shells:' "$WORKFLOW"; then
  pass "check-dev-shells input is declared"
else
  fail "check-dev-shells input is not declared"
fi

# --- devShell validation does not silently swallow errors ---

# Extract the Validate devShells step block
validate_devshells_block=""
in_step=false
while IFS= read -r line; do
  if [[ "$line" == *"name: Validate devShells"* ]]; then
    in_step=true
    continue
  fi
  if $in_step; then
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(name:|uses:) ]]; then
      break
    fi
    validate_devshells_block+="$line"$'\n'
  fi
done < "$WORKFLOW"

if echo "$validate_devshells_block" | grep -q '2>/dev/null'; then
  fail "Validate devShells step contains 2>/dev/null (silently swallows errors)"
else
  pass "Validate devShells step does not contain 2>/dev/null"
fi

# --- nix eval fallback must distinguish missing-attribute from real failures ---

if echo "$validate_devshells_block" | grep -qE "\|\| echo '\[\]'"; then
  fail "Validate devShells step uses bare '|| echo []' fallback (masks genuine nix eval failures)"
else
  pass "Validate devShells step does not use bare '|| echo []' fallback"
fi

# --- Validate devShells checks for missing-attribute error specifically ---

if echo "$validate_devshells_block" | grep -q 'does not provide attribute'; then
  pass "Validate devShells step checks for 'does not provide attribute' error"
else
  fail "Validate devShells step does not check for 'does not provide attribute' error (missing-attribute detection needed)"
fi

# --- No commented-out action references ---

if grep -qE '^\s*#\s*-\s+uses:' "$WORKFLOW"; then
  fail "workflow contains commented-out action references (e.g. '# - uses:')"
else
  pass "no commented-out action references"
fi

# NOTE: determinate-nix-action + magic-nix-cache cleanup assertions moved to
# tests/setup-action-structure/test.sh — they live in setup/action.yml now.

# --- Build job has id-token: write ---

if echo "$build_block" | grep -q 'id-token.*write'; then
  pass "build job has id-token: write"
else
  fail "build job does not have id-token: write"
fi

# --- All deprecated no-op inputs are declared ---

deprecated_inputs=(visibility default-branch flake-iter-flakeref include-output-paths inventory-runner use-flake-check)
missing_deprecated=()
for input_name in "${deprecated_inputs[@]}"; do
  if grep -q "^      ${input_name}:" "$WORKFLOW"; then
    :
  else
    missing_deprecated+=("$input_name")
  fi
done

if [ ${#missing_deprecated[@]} -eq 0 ]; then
  pass "all 6 deprecated no-op inputs are declared"
else
  fail "missing deprecated inputs: ${missing_deprecated[*]}"
fi

# --- check-dev-shells defaults to true ---

if grep -A8 'check-dev-shells:' "$WORKFLOW" | grep -q 'default: true'; then
  pass "check-dev-shells defaults to true"
else
  fail "check-dev-shells does not default to true"
fi

# --- Validate devShells step has correct if condition ---

if grep -B1 -A1 'name: Validate devShells' "$WORKFLOW" | grep -q "if: \${{ inputs.check-dev-shells }}"; then
  pass "Validate devShells step has correct if condition"
else
  fail "Validate devShells step does not have correct if condition"
fi

# --- Build job uses determinate-nix-action (inline; not via composite) ---
#
# workflow.yml duplicates the setup steps inline rather than calling the
# setup/action.yml composite. See the long comment in workflow.yml — GHA's
# reusable-workflow + local-action interaction is hostile to single-source-
# of-truth here. The setup composite at setup/action.yml exists as a
# parallel artifact for BESPOKE downstream workflows (e.g. infra's
# state-plan-on-pr.yml) to consume directly, NOT for workflow.yml to
# dogfood.
#
# tests/setup-action-structure/test.sh asserts the composite's shape;
# this file asserts workflow.yml has the matching inline steps. If the
# two drift, both test suites still pass — drift detection lives in the
# named-step parity assertions below.

if echo "$build_block" | grep -qi 'determinate-nix-action'; then
  pass "build job uses determinate-nix-action"
else
  fail "build job does not use determinate-nix-action"
fi

if echo "$build_block" | grep -qE 'pkill.*magic-nix-cache'; then
  pass "build job has magic-nix-cache cleanup step"
else
  fail "build job does not have magic-nix-cache cleanup step"
fi

if echo "$build_block" | grep -qE 'name: Authenticate git / Nix to github\.com'; then
  pass "build job has 'Authenticate git / Nix to github.com' step (inline)"
else
  fail "build job does not have 'Authenticate git / Nix to github.com' step"
fi

if echo "$build_block" | grep -qE 'name: Add GitHub SSH host keys'; then
  pass "build job has 'Add GitHub SSH host keys' step (inline)"
else
  fail "build job does not have 'Add GitHub SSH host keys' step"
fi

if echo "$build_block" | grep -qE 'webfactory/ssh-agent'; then
  pass "build job has webfactory/ssh-agent reference (inline)"
else
  fail "build job does not have webfactory/ssh-agent reference"
fi

# --- Required inline setup steps in workflow.yml (drift detection vs composite) ---
#
# These step names MUST appear inline in workflow.yml AND in setup/action.yml
# (asserted separately by tests/setup-action-structure/test.sh). If one file
# is edited without the other, one suite goes red.

required_inline_steps=(
  "name: Install git-lfs (Linux)"
  "name: Install git-lfs (macOS)"
  "name: Ensure LFS files are checked out"
  "name: Clean up stale magic-nix-cache daemon"
  "name: Clean up stale git extraHeader config"
)
for required in "${required_inline_steps[@]}"; do
  # -F (fixed string) so the `(Linux)` / `(macOS)` parens aren't treated
  # as regex grouping metacharacters.
  if grep -qF "${required}" "$WORKFLOW"; then
    pass "inline step present in workflow.yml: ${required}"
  else
    fail "inline step missing from workflow.yml (drift vs setup/action.yml): ${required}"
  fi
done

# --- Authenticate-step internals (regression assertions kept inline since
#     workflow.yml owns the inline version; the composite's copy is asserted
#     in tests/setup-action-structure/test.sh). ---

authenticate_block=""
in_step=false
while IFS= read -r line; do
  if [[ "$line" == *"name: Authenticate git / Nix to github.com"* ]]; then
    in_step=true
    authenticate_block+="$line"$'\n'
    continue
  fi
  if $in_step; then
    if [[ "$line" =~ ^[[:space:]]{6}-[[:space:]]+(name:|uses:) ]]; then
      break
    fi
    authenticate_block+="$line"$'\n'
  fi
done < "$WORKFLOW"

if echo "$authenticate_block" | grep -qE 'GITHUB_TOKEN:[[:space:]]*\$\{\{[[:space:]]*github\.token[[:space:]]*\}\}'; then
  pass "Authenticate step sets GITHUB_TOKEN: \${{ github.token }}"
else
  fail "Authenticate step does not set GITHUB_TOKEN: \${{ github.token }}"
fi

if echo "$authenticate_block" | grep -qE '\$\{?HOME\}?/\.netrc|~/.netrc'; then
  pass "Authenticate step writes to \${HOME}/.netrc"
else
  fail "Authenticate step does not write to \${HOME}/.netrc"
fi

if echo "$authenticate_block" | grep -q '/tmp/netrc'; then
  pass "Authenticate step writes to /tmp/netrc"
else
  fail "Authenticate step does not write to /tmp/netrc"
fi

if echo "$authenticate_block" | grep -qE '~/\.git-credentials|\$\{?HOME\}?/\.git-credentials'; then
  pass "Authenticate step writes to ~/.git-credentials"
else
  fail "Authenticate step does not write to ~/.git-credentials"
fi

if echo "$authenticate_block" | grep -qE 'credential\.helper[[:space:]]+store'; then
  pass "Authenticate step sets credential.helper store"
else
  fail "Authenticate step does not set credential.helper store"
fi

# --- Optional GitHub App authentication contract ---

# Extract a named build step, including its name line, through the next step.
extract_named_build_step() {
  local step_name="$1"
  local in_step=false
  while IFS= read -r line; do
    if [[ "$line" == *"name: ${step_name}" ]]; then
      in_step=true
      echo "$line"
      continue
    fi
    if $in_step; then
      if [[ "$line" =~ ^[[:space:]]{6}-[[:space:]]+(name:|uses:) ]]; then
        break
      fi
      echo "$line"
    fi
  done < "$WORKFLOW"
}

if grep -A8 '^      enable-github-app-auth:' "$WORKFLOW" | grep -q 'default: false'; then
  pass "enable-github-app-auth input is opt-in by default"
else
  fail "enable-github-app-auth input is missing or not opt-in by default"
fi

if grep -q '^      github-app-id:' "$WORKFLOW" && \
   grep -q '^      github-app-private-key:' "$WORKFLOW"; then
  pass "GitHub App ID and private-key secrets are declared"
else
  fail "GitHub App ID and private-key secrets are not both declared"
fi

app_token_block="$(extract_named_build_step 'Mint GitHub App organization installation token')"

if echo "$app_token_block" | grep -qF 'if: ${{ inputs.enable-github-app-auth }}'; then
  pass "GitHub App token minting is enabled only in App-auth mode"
else
  fail "GitHub App token minting is not gated by enable-github-app-auth"
fi

if echo "$app_token_block" | grep -qF 'actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0'; then
  pass "GitHub App token action is pinned to v3.2.0 commit"
else
  fail "GitHub App token action is not pinned to the required v3.2.0 commit"
fi

if echo "$app_token_block" | grep -qF 'app-id: ${{ secrets.github-app-id }}' && \
   echo "$app_token_block" | grep -qF 'private-key: ${{ secrets.github-app-private-key }}' && \
   echo "$app_token_block" | grep -qF 'owner: ${{ github.repository_owner }}'; then
  pass "GitHub App token uses caller credentials for the repository owner installation"
else
  fail "GitHub App token does not use caller credentials and repository owner installation"
fi

if echo "$app_token_block" | grep -qF 'permission-contents: read'; then
  pass "GitHub App token is downscoped to contents: read"
else
  fail "GitHub App token is not downscoped to contents: read"
fi

repository_auth_block="$(extract_named_build_step 'Authenticate git / Nix to github.com (repository token)')"
app_auth_block="$(extract_named_build_step 'Authenticate git / Nix to github.com (GitHub App token)')"

if echo "$repository_auth_block" | grep -qF 'if: ${{ !inputs.enable-github-app-auth }}' && \
   echo "$repository_auth_block" | grep -qF 'GITHUB_TOKEN: ${{ github.token }}'; then
  pass "repository token authentication remains the default path"
else
  fail "repository token authentication is not limited to the default path"
fi

if echo "$app_auth_block" | grep -qF 'if: ${{ inputs.enable-github-app-auth }}' && \
   echo "$app_auth_block" | grep -qF 'GITHUB_TOKEN: ${{ steps.github-app-token.outputs.token }}' && \
   ! echo "$app_auth_block" | grep -qF 'github.token'; then
  pass "App-auth mode uses only the minted token for Git and Nix authentication"
else
  fail "App-auth mode can fall back to github.token or does not use the minted token"
fi

ssh_rewrite_block="$(extract_named_build_step 'Rewrite GitHub SSH URLs to HTTPS')"

if echo "$ssh_rewrite_block" | grep -qF 'if: ${{ inputs.enable-github-app-auth }}' && \
   echo "$ssh_rewrite_block" | grep -qF 'url."https://github.com/".insteadOf "git@github.com:"' && \
   echo "$ssh_rewrite_block" | grep -qF 'url."https://github.com/".insteadOf "ssh://git@github.com/"' && \
   echo "$ssh_rewrite_block" | grep -qF 'url."https://github.com/".insteadOf "git+ssh://git@github.com/"' && \
   grep -A2 'name: Clean up stale GitHub SSH URL rewrites' "$WORKFLOW" | grep -qF 'url."https://github.com/".insteadOf'; then
  pass "GitHub SSH URL rewriting to HTTPS is limited to App-auth mode"
else
  fail "GitHub SSH URL rewriting is missing, incomplete, or not conditional on App-auth mode"
fi

# --- Regression guard: no git config --global http.extraHeader (setting) ---

extra_header_hits="$(grep -E 'git config --global[^|]*http\..*\.extraHeader' "$WORKFLOW" | grep -vE -- '--unset' || true)"
if [ -n "$extra_header_hits" ]; then
  fail "workflow sets git config --global http.extraHeader (regression)"
else
  pass "workflow does not set git config --global http.extraHeader"
fi

# --- Summary ---

echo ""
echo "================================"
echo "Results: $passed passed, $failed failed"
echo "================================"

if [ "$failed" -gt 0 ]; then
  exit 1
fi
exit 0
