#!/usr/bin/env bash
set -euo pipefail

# Contract tests for setup/action.yml — the composite action extracted from
# workflow.yml's build job. Asserts the action exists at the expected path,
# declares the expected inputs, and contains the steps that consumers
# (workflow.yml + any bespoke caller in another repo) rely on.
#
# Pattern modelled after tests/workflow-structure/test.sh — pure shell, no
# YAML parser, structural grep + line-bounded block extraction.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ACTION="$REPO_ROOT/setup/action.yml"

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

# --- File exists at the conventional path ---

if [[ -f "$ACTION" ]]; then
  pass "setup/action.yml exists"
else
  fail "setup/action.yml does not exist (expected at $ACTION)"
  echo ""
  echo "Results: $passed passed, $failed failed"
  exit 1
fi

# --- Declared as a composite action ---

if grep -qE '^[[:space:]]*using:[[:space:]]*"composite"' "$ACTION" || \
   grep -qE "^[[:space:]]*using:[[:space:]]*'composite'" "$ACTION" || \
   grep -qE "^[[:space:]]*using:[[:space:]]*composite" "$ACTION"; then
  pass "action declares 'using: composite'"
else
  fail "action does not declare 'using: composite'"
fi

# --- All expected inputs are declared ---

expected_inputs=(enable-ssh-agent ssh-private-key enable-lfs fetch-depth checkout)
for input_name in "${expected_inputs[@]}"; do
  if grep -qE "^[[:space:]]+${input_name}:" "$ACTION"; then
    pass "input declared: $input_name"
  else
    fail "input missing: $input_name"
  fi
done

# --- ssh-private-key input is documented as sensitive (no echo to logs) ---
# Composite inputs don't have a 'sensitive' flag; we just check the
# description mentions it's secret/sensitive so consumers know.

if grep -A6 '^[[:space:]]*ssh-private-key:' "$ACTION" | grep -qiE 'secret|sensitive|private'; then
  pass "ssh-private-key input description mentions secret/sensitive/private"
else
  fail "ssh-private-key input description does not mention secret/sensitive/private"
fi

# --- Default values are sane ---
# Mirrors the tests/workflow-structure/test.sh `check-dev-shells` pattern —
# grep -A<N> for a generous window; assert `default: <value>` appears.

if grep -A8 '^[[:space:]]*enable-ssh-agent:' "$ACTION" | grep -qE "^[[:space:]]+default:[[:space:]]*['\"]?false['\"]?"; then
  pass "enable-ssh-agent defaults to false"
else
  fail "enable-ssh-agent does not default to false"
fi

if grep -A8 '^[[:space:]]*enable-lfs:' "$ACTION" | grep -qE "^[[:space:]]+default:[[:space:]]*['\"]?false['\"]?"; then
  pass "enable-lfs defaults to false"
else
  fail "enable-lfs does not default to false"
fi

if grep -A8 '^[[:space:]]*checkout:' "$ACTION" | grep -qE "^[[:space:]]+default:[[:space:]]*['\"]?true['\"]?"; then
  pass "checkout defaults to true"
else
  fail "checkout does not default to true"
fi

# --- Required step names are present ---
# These are the steps consumers rely on. If any go missing the contract is
# broken even if the action.yml still parses cleanly.

required_steps=(
  "Clean up stale git extraHeader config"
  "Authenticate git / Nix to github.com"
  "Clean up stale magic-nix-cache daemon"
  "Add GitHub SSH host keys"
)
for step_name in "${required_steps[@]}"; do
  if grep -qE "name:[[:space:]]*${step_name}" "$ACTION"; then
    pass "step exists: $step_name"
  else
    fail "step missing: $step_name"
  fi
done

# --- The authenticate step writes the same three credential surfaces as before ---

authenticate_block=""
in_step=false
while IFS= read -r line; do
  if [[ "$line" == *"name: Authenticate git / Nix to github.com"* ]]; then
    in_step=true
    authenticate_block+="$line"$'\n'
    continue
  fi
  if $in_step; then
    # End of step: next "- name:" at the same indent level.
    if [[ "$line" =~ ^[[:space:]]*-[[:space:]]+(name:|uses:) ]]; then
      break
    fi
    authenticate_block+="$line"$'\n'
  fi
