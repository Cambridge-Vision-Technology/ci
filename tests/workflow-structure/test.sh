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

# --- No FlakeHub references remain ---

if grep -qi 'flakehub-cache-action' "$WORKFLOW"; then
  fail "workflow still references flakehub-cache-action"
else
  pass "no flakehub-cache-action references"
fi

if grep -qi 'flakehub-push' "$WORKFLOW"; then
  fail "workflow still references flakehub-push"
else
  pass "no flakehub-push references"
fi

if grep -qi 'flake-iter' "$WORKFLOW"; then
  fail "workflow still references flake-iter"
else
  pass "no flake-iter references"
fi

if grep -qi 'determinate-nix-action' "$WORKFLOW"; then
  fail "workflow still references determinate-nix-action"
else
  pass "no determinate-nix-action references"
fi

if grep -qi 'flake-checker-action' "$WORKFLOW"; then
  fail "workflow still references flake-checker-action"
else
  pass "no flake-checker-action references"
fi

# --- All jobs have timeout-minutes ---

# Extract job names (top-level keys under "jobs:") and check each has timeout-minutes
in_jobs=false
current_job=""
jobs_without_timeout=()

while IFS= read -r line; do
  # Detect start of jobs block
  if [[ "$line" =~ ^jobs: ]]; then
    in_jobs=true
    continue
  fi

  if $in_jobs; then
    # A top-level job is a line with exactly 2 spaces of indent followed by a word and colon
    if [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z_][a-zA-Z0-9_-]*: ]] && ! [[ "$line" =~ ^[[:space:]]{3,} ]]; then
      current_job="$(echo "$line" | sed 's/^  //;s/:.*//')"
    fi
  fi
done < "$WORKFLOW"

# Now for each job, check if timeout-minutes appears in its block
# We do this by extracting job blocks with awk-like logic
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
for job in "${job_names[@]}"; do
  # Extract the block for this job and check for timeout-minutes
  # A job block starts at "  <job>:" and ends at the next "  <other>:" at the same indent level
  in_target_job=false
  found_timeout=false
  while IFS= read -r line; do
    if [[ "$line" == "  ${job}:" ]] || [[ "$line" == "  ${job}: "* ]]; then
      in_target_job=true
      continue
    fi
    if $in_target_job; then
      # Check if we've reached the next job (2-space indent, word followed by colon)
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

# --- No id-token permission ---

if grep -q 'id-token' "$WORKFLOW"; then
  fail "workflow still contains id-token permission"
else
  pass "no id-token permission found"
fi

# --- Build job contains nix flake check ---

# Extract the build job block and look for "nix flake check"
in_build=false
found_flake_check=false
while IFS= read -r line; do
  if [[ "$line" == "  build:" ]] || [[ "$line" == "  build: "* ]]; then
    in_build=true
    continue
  fi
  if $in_build; then
    if [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z_][a-zA-Z0-9_-]*: ]] && ! [[ "$line" =~ ^[[:space:]]{3,} ]]; then
      break
    fi
    if [[ "$line" =~ "nix flake check" ]]; then
      found_flake_check=true
    fi
  fi
done < "$WORKFLOW"

if $found_flake_check; then
  pass "build job contains 'nix flake check'"
else
  fail "build job does not contain 'nix flake check'"
fi

# --- No commented-out action references ---

if grep -qE '^\s*#\s*-\s+uses:' "$WORKFLOW"; then
  fail "workflow contains commented-out action references (e.g. '# - uses:')"
else
  pass "no commented-out action references"
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
