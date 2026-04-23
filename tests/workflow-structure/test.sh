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

# --- Security scan: extract block helper ---
extract_security_scan_block() {
  local in_block=false
  while IFS= read -r line; do
    if [[ "$line" == "  security-scan:" ]] || [[ "$line" == "  security-scan: "* ]]; then
      in_block=true
      continue
    fi
    if $in_block; then
      if [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z_][a-zA-Z0-9_-]*: ]] && ! [[ "$line" =~ ^[[:space:]]{3,} ]]; then
        break
      fi
      echo "$line"
    fi
  done < "$WORKFLOW"
}

# --- Security scan: enable-security input is declared, defaults to false ---

if grep -q '^      enable-security:' "$WORKFLOW"; then
  pass "enable-security input is declared"
else
  fail "enable-security input is not declared"
fi

if grep -A8 '^      enable-security:' "$WORKFLOW" | grep -q 'default: false'; then
  pass "enable-security defaults to false (opt-in rollout)"
else
  fail "enable-security does not default to false"
fi

# --- Security scan: job exists and is gated ---

security_scan_block="$(extract_security_scan_block)"

if [ -n "$security_scan_block" ]; then
  pass "security-scan job exists"
else
  fail "security-scan job does not exist"
fi

if echo "$security_scan_block" | grep -qE 'if:.*inputs\.enable-security'; then
  pass "security-scan job is gated by inputs.enable-security"
else
  fail "security-scan job is not gated by inputs.enable-security"
fi

# --- Security scan: SARIF permissions + upload ---

if echo "$security_scan_block" | grep -qE 'security-events:\s*write'; then
  pass "security-scan job has security-events: write permission"
else
  fail "security-scan job does not have security-events: write permission"
fi

if echo "$security_scan_block" | grep -q 'github/codeql-action/upload-sarif'; then
  pass "security-scan job uploads SARIF via codeql-action"
else
  fail "security-scan job does not upload SARIF via codeql-action"
fi

# --- Security scan: invokes the scanner via nix run github: + workflow_sha pin ---

if echo "$security_scan_block" | grep -q 'nix run "github:Cambridge-Vision-Technology/ci'; then
  pass "security-scan invokes nix run github:Cambridge-Vision-Technology/ci"
else
  fail "security-scan does not invoke nix run github:Cambridge-Vision-Technology/ci"
fi

if echo "$security_scan_block" | grep -qE 'github:Cambridge-Vision-Technology/ci/(main|feat/security-scanning)#security-scan'; then
  pass "security-scan pins scanner to a ci repo ref"
else
  fail "security-scan does not pin scanner to a ci repo ref"
fi

# --- Security scan: job summary + SBOM submission ---

if echo "$security_scan_block" | grep -q 'GITHUB_STEP_SUMMARY'; then
  pass "security-scan writes to GITHUB_STEP_SUMMARY"
else
  fail "security-scan does not write to GITHUB_STEP_SUMMARY"
fi

if echo "$security_scan_block" | grep -qi 'spdx-dependency-submission-action'; then
  pass "security-scan submits SBOM via spdx-dependency-submission-action"
else
  fail "security-scan does not submit SBOM"
fi

# --- Security scan: fails the job when scanner reports findings ---

if echo "$security_scan_block" | grep -qE "steps\.scan\.outcome == 'failure'"; then
  pass "security-scan fails when scanner reports un-suppressed findings"
else
  fail "security-scan does not fail when scanner reports un-suppressed findings"
fi

# --- Security scan: success.needs includes security-scan ---

if grep -A3 '^  success:' "$WORKFLOW" | grep -qE 'needs:.*security-scan'; then
  pass "success.needs includes security-scan"
else
  fail "success.needs does not include security-scan"
fi

# --- Security scan: all jobs timeout-minutes check already covers this (generic check above) ---

# --- Summary ---

echo ""
echo "================================"
echo "Results: $passed passed, $failed failed"
echo "================================"

if [ "$failed" -gt 0 ]; then
  exit 1
fi
exit 0
