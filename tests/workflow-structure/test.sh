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

# --- Helper: extract a named build step, including its name line ---
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

# --- Helper: count occurrences of a fixed string without failing on zero ---
count_occurrences() {
  awk -v needle="$1" 'index($0, needle) { count++ } END { print count + 0 }' "$2"
}

# --- Helper: first line number containing a fixed string ---
line_of() {
  awk -v needle="$1" 'index($0, needle) { print NR; exit }' "$2"
}

# --- Helper: extract the minimum Nix version guard body from any surface ---
# Handles both the reusable workflow (six-space step indent) and the composite
# actions (four-space step indent). Whole-line comments are dropped so prose
# about the guard can neither satisfy nor break an assertion about its code.
extract_guard_body() {
  awk '
    index($0, "name: Verify Nix meets the minimum supported version") { in_guard = 1; next }
    !in_guard { next }
    /^[[:space:]]*-[[:space:]]+(name:|uses:)/ { exit }
    /^[[:space:]]*#/ { next }
    { print }
  ' "$1"
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

# --- Backward-compatible inputs are still accepted ---
# A reusable workflow errors on an undefined input, so removing any of these
# breaks every caller that still passes it.

compatible_inputs=(enable-ssh-agent directory fail-fast runner-map enable-lfs check-dev-shells)
for input_name in "${compatible_inputs[@]}"; do
  if grep -q "^      ${input_name}:" "$WORKFLOW"; then
    pass "backward-compatible input still declared: $input_name"
  else
    fail "backward-compatible input removed: $input_name"
  fi
done

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

# --- Setup contract steps both surfaces must provide ---

required_setup_steps=(
  "name: Install git-lfs (Linux)"
  "name: Install git-lfs (macOS)"
  "name: Ensure LFS files are checked out"
  "name: Clean up stale git credential config"
  "name: Detect existing Nix"
  "name: Install Nix when absent"
  "name: Verify Nix meets the minimum supported version"
  "name: Authenticate git and Nix to github.com"
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

# --- Deprecated ssh-agent path stays functional ---

if echo "$build_block" | grep -qE 'webfactory/ssh-agent'; then
  pass "build job still has webfactory/ssh-agent reference (inline)"
else
  fail "build job no longer has webfactory/ssh-agent reference"
fi

if echo "$build_block" | grep -qE 'name: Add GitHub SSH host keys'; then
  pass "build job still has 'Add GitHub SSH host keys' step (inline)"
else
  fail "build job no longer has 'Add GitHub SSH host keys' step"
fi

if echo "$build_block" | grep -qF 'if: ${{ inputs.enable-ssh-agent }}'; then
  pass "ssh-agent steps remain gated on inputs.enable-ssh-agent"
else
  fail "ssh-agent steps are not gated on inputs.enable-ssh-agent"
fi

# --- Stale credential cleanup stays inline and runs before checkout ---
# Delegation cannot cover this: reaching the shared script requires a checkout
# to exist, and the cleanup has to happen before actions/checkout runs.

cleanup_block="$(extract_named_build_step 'Clean up stale git credential config')"
cleanup_line="$(line_of 'name: Clean up stale git credential config' "$WORKFLOW")"
first_checkout_line="$(line_of 'uses: actions/checkout@v4' "$WORKFLOW")"

if [[ -n "$cleanup_line" && -n "$first_checkout_line" && "$cleanup_line" -lt "$first_checkout_line" ]]; then
  pass "stale credential cleanup runs before actions/checkout"
else
  fail "stale credential cleanup must run before actions/checkout"
fi

if echo "$cleanup_block" | grep -qF 'http.https://github.com/.extraHeader' &&
  echo "$cleanup_block" | grep -qF 'url.https://github.com/.insteadOf'; then
  pass "stale credential cleanup unsets both extraHeader and insteadOf"
else
  fail "stale credential cleanup does not unset both extraHeader and insteadOf"
fi

if echo "$cleanup_block" | grep -qF -- '-ne 5'; then
  pass "stale credential cleanup handles git config --unset-all status 5 explicitly"
else
  fail "stale credential cleanup does not handle git config --unset-all status 5 explicitly"
fi

if grep -qF '|| true' "$WORKFLOW"; then
  fail "workflow uses '|| true' (fail-fast violation)"
else
  pass "workflow contains no '|| true'"
fi

# --- Organization read access capability ---

if grep -A8 '^      enable-org-read-access:' "$WORKFLOW" | grep -q 'default: false'; then
  pass "enable-org-read-access input is opt-in by default"
else
  fail "enable-org-read-access input is missing or not opt-in by default"
fi

if grep -A8 '^      enable-github-app-auth:' "$WORKFLOW" | grep -q 'default: false'; then
  pass "deprecated enable-github-app-auth alias is still declared and opt-in"
else
  fail "deprecated enable-github-app-auth alias is missing or not opt-in"
fi

if grep -A3 '^      enable-github-app-auth:' "$WORKFLOW" | grep -q 'DEPRECATED'; then
  pass "enable-github-app-auth is documented as deprecated"
else
  fail "enable-github-app-auth is not documented as deprecated"
fi

for secret_name in ssh-private-key github-app-id github-app-private-key; do
  if grep -A2 "^      ${secret_name}:" "$WORKFLOW" | grep -q 'required: false'; then
    pass "secret stays optional: $secret_name"
  else
    fail "secret is not declared optional: $secret_name"
  fi
done

# --- Token minting happens exactly once, on a pinned action ---

app_token_steps="$(count_occurrences 'actions/create-github-app-token@' "$WORKFLOW")"
if [ "$app_token_steps" -eq 1 ]; then
  pass "workflow mints the App token in exactly one step"
else
  fail "workflow has $app_token_steps create-github-app-token steps, expected exactly 1"
fi

app_token_block="$(extract_named_build_step 'Mint GitHub App organization installation token')"

if echo "$app_token_block" | grep -qF 'if: ${{ inputs.enable-org-read-access || inputs.enable-github-app-auth }}'; then
  pass "App token minting is alias-aware and opt-in"
else
  fail "App token minting is not gated on both the capability input and its deprecated alias"
fi

if echo "$app_token_block" | grep -qF 'actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0'; then
  pass "GitHub App token action is pinned to v3.2.0 commit"
else
  fail "GitHub App token action is not pinned to the required v3.2.0 commit"
fi

if echo "$app_token_block" | grep -qF 'app-id: ${{ secrets.github-app-id }}' &&
  echo "$app_token_block" | grep -qF 'private-key: ${{ secrets.github-app-private-key }}' &&
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

# --- Credential acquisition is delegated to the single shared script ---

delegation_block="$(extract_named_build_step 'Check out shared authentication implementation')"

if echo "$delegation_block" | grep -qF 'repository: ${{ job.workflow_repository }}' &&
  echo "$delegation_block" | grep -qF 'ref: ${{ job.workflow_sha }}'; then
  pass "delegation checks out this repository at the caller-selected revision"
else
  fail "delegation does not check out job.workflow_repository at job.workflow_sha"
fi

if echo "$delegation_block" | grep -qF 'path: .cvt-ci-auth'; then
  pass "delegation checkout is confined to a workspace subpath"
else
  fail "delegation checkout is not confined to a workspace subpath"
fi

delegation_line="$(line_of 'name: Check out shared authentication implementation' "$WORKFLOW")"
if [[ -n "$delegation_line" && -n "$first_checkout_line" && "$delegation_line" -gt "$first_checkout_line" ]]; then
  pass "delegation checkout runs after the consumer checkout"
else
  fail "delegation checkout must run after the consumer checkout"
fi

authenticate_steps="$(count_occurrences 'name: Authenticate git and Nix to github.com' "$WORKFLOW")"
if [ "$authenticate_steps" -eq 1 ]; then
  pass "workflow has exactly one authentication step"
else
  fail "workflow has $authenticate_steps authentication steps, expected exactly 1"
fi

authenticate_block="$(extract_named_build_step 'Authenticate git and Nix to github.com')"

if echo "$authenticate_block" | grep -qF '.cvt-ci-auth/auth/authenticate.sh'; then
  pass "authentication step invokes the shared auth/authenticate.sh"
else
  fail "authentication step does not invoke the shared auth/authenticate.sh"
fi

if echo "$authenticate_block" | grep -qF 'ORG_READ_TOKEN: ${{ (inputs.enable-org-read-access || inputs.enable-github-app-auth) && steps.github-app-token.outputs.token || github.token }}'; then
  pass "authentication step selects the App token when either capability input is set"
else
  fail "authentication step does not select the App token in an alias-aware way"
fi

if echo "$authenticate_block" | grep -qF 'ORG_READ_INSTALL_URL_REWRITES: ${{ inputs.enable-org-read-access || inputs.enable-github-app-auth }}'; then
  pass "url rewrites are requested only when organization read access is enabled"
else
  fail "url rewrite request is not alias-aware or not conditional"
fi

if echo "$authenticate_block" | grep -qF 'ORG_READ_OWNER: ${{ github.repository_owner }}'; then
  pass "authentication step scopes Nix access tokens to the repository owner"
else
  fail "authentication step does not scope Nix access tokens to the repository owner"
fi

remove_block="$(extract_named_build_step 'Remove shared authentication checkout')"
remove_line="$(line_of 'name: Remove shared authentication checkout' "$WORKFLOW")"
authenticate_line="$(line_of 'name: Authenticate git and Nix to github.com' "$WORKFLOW")"

if echo "$remove_block" | grep -qF 'rm -rf "$GITHUB_WORKSPACE/.cvt-ci-auth"' &&
  [[ -n "$remove_line" && -n "$authenticate_line" && "$remove_line" -gt "$authenticate_line" ]]; then
  pass "delegation checkout is removed after authentication"
else
  fail "delegation checkout is not removed after authentication"
fi

# --- The workflow carries no credential-writing logic of its own ---

for forbidden in 'machine github.com' 'credential.helper' '.git-credentials' 'netrc-file' '/tmp/netrc' 'x-access-token'; do
  if grep -qF "$forbidden" "$WORKFLOW"; then
    fail "workflow contains its own credential-writing logic: $forbidden"
  else
    pass "workflow contains no credential-writing logic for: $forbidden"
  fi
done

insteadof_occurrences="$(awk '/^[[:space:]]*#/ { next } index($0, "insteadOf") { count++ } END { print count + 0 }' "$WORKFLOW")"
if [ "$insteadof_occurrences" -eq 1 ]; then
  pass "insteadOf appears only in the inline stale cleanup"
else
  fail "insteadOf appears $insteadof_occurrences times in the workflow, expected only the inline stale cleanup"
fi

# --- Conditional upstream Nix installation contract ---

install_nix_block="$(extract_named_build_step 'Install Nix when absent')"
detect_nix_block="$(extract_named_build_step 'Detect existing Nix')"

detect_nix_line="$(line_of 'name: Detect existing Nix' "$WORKFLOW")"
install_nix_line="$(line_of 'name: Install Nix when absent' "$WORKFLOW")"

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

if echo "$install_nix_block" | grep -qF 'github_access_token: ${{ (inputs.enable-org-read-access || inputs.enable-github-app-auth) && steps.github-app-token.outputs.token || github.token }}'; then
  pass "upstream installer token selection is alias-aware"
else
  fail "upstream installer token selection is not alias-aware"
fi

if [[ -n "$authenticate_line" && -n "$install_nix_line" && "$authenticate_line" -gt "$install_nix_line" ]]; then
  pass "authentication runs after conditional Nix installation"
else
  fail "authentication must run after conditional Nix installation"
fi

# --- Fail-fast minimum Nix version guard ---
# Nix below 2.35.0 builds a malformed Git-LFS endpoint and GitHub answers HTTP
# 422 before it evaluates any credential, so the organization token path cannot
# serve Git LFS. The floor has to stay a literal on every surface: a consumer
# input would let callers silently lower it back under the defect.

SETUP_ACTION="$REPO_ROOT/setup/action.yml"
guard_step_name='name: Verify Nix meets the minimum supported version'
guard_floor_literal='minimum_nix_version="2.35.0"'

for guard_surface in "$WORKFLOW" "$SETUP_ACTION"; do
  guard_surface_label="${guard_surface#"$REPO_ROOT"/}"

  guard_steps="$(count_occurrences "$guard_step_name" "$guard_surface")"
  if [ "$guard_steps" -eq 1 ]; then
    pass "exactly one minimum Nix version guard step in $guard_surface_label"
  else
    fail "$guard_surface_label has $guard_steps minimum Nix version guard steps, expected exactly 1"
  fi

  floor_literals="$(count_occurrences "$guard_floor_literal" "$guard_surface")"
  if [ "$floor_literals" -eq 1 ]; then
    pass "the 2.35.0 floor is one hard-coded literal in $guard_surface_label"
  else
    fail "$guard_surface_label declares the 2.35.0 floor $floor_literals times, expected exactly 1"
  fi

  floor_from_input="$(awk 'index($0, "minimum_nix_version=") && (index($0, "inputs.") || index($0, "${{")) { count++ } END { print count + 0 }' "$guard_surface")"
  if [ "$floor_from_input" -eq 0 ]; then
    pass "the floor in $guard_surface_label is never read from a consumer input"
  else
    fail "$guard_surface_label reads the minimum Nix version from an expression, which lets consumers lower the floor"
  fi

  if grep -qF 'echo "::error::$guard_message"' "$guard_surface" && grep -qF 'exit 1' "$guard_surface"; then
    pass "the guard in $guard_surface_label fails the job rather than warning"
  else
    fail "the guard in $guard_surface_label has no hard failure path"
  fi

  # The floor is enforced on every platform. No warning-only path, no
  # platform-conditional exit 0, no exemption literal: a version below the
  # floor has exactly one outcome, an annotated error and a non-zero exit.
  guard_body="$(extract_guard_body "$guard_surface")"

  if echo "$guard_body" | grep -qF '::warning::'; then
    fail "the guard in $guard_surface_label has a soft-warning path; below the floor must always fail"
  else
    pass "the guard in $guard_surface_label has no soft-warning path"
  fi

  if echo "$guard_body" | grep -qF 'RUNNER_OS'; then
    fail "the guard in $guard_surface_label branches on the platform, which exempts a runner from the floor"
  else
    pass "the guard in $guard_surface_label never branches on the platform"
  fi

  if echo "$guard_body" | grep -qi 'defer'; then
    fail "the guard in $guard_surface_label still carries a deferral exemption"
  else
    pass "the guard in $guard_surface_label carries no deferral exemption"
  fi

  guard_successful_exits="$(printf '%s\n' "$guard_body" | awk '/^[[:space:]]*exit 0[[:space:]]*$/ { count++ } END { print count + 0 }')"
  if [ "$guard_successful_exits" -eq 1 ]; then
    pass "the guard in $guard_surface_label succeeds only on the meets-the-floor path"
  else
    fail "the guard in $guard_surface_label has $guard_successful_exits successful exits, expected only the meets-the-floor path"
  fi

  if printf '%s\n' "$guard_body" | awk '
    index($0, "guard_message=\"Nix ") { in_tail = 1; next }
    !in_tail { next }
    /^[[:space:]]*$/ { next }
    { tail = tail $0 "\n"; lines++ }
    END { exit !(lines == 2 && index(tail, "echo \"::error::$guard_message\"") && index(tail, "exit 1")) }
  '; then
    pass "a below-floor version in $guard_surface_label has exactly one outcome: ::error:: then exit 1"
  else
    fail "$guard_surface_label does not end the guard with exactly ::error:: and exit 1 after the message"
  fi

  guard_message_line="$(awk 'index($0, "guard_message=\"Nix ") { print; exit }' "$guard_surface")"
  if [[ "$guard_message_line" == *'$found_nix_version'* ]] &&
    [[ "$guard_message_line" == *"\$RUNNER_LABEL"* ]] &&
    [[ "$guard_message_line" == *'$minimum_nix_version'* ]] &&
    [[ "$guard_message_line" == *'HTTP 422'* ]]; then
    pass "the guard message in $guard_surface_label names the found version, runner and required minimum, and why"
  else
    fail "the guard message in $guard_surface_label does not name the found version, runner, required minimum and reason"
  fi
done

guard_block="$(extract_named_build_step 'Verify Nix meets the minimum supported version')"
guard_line="$(line_of "$guard_step_name" "$WORKFLOW")"

if echo "$guard_block" | grep -qF 'RUNNER_LABEL: ${{ matrix.systems.runner }}'; then
  pass "the guard names the matrix runner label it is running on"
else
  fail "the guard does not name the matrix runner label it is running on"
fi

if [[ -n "$guard_line" && -n "$install_nix_line" && "$guard_line" -gt "$install_nix_line" ]]; then
  pass "the guard runs after conditional Nix installation"
else
  fail "the guard must run after conditional Nix installation"
fi

# The App token is minted and consumed earlier — by the delegation checkout and
# by install-nix-action — so the guard cannot and does not gate token use. What
# it gates is the shared authenticate script: the runner is proven to be above
# the floor before any credential is written or Nix is reconfigured.
if [[ -n "$guard_line" && -n "$authenticate_line" && "$guard_line" -lt "$authenticate_line" ]]; then
  pass "the guard runs after Nix installation and before the shared authenticate script configures credentials"
else
  fail "the guard must run before the shared authenticate script configures credentials"
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

# --- Manual organization-read probes: present, dispatch-gated, never on a PR ---
# The probes need real App credentials and real private repositories, so they
# must stay manual and opt-in. Ordinary pull-request validation has to keep
# exercising the default path with no App credentials, which means no probe job
# may exist on a pull_request event at all.

PROBE_FIXTURE="$REPO_ROOT/tests/org-read-probe/flake.nix"

probe_jobs=(
  probe-reusable-workflow-org-read
  probe-setup-action-org-read
  probe-auth-action-self-hosted-org-read
)
step_driven_probe_jobs=(
  probe-setup-action-org-read
  probe-auth-action-self-hosted-org-read
)
probe_gate='if: ${{ github.event_name == '"'"'workflow_dispatch'"'"' && inputs.run-org-read-probes }}'

# A job block ends at the next two-space key OR the next two-space comment,
# because the prose that introduces the following job sits between them and
# would otherwise be read as part of this one.
extract_validate_job() {
  awk -v job="  $1:" '
    $0 == job { in_job = 1; next }
    !in_job { next }
    /^  [a-zA-Z_#]/ { exit }
    { print }
  ' "$VALIDATE"
}

if grep -A10 '^      run-org-read-probes:' "$VALIDATE" | grep -qF 'default: false'; then
  pass "the run-org-read-probes dispatch input defaults to false"
else
  fail "the run-org-read-probes dispatch input is missing or does not default to false"
fi

if awk '
  /^  workflow_dispatch:/ { in_dispatch = 1; next }
  /^  [a-z_]/ { in_dispatch = 0 }
  in_dispatch && index($0, "run-org-read-probes:") { found = 1 }
  END { exit !found }
' "$VALIDATE"; then
  pass "run-org-read-probes is declared on the workflow_dispatch trigger, not on any other event"
else
  fail "run-org-read-probes is not declared under workflow_dispatch"
fi

gated_probe_jobs="$(count_occurrences "$probe_gate" "$VALIDATE")"
if [ "$gated_probe_jobs" -eq "${#probe_jobs[@]}" ]; then
  pass "every one of the ${#probe_jobs[@]} probe jobs carries the identical dispatch gate"
else
  fail "$gated_probe_jobs jobs carry the probe dispatch gate, expected ${#probe_jobs[@]}"
fi

for probe_job in "${probe_jobs[@]}"; do
  probe_block="$(extract_validate_job "$probe_job")"

  if [ -n "$probe_block" ]; then
    pass "probe job exists: $probe_job"
  else
    fail "probe job is missing: $probe_job"
    continue
  fi

  # Two independent reasons a pull request cannot reach this job: the event name
  # is pinned to workflow_dispatch, and the opt-in input only exists on that
  # event. Either alone would do; both are asserted so removing one is caught.
  if echo "$probe_block" | grep -qF "github.event_name == 'workflow_dispatch'"; then
    pass "$probe_job is gated on the workflow_dispatch event"
  else
    fail "$probe_job is not gated on the workflow_dispatch event, so a pull request could run it"
  fi

  if echo "$probe_block" | grep -qF 'inputs.run-org-read-probes'; then
    pass "$probe_job is gated on the explicit run-org-read-probes opt-in"
  else
    fail "$probe_job is not gated on the run-org-read-probes opt-in, so a plain dispatch would run it"
  fi

  if echo "$probe_block" | grep -qE '^[[:space:]]*needs:'; then
    fail "$probe_job declares needs:, which can drag it into an ungated run"
  else
    pass "$probe_job depends on no other job"
  fi
done

# Nothing an ungated job needs may name a probe, or the probe would be created
# on a pull request despite its own gate.
probe_dependents="$(awk '
  /^[[:space:]]*needs:/ && index($0, "probe-") { count++ }
  END { print count + 0 }
' "$VALIDATE")"
if [ "$probe_dependents" -eq 0 ]; then
  pass "no job depends on a probe job"
else
  fail "$probe_dependents jobs declare needs: on a probe job"
fi

# The three ordinary validation jobs stay ungated, so the probes cannot have
# been added by gating normal CI instead.
for ordinary_job in lints ci setup-composite-smoke; do
  ordinary_block="$(extract_validate_job "$ordinary_job")"
  if echo "$ordinary_block" | grep -qF 'run-org-read-probes'; then
    fail "ordinary validation job $ordinary_job is gated on the probe opt-in"
  else
    pass "ordinary validation job $ordinary_job is not gated on the probe opt-in"
  fi
done

# --- The reusable-workflow probe ---

reusable_probe_block="$(extract_validate_job probe-reusable-workflow-org-read)"

if echo "$reusable_probe_block" | grep -qF 'uses: ./.github/workflows/workflow.yml'; then
  pass "the reusable-workflow probe exercises the reusable workflow surface"
else
  fail "the reusable-workflow probe does not call the reusable workflow"
fi

if echo "$reusable_probe_block" | grep -qF 'enable-org-read-access: true'; then
  pass "the reusable-workflow probe enables organization read access"
else
  fail "the reusable-workflow probe does not enable organization read access"
fi

if echo "$reusable_probe_block" | grep -qF 'directory: ./tests/org-read-probe'; then
  pass "the reusable-workflow probe points at the organization-read probe fixture"
else
  fail "the reusable-workflow probe does not point at the organization-read probe fixture"
fi

if echo "$reusable_probe_block" | grep -qF 'enable-ssh-agent'; then
  fail "the reusable-workflow probe enables ssh-agent, so a pass would not prove the token path"
else
  pass "the reusable-workflow probe supplies no SSH key"
fi

# A job that calls a reusable workflow may not declare timeout-minutes, so this
# probe cannot carry one. Asserted so the omission reads as deliberate.
if echo "$reusable_probe_block" | grep -qE '^[[:space:]]*timeout-minutes:'; then
  fail "the reusable-workflow probe declares timeout-minutes, which GitHub rejects on a uses: job"
else
  pass "the reusable-workflow probe declares no timeout-minutes, which a uses: job may not have"
fi

# The reusable workflow admits no extra steps, so this probe's proof has to live
# in the fixture flake's inputs.
if [ -f "$PROBE_FIXTURE" ]; then
  pass "the organization-read probe fixture flake exists"
else
  fail "the organization-read probe fixture flake is missing"
fi

if grep -qF 'url = "git+https://github.com/Cambridge-Vision-Technology/infra-base"' "$PROBE_FIXTURE"; then
  pass "the probe fixture resolves private infra-base over plain HTTPS"
else
  fail "the probe fixture does not resolve private infra-base over plain HTTPS"
fi

if grep -qF 'url = "git+ssh://git@github.com/Cambridge-Vision-Technology/nix-shared"' "$PROBE_FIXTURE"; then
  pass "the probe fixture resolves private nix-shared through its git+ssh:// flake URL"
else
  fail "the probe fixture does not resolve private nix-shared through its git+ssh:// flake URL"
fi

if grep -qF 'purescript-dedup?lfs=1' "$PROBE_FIXTURE"; then
  pass "the probe fixture carries a Git-LFS-bearing private input"
else
  fail "the probe fixture carries no Git-LFS-bearing private input"
fi

if grep -qF 'git-lfs.github.com/spec/v1' "$PROBE_FIXTURE"; then
  pass "the probe fixture fails when an LFS object arrives as an unsmudged pointer"
else
  fail "the probe fixture does not check that LFS objects are smudged"
fi

# --- The two step-driven probes ---

for probe_job in "${step_driven_probe_jobs[@]}"; do
  probe_block="$(extract_validate_job "$probe_job")"

  if echo "$probe_block" | grep -qF 'timeout-minutes: 10'; then
    pass "$probe_job is bounded to ten minutes"
  else
    fail "$probe_job is not bounded to ten minutes"
  fi

  # A warm Nix cache serves a tree an earlier authenticated run fetched and
  # turns the probe into a false green. This has happened in practice.
  if echo "$probe_block" | grep -qF 'rm -rf "$HOME/.cache/nix/gitv3"'; then
    pass "$probe_job clears the Nix git cache"
  else
    fail "$probe_job does not clear the Nix git cache, so it can report a false green"
  fi

  probe_cold_cache_line="$(printf '%s\n' "$probe_block" | awk 'index($0, "rm -rf \"$HOME/.cache/nix/gitv3\"") { print NR; exit }')"
  probe_first_fetch_line="$(printf '%s\n' "$probe_block" | awk 'index($0, "uses: ./") { print NR; exit }')"
  if [[ -n "$probe_cold_cache_line" && -n "$probe_first_fetch_line" && "$probe_cold_cache_line" -lt "$probe_first_fetch_line" ]]; then
    pass "$probe_job clears the cache before it authenticates or fetches anything"
  else
    fail "$probe_job clears the cache too late to prevent a false green"
  fi

  # A passing git+ssh fetch would prove nothing about the token path, so the
  # probe removes the SSH transport outright rather than merely not using it.
  if echo "$probe_block" | grep -qF 'SSH_AUTH_SOCK: ""' &&
    echo "$probe_block" | grep -qF 'GIT_SSH_COMMAND: "false"'; then
    pass "$probe_job makes the SSH transport unusable, so a pass can only be HTTPS"
  else
    fail "$probe_job leaves the SSH transport usable, so a pass would not prove the token path"
  fi

  if echo "$probe_block" | grep -qF 'ssh-private-key' ||
    echo "$probe_block" | grep -qF 'webfactory/ssh-agent'; then
    fail "$probe_job supplies an SSH key"
  else
    pass "$probe_job supplies no SSH key"
  fi

  if echo "$probe_block" | grep -qF 'enable-org-read-access: "true"'; then
    pass "$probe_job enables organization read access"
  else
    fail "$probe_job does not enable organization read access"
  fi

  if echo "$probe_block" | grep -qF 'git clone --depth 1 "https://github.com/$PROBE_ORG/infra-base"'; then
    pass "$probe_job clones private infra-base over HTTPS"
  else
    fail "$probe_job does not clone private infra-base over HTTPS"
  fi

  if echo "$probe_block" | grep -qF '"git+ssh://git@github.com/$PROBE_ORG/nix-shared"'; then
    pass "$probe_job resolves private nix-shared through its git+ssh:// flake URL"
  else
    fail "$probe_job does not resolve private nix-shared through its git+ssh:// flake URL"
  fi

  if echo "$probe_block" | grep -qF '/purescript-dedup"; ref = "main"; lfs = true;'; then
    pass "$probe_job fetches a private Git-LFS-bearing input"
  else
    fail "$probe_job does not fetch a private Git-LFS-bearing input"
  fi

  if echo "$probe_block" | grep -qF 'git-lfs.github.com/spec/v1'; then
    pass "$probe_job fails when an LFS object arrives as an unsmudged pointer"
  else
    fail "$probe_job does not check that LFS objects are smudged"
  fi

  # The public-repository A/B separates the Nix endpoint defect from anything
  # to do with credentials, and its outcomes are inverted from the obvious
  # reading, so both have to stay spelled out where the step runs.
  if echo "$probe_block" | grep -qF 'https://github.com/Apress/repo-with-large-file-storage'; then
    pass "$probe_job runs the credential-free public-repository Git-LFS A/B check"
  else
    fail "$probe_job does not run the credential-free public-repository Git-LFS A/B check"
  fi

  if echo "$probe_block" | grep -qF 'env -u NIX_USER_CONF_FILES nix eval'; then
    pass "$probe_job runs the A/B check with no netrc and no access token in scope"
  else
    fail "$probe_job lets job credentials influence the credential-free A/B check"
  fi

  if echo "$probe_block" | grep -qF 'HTTP 403 (LFS budget exceeded) is the expected SUCCESS signal'; then
    pass "$probe_job states that a 403 from the A/B check is the success signal"
  else
    fail "$probe_job does not state that a 403 from the A/B check is the success signal"
  fi

  if echo "$probe_block" | grep -qF '::error::HTTP 422 from the public Git-LFS endpoint'; then
    pass "$probe_job treats a 422 from the A/B check as a hard failure"
  else
    fail "$probe_job does not treat a 422 from the A/B check as a hard failure"
  fi

  if echo "$probe_block" | grep -qF "name: Verify this job's log contains no credential material"; then
    pass "$probe_job checks its own log for credential material"
  else
    fail "$probe_job does not check its own log for credential material"
  fi
done

setup_probe_block="$(extract_validate_job probe-setup-action-org-read)"
auth_probe_block="$(extract_validate_job probe-auth-action-self-hosted-org-read)"

if echo "$setup_probe_block" | grep -qF 'uses: ./setup'; then
  pass "the setup-action probe exercises the setup composite"
else
  fail "the setup-action probe does not exercise the setup composite"
fi

if echo "$setup_probe_block" | grep -qF 'runs-on: ubuntu-latest'; then
  pass "the setup-action probe runs on a GitHub-hosted Linux runner"
else
  fail "the setup-action probe does not run on a GitHub-hosted Linux runner"
fi

if echo "$auth_probe_block" | grep -qF 'uses: ./auth'; then
  pass "the self-hosted probe exercises the standalone auth action"
else
  fail "the self-hosted probe does not exercise the standalone auth action"
fi

# The DEV-757 build_workstation_index shape is the standalone action WITHOUT
# the setup composite. A probe that reached for setup would not prove it.
if echo "$auth_probe_block" | grep -qF 'uses: ./setup'; then
  fail "the self-hosted probe uses the setup composite, so it does not prove the standalone path"
else
  pass "the self-hosted probe never uses the setup composite"
fi

if echo "$auth_probe_block" | grep -qF 'runs-on: x86_64-linux'; then
  pass "the self-hosted probe runs on the x86_64-linux self-hosted runner"
else
  fail "the self-hosted probe does not run on the x86_64-linux self-hosted runner"
fi

# The runner reads this while it prepares a JavaScript action, so a job-level or
# step-level env is already too late: actions/create-github-app-token simply
# does not run on [self-hosted, Linux, X64] without it.
if awk '
  /^env:/ { in_env = 1; next }
  /^[a-zA-Z_]/ { in_env = 0 }
  in_env && index($0, "FORCE_JAVASCRIPT_ACTIONS_TO_NODE24:") { found = 1 }
  END { exit !found }
' "$VALIDATE"; then
  pass "FORCE_JAVASCRIPT_ACTIONS_TO_NODE24 is set at workflow level, where the runner can read it"
else
  fail "FORCE_JAVASCRIPT_ACTIONS_TO_NODE24 is not set at workflow level, so the self-hosted probe cannot mint a token"
fi

# --- Probes stay read-only and leak nothing ---

for write_verb in 'git push' 'git commit' 'gh pr ' 'gh release' 'gh api -X' '--method POST' 'upload-artifact'; do
  if grep -qF -e "$write_verb" "$VALIDATE"; then
    fail "validation workflow performs a write or an upload: $write_verb"
  else
    pass "validation workflow performs no write or upload: $write_verb"
  fi
done

for credential_file_name in github-org-read-netrc github-org-read-credentials github-org-read-nix-conf; do
  if awk -v needle="$credential_file_name" 'index($0, "cat ") && index($0, needle) { count++ } END { exit !(count + 0) }' "$VALIDATE"; then
    fail "validation workflow cats a credential file: $credential_file_name"
  else
    pass "validation workflow never cats the credential file: $credential_file_name"
  fi
done

if grep -qF '|| true' "$VALIDATE"; then
  fail "validation workflow uses '|| true' (fail-fast violation)"
else
  pass "validation workflow contains no '|| true'"
fi

# --- Regression guard: no git config --global http.extraHeader (setting) ---

extra_header_settings="$(awk 'index($0, "git config --global") && index($0, ".extraHeader") && !index($0, "--unset") { count++ } END { print count + 0 }' "$WORKFLOW")"
if [ "$extra_header_settings" -ne 0 ]; then
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
