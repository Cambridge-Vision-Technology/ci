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

# The jq transform that will be used in the inventory job
transform() {
  echo "$1" | jq -c '[to_entries[] | {"nix-system": .key, "runner": .value}]'
}

# --- Test 1: Default 2-system runner-map produces correct array with 2 entries ---

DEFAULT_RUNNER_MAP="$(yq -r '.on.workflow_call.inputs."runner-map".default' "$WORKFLOW")"

result="$(transform "$DEFAULT_RUNNER_MAP")"
count="$(echo "$result" | jq 'length')"

if [ "$count" -eq 2 ]; then
  pass "default 2-system runner-map produces array with 2 entries"
else
  fail "default 2-system runner-map: expected 2 entries, got $count"
fi

# Verify each entry has both nix-system and runner keys
valid_keys=true
for i in 0 1; do
  has_nix_system="$(echo "$result" | jq ".[$i] | has(\"nix-system\")")"
  has_runner="$(echo "$result" | jq ".[$i] | has(\"runner\")")"
  if [ "$has_nix_system" != "true" ] || [ "$has_runner" != "true" ]; then
    valid_keys=false
  fi
done

if $valid_keys; then
  pass "default runner-map entries all have nix-system and runner keys"
else
  fail "default runner-map entries missing nix-system or runner keys"
fi

# Verify specific mapping: x86_64-linux -> x86_64-linux
has_x86="$(echo "$result" | jq '[.[] | select(."nix-system" == "x86_64-linux" and .runner == "x86_64-linux")] | length')"
if [ "$has_x86" -eq 1 ]; then
  pass "default runner-map contains x86_64-linux -> x86_64-linux mapping"
else
  fail "default runner-map missing x86_64-linux -> x86_64-linux mapping"
fi

# Verify default runner-map does NOT contain aarch64-linux
has_aarch64_linux="$(echo "$result" | jq '[.[] | select(."nix-system" == "aarch64-linux")] | length')"
if [ "$has_aarch64_linux" -eq 0 ]; then
  pass "default runner-map does not contain aarch64-linux"
else
  fail "default runner-map should not contain aarch64-linux"
fi

# Verify default runner-map contains macos-arm64-nix-darwin as a runner value
has_macos_self_hosted="$(echo "$result" | jq '[.[] | select(.runner == "macos-arm64-nix-darwin")] | length')"
if [ "$has_macos_self_hosted" -eq 1 ]; then
  pass "default runner-map contains macos-arm64-nix-darwin runner"
else
  fail "default runner-map missing macos-arm64-nix-darwin runner"
fi

# --- Test 2: Single-system map produces array with 1 entry ---

SINGLE_RUNNER_MAP='{"x86_64-linux": "ubuntu-latest"}'

result="$(transform "$SINGLE_RUNNER_MAP")"
count="$(echo "$result" | jq 'length')"

if [ "$count" -eq 1 ]; then
  pass "single-system runner-map produces array with 1 entry"
else
  fail "single-system runner-map: expected 1 entry, got $count"
fi

entry_system="$(echo "$result" | jq -r '.[0]."nix-system"')"
entry_runner="$(echo "$result" | jq -r '.[0].runner')"

if [ "$entry_system" = "x86_64-linux" ] && [ "$entry_runner" = "ubuntu-latest" ]; then
  pass "single-system entry has correct nix-system and runner values"
else
  fail "single-system entry: expected x86_64-linux/ubuntu-latest, got $entry_system/$entry_runner"
fi

# --- Test 3: Empty map produces empty array ---

EMPTY_RUNNER_MAP='{}'

result="$(transform "$EMPTY_RUNNER_MAP")"

if [ "$result" = "[]" ]; then
  pass "empty runner-map produces empty array []"
else
  fail "empty runner-map: expected [], got $result"
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
