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

# --- Build job uses determinate-nix-action ---

if echo "$build_block" | grep -qi 'determinate-nix-action'; then
  pass "build job uses determinate-nix-action"
else
  fail "build job does not use determinate-nix-action"
fi

# --- Build job uses flakehub-cache-action ---

if echo "$build_block" | grep -qi 'flakehub-cache-action'; then
  pass "build job uses flakehub-cache-action"
else
  fail "build job does not use flakehub-cache-action"
fi

# --- Build job has cleanup step for stale magic-nix-cache ---

if echo "$build_block" | grep -qE 'pkill.*magic-nix-cache'; then
  pass "build job has magic-nix-cache cleanup step"
else
  fail "build job does not have magic-nix-cache cleanup step"
fi

# --- flakehub-cache-action uses startup-notification-port: 0 ---

if echo "$build_block" | grep -q 'startup-notification-port.*0'; then
  pass "flakehub-cache-action uses startup-notification-port: 0"
else
  fail "flakehub-cache-action does not use startup-notification-port: 0"
fi

# --- flakehub-cache-action uses listen: 127.0.0.1:0 ---

if echo "$build_block" | grep -q 'listen.*127\.0\.0\.1:0'; then
  pass "flakehub-cache-action uses listen: 127.0.0.1:0"
else
  fail "flakehub-cache-action does not use listen: 127.0.0.1:0"
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

# --- Authenticate git / Nix to github.com: step exists (issue #14) ---

if grep -qE 'name: Authenticate git / Nix to github\.com' "$WORKFLOW"; then
  pass "Authenticate git / Nix to github.com step exists"
else
  fail "Authenticate git / Nix to github.com step does not exist"
fi

# --- Extract the Authenticate step block for further assertions ---

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

# --- Authenticate step is unconditional (no if: referencing enable-lfs) ---

if echo "$authenticate_block" | grep -qE '^\s*if:.*enable-lfs'; then
  fail "Authenticate step has an if: condition referencing enable-lfs (must be unconditional)"
else
  pass "Authenticate step has no if: enable-lfs guard"
fi

# --- Authenticate step env includes GITHUB_TOKEN: ${{ github.token }} ---

if echo "$authenticate_block" | grep -qE 'GITHUB_TOKEN:[[:space:]]*\$\{\{[[:space:]]*github\.token[[:space:]]*\}\}'; then
  pass "Authenticate step sets GITHUB_TOKEN: \${{ github.token }} in env"
else
  fail "Authenticate step does not set GITHUB_TOKEN: \${{ github.token }} in env"
fi

# --- Authenticate step writes ${HOME}/.netrc ---

if echo "$authenticate_block" | grep -qE '\$\{?HOME\}?/\.netrc|~/.netrc'; then
  pass "Authenticate step writes to \${HOME}/.netrc"
else
  fail "Authenticate step does not write to \${HOME}/.netrc"
fi

# --- Authenticate step writes /tmp/netrc ---

if echo "$authenticate_block" | grep -q '/tmp/netrc'; then
  pass "Authenticate step writes to /tmp/netrc"
else
  fail "Authenticate step does not write to /tmp/netrc"
fi

# --- Authenticate step writes ~/.git-credentials ---

if echo "$authenticate_block" | grep -qE '~/\.git-credentials|\$\{?HOME\}?/\.git-credentials'; then
  pass "Authenticate step writes to ~/.git-credentials"
else
  fail "Authenticate step does not write to ~/.git-credentials"
fi

# --- Authenticate step configures credential.helper store ---

if echo "$authenticate_block" | grep -qE 'credential\.helper[[:space:]]+store'; then
  pass "Authenticate step sets credential.helper store"
else
  fail "Authenticate step does not set credential.helper store"
fi

# --- Old conditional 'Configure credentials for LFS' step is removed ---

if grep -qE 'name: Configure credentials for LFS' "$WORKFLOW"; then
  fail "old 'Configure credentials for LFS' step still exists (should be removed/renamed)"
else
  pass "old 'Configure credentials for LFS' step has been removed"
fi

# --- Regression guard: no git config --global http.extraHeader (setting) ---

extra_header_hits="$(grep -E 'git config --global[^|]*http\..*\.extraHeader' "$WORKFLOW" | grep -vE -- '--unset' || true)"
if [ -n "$extra_header_hits" ]; then
  fail "workflow sets git config --global http.extraHeader (regression)"
else
  pass "workflow does not set git config --global http.extraHeader"
fi

# --- Preserve existing 'Clean up stale git extraHeader config' step ---

if grep -qE 'name: Clean up stale git extraHeader config' "$WORKFLOW"; then
  pass "'Clean up stale git extraHeader config' step is preserved"
else
  fail "'Clean up stale git extraHeader config' step is missing (must be preserved)"
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
