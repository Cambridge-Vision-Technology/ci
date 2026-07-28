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

# --- Inline and composite setup contracts remain in parity ---

required_setup_steps=(
  "name: Install git-lfs (Linux)"
  "name: Install git-lfs (macOS)"
  "name: Ensure LFS files are checked out"
  "name: Clean up stale git extraHeader config"
  "name: Detect existing Nix"
  "name: Install Nix when absent"
  "name: Configure Nix netrc"
)
for setup_surface in "$WORKFLOW" "$REPO_ROOT/setup/action.yml"; do
  for required in "${required_setup_steps[@]}"; do
    if grep -qF "$required" "$setup_surface"; then
      pass "setup contract present in $(basename "$setup_surface"): $required"
    else
      fail "setup contract missing from $(basename "$setup_surface"): $required"
    fi
  done
done

if echo "$build_block" | grep -qE 'name: Authenticate git / Nix to github\.com'; then
  pass "build job has an inline Git and Nix authentication step"
else
  fail "build job does not have an inline Git and Nix authentication step"
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

install_nix_block="$(extract_named_build_step 'Install Nix when absent')"
detect_nix_block="$(extract_named_build_step 'Detect existing Nix')"
configure_netrc_block="$(extract_named_build_step 'Configure Nix netrc')"

detect_nix_line="$(awk 'index($0, "name: Detect existing Nix") { print NR; exit }' "$WORKFLOW")"
install_nix_line="$(awk 'index($0, "name: Install Nix when absent") { print NR; exit }' "$WORKFLOW")"

if echo "$detect_nix_block" | grep -qE '^[[:space:]]*id:[[:space:]]*nix-detection[[:space:]]*$'; then
  pass "Nix detection step has id: nix-detection"
else
  fail "Nix detection step does not have id: nix-detection"
fi

if [[ -n "$detect_nix_line" && -n "$install_nix_line" && "$detect_nix_line" -lt "$install_nix_line" ]]; then
  pass "Nix detection runs before conditional installation"
else
  fail "Nix detection must run before conditional installation"
fi

if printf '%s\n' "$detect_nix_block" | awk '
  BEGIN { state = "before"; valid = 1 }
  /^[[:space:]]*if[[:space:]]+command[[:space:]]+-v[[:space:]]+nix([[:space:];]|$)/ {
    if (state != "before") valid = 0
    state = "present"
    next
  }
  /^[[:space:]]*else[[:space:]]*$/ {
    if (state != "present" || !present_true) valid = 0
    state = "absent"
    next
  }
  /^[[:space:]]*fi[[:space:]]*$/ {
    if (state != "absent" || !present_false) valid = 0
    state = "after"
    next
  }
  /present=true/ && /\$GITHUB_OUTPUT/ {
    if (state != "present" || present_true) valid = 0
    present_true = 1
  }
  /present=false/ && /\$GITHUB_OUTPUT/ {
    if (state != "absent" || present_false) valid = 0
    present_false = 1
  }
  END { exit !(valid && state == "after" && present_true && present_false) }
'; then
  pass "Nix detection writes GITHUB_OUTPUT values in command -v success and else branches"
else
  fail "Nix detection must write present=true only after command -v nix succeeds and present=false in its else branch"
fi

if echo "$install_nix_block" | grep -qF "if: \${{ steps.nix-detection.outputs.present != 'true' }}"; then
  pass "upstream installation runs only when Nix is absent"
else
  fail "upstream installation is not conditional on absent Nix"
fi

if echo "$install_nix_block" | grep -qF 'cachix/install-nix-action@630ae543ea3a38a9a4166f03376c02c50f408342 # v31.11.0'; then
  pass "upstream installer is pinned to cachix/install-nix-action v31.11.0"
else
  fail "upstream installer is not pinned to cachix/install-nix-action v31.11.0"
fi

if echo "$install_nix_block" | grep -qF 'github_access_token: ${{ inputs.enable-github-app-auth && steps.github-app-token.outputs.token || github.token }}'; then
  pass "upstream installer selects the repository or GitHub App token"
else
  fail "upstream installer does not select the repository or GitHub App token"
fi

if grep -qi 'determinate' "$WORKFLOW"; then
  fail "workflow still references Determinate"
else
  pass "workflow has no Determinate references"
fi

if grep -qi 'magic-nix-cache' "$WORKFLOW"; then
  fail "workflow still references magic-nix-cache"
else
  pass "workflow has no magic-nix-cache references"
fi

if echo "$install_nix_block" | grep -q 'netrc-file'; then
  fail "upstream installer configures netrc-file instead of the separate Nix configuration step"
else
  pass "upstream installer leaves netrc configuration separate"
fi

if echo "$configure_netrc_block" | grep -qF 'netrc-file = /tmp/netrc'; then
  pass "separate Nix configuration sets netrc-file = /tmp/netrc"
else
  fail "separate Nix configuration does not set netrc-file = /tmp/netrc"
fi

if echo "$configure_netrc_block" | grep -qF 'awk'; then
  fail "netrc configuration depends on awk"
else
  pass "netrc configuration does not depend on awk"
fi

configure_netrc_line="$(awk 'index($0, "name: Configure Nix netrc") { print NR; exit }' "$WORKFLOW")"
if [[ -n "$install_nix_line" && -n "$configure_netrc_line" && "$configure_netrc_line" -gt "$install_nix_line" ]] && \
   ! grep -qE '^[[:space:]]*if:' <<< "$configure_netrc_block"; then
  pass "netrc configuration runs unconditionally after conditional installation"
else
  fail "netrc configuration must run unconditionally after conditional installation"
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

# --- Pull-request CI runs every shell contract test ---

VALIDATE="$REPO_ROOT/.github/workflows/validate.yml"
contract_test_block="$(grep -A20 -F 'name: Run shell contract tests' "$VALIDATE")"

if grep -qE '^[[:space:]]*pull_request:' "$VALIDATE"; then
  pass "validation workflow runs on pull requests"
else
  fail "validation workflow does not run on pull requests"
fi

for contract_test in \
  tests/runner-map-transform/test.sh \
  tests/setup-action-structure/test.sh \
  tests/workflow-structure/test.sh; do
  if echo "$contract_test_block" | grep -qF "$contract_test"; then
    pass "pull-request CI runs $contract_test"
  else
    fail "pull-request CI does not run $contract_test"
  fi
done

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