done < "$ACTION"

if echo "$authenticate_block" | grep -qE 'GITHUB_TOKEN:[[:space:]]*\$\{\{[[:space:]]*github\.token[[:space:]]*\}\}'; then
  pass "Authenticate step sets GITHUB_TOKEN: \${{ github.token }}"
else
  fail "Authenticate step does not set GITHUB_TOKEN: \${{ github.token }}"
fi

for surface in '\$\{?HOME\}?/\.netrc|~/.netrc' '/tmp/netrc' '~/\.git-credentials|\$\{?HOME\}?/\.git-credentials'; do
  if echo "$authenticate_block" | grep -qE "$surface"; then
    pass "Authenticate step writes to surface matching: $surface"
  else
    fail "Authenticate step does not write to surface matching: $surface"
  fi
done

if echo "$authenticate_block" | grep -qE 'credential\.helper[[:space:]]+store'; then
  pass "Authenticate step sets credential.helper store"
else
  fail "Authenticate step does not set credential.helper store"
fi

# --- The authenticate step is unconditional (no if: gate) ---

if echo "$authenticate_block" | grep -qE '^\s*if:'; then
  fail "Authenticate step has an if: gate (must run unconditionally)"
else
  pass "Authenticate step is unconditional"
fi

# --- Regression guard: no git config --global http.extraHeader (setting) ---

extra_header_hits="$(grep -E 'git config --global[^|]*http\..*\.extraHeader' "$ACTION" | grep -vE -- '--unset' || true)"
if [ -n "$extra_header_hits" ]; then
  fail "action sets git config --global http.extraHeader (regression)"
else
  pass "action does not set git config --global http.extraHeader"
fi

# --- ssh-agent step is gated on enable-ssh-agent input ---
# action.yml has the ssh-agent step as a `name:`-led block with `if:` and
# `uses:` siblings. Extract a 4-line window starting at the name and
# require both the gate and the uses: line to appear within it.

ssh_agent_window="$(grep -A4 -E 'name:[[:space:]]*Start ssh-agent' "$ACTION" || true)"

if [[ -n "$ssh_agent_window" ]] && echo "$ssh_agent_window" | grep -q 'webfactory/ssh-agent'; then
  pass "Start ssh-agent step references webfactory/ssh-agent"
else
  fail "Start ssh-agent step does not reference webfactory/ssh-agent"
fi

if echo "$ssh_agent_window" | grep -qE "if:.*inputs\.enable-ssh-agent"; then
  pass "Start ssh-agent step is gated on inputs.enable-ssh-agent"
else
  fail "Start ssh-agent step is not gated on inputs.enable-ssh-agent"
fi

# --- LFS install steps are gated on enable-lfs AND on runner.os ---

linux_lfs_found=false
macos_lfs_found=false
while IFS= read -r line; do
  if [[ "$line" =~ Install\ git-lfs\ \(Linux\) ]]; then linux_lfs_found=true; fi
  if [[ "$line" =~ Install\ git-lfs\ \(macOS\) ]]; then macos_lfs_found=true; fi
done < "$ACTION"

if $linux_lfs_found; then
  pass "Install git-lfs (Linux) step exists"
else
  fail "Install git-lfs (Linux) step missing"
fi

if $macos_lfs_found; then
  pass "Install git-lfs (macOS) step exists"
else
  fail "Install git-lfs (macOS) step missing"
fi

# --- determinate-nix-action step is configured with netrc-file ---

if grep -A5 'DeterminateSystems/determinate-nix-action' "$ACTION" | grep -qE 'netrc-file[[:space:]]*=[[:space:]]*/tmp/netrc'; then
  pass "Determinate Nix step wires netrc-file = /tmp/netrc"
else
  fail "Determinate Nix step does not wire netrc-file = /tmp/netrc"
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
