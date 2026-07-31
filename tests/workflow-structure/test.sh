#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/workflow.yml"
ACTIONLINT_CONFIG="$REPO_ROOT/.github/actionlint.yaml"

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

# --- Optional repository scoping narrows the capability, and nothing else ---
#
# enable-org-read-access grants read access to every repository in the
# organization. A caller whose private dependencies are a known, fixed list
# should be able to say so without abandoning this workflow for a hand-rolled
# job, so org-read-repositories confines the minted token to a named list.
#
# It is a PURE ADDITION. The App token action splits `repositories` on commas
# and newlines and drops empty entries, so the empty default leaves it with no
# repository at all, and an `owner` with no repositories is exactly its
# whole-organization case. An unset input therefore mints precisely the token
# this workflow has always minted — which matters more here than on the
# composites, because roughly 27 repositories consume this workflow at @main.
#
# The name is scope-shaped, never mechanism-shaped. Octo STS trust policies
# carry a `repositories` field just as an App installation token does, so the
# input survives the move off App secrets (DEV-753) without a second
# organization-wide sweep of call sites.

extract_workflow_input() {
  awk -v key="      $1:" '
    $0 == key { in_input = 1; next }
    in_input && /^      [a-zA-Z]/ { exit }
    in_input { print }
  ' "$WORKFLOW"
}

if grep -qE '^      org-read-repositories:' "$WORKFLOW"; then
  pass "the workflow exposes the optional repository scope input org-read-repositories"
else
  fail "the workflow does not expose org-read-repositories, so a caller cannot narrow below organization-wide"
fi

scope_input_block="$(extract_workflow_input org-read-repositories)"
scope_description="$(printf '%s\n' "$scope_input_block" | tr '\n' ' ' | tr -s ' ')"

if printf '%s\n' "$scope_input_block" | grep -qE '^[[:space:]]+required: false[[:space:]]*$'; then
  pass "org-read-repositories stays optional on the workflow"
else
  fail "org-read-repositories is not optional on the workflow, so every existing call site would have to pass it"
fi

if printf '%s\n' "$scope_input_block" | grep -qE '^[[:space:]]+default: ""[[:space:]]*$'; then
  pass "org-read-repositories defaults to empty, which is the organization-wide token this workflow mints today"
else
  fail "org-read-repositories does not default to empty, so it would change the behaviour of existing callers"
fi

# A list of names is a string, not a boolean. A workflow_call input with the
# wrong type is a startup failure at every call site that sets it.
if printf '%s\n' "$scope_input_block" | grep -qE '^[[:space:]]+type: string[[:space:]]*$'; then
  pass "org-read-repositories is declared as a string, matching the list the App token action parses"
else
  fail "org-read-repositories is not declared type: string"
fi

if [[ "$scope_description" == *"every repository in this organization"* ]]; then
  pass "the workflow documents that the empty default of org-read-repositories is organization-wide"
else
  fail "the workflow does not document what the empty default of org-read-repositories means"
fi

if echo "$app_token_block" | grep -qF 'repositories: ${{ inputs.org-read-repositories }}'; then
  pass "the workflow wires org-read-repositories to create-github-app-token's repositories input"
else
  fail "the workflow declares org-read-repositories but never wires it to create-github-app-token's repositories input"
fi

workflow_scope_wirings="$(count_occurrences 'repositories: ${{ inputs.org-read-repositories }}' "$WORKFLOW")"
if [ "$workflow_scope_wirings" -eq 1 ]; then
  pass "org-read-repositories is wired exactly once in the workflow"
else
  fail "the workflow wires org-read-repositories $workflow_scope_wirings times, expected exactly 1"
fi

# A fallback expression is the one edit that would silently narrow the default
# path: `${{ inputs.org-read-repositories || github.repository }}` looks
# harmless and confines every existing caller to its own repository.
workflow_scope_fallbacks="$(awk '/^[[:space:]]*#/ { next } index($0, "repositories: ${{") && index($0, "||") { count++ } END { print count + 0 }' "$WORKFLOW")"
if [ "$workflow_scope_fallbacks" -eq 0 ]; then
  pass "the repository scope carries no fallback expression, so an unset input stays empty"
else
  fail "the workflow has $workflow_scope_fallbacks fallback expressions on the repositories input, which would narrow the default path"
fi

workflow_mint_owner_line="$(echo "$app_token_block" | awk 'index($0, "owner:") { sub(/^[[:space:]]*/, ""); print; exit }')"
if [ "$workflow_mint_owner_line" = 'owner: ${{ github.repository_owner }}' ]; then
  pass "the workflow still mints against the whole owner installation, unconditionally"
else
  fail "the workflow mints with owner line '$workflow_mint_owner_line', expected the unconditional repository owner"
fi

# Setting only the scope must mint nothing: the capability input and its
# deprecated alias alone decide whether a token exists, and the scope decides
# only how wide it is.
workflow_mint_gate_line="$(echo "$app_token_block" | awk 'index($0, "if:") { sub(/^[[:space:]]*/, ""); print; exit }')"
if [ "$workflow_mint_gate_line" = 'if: ${{ inputs.enable-org-read-access || inputs.enable-github-app-auth }}' ]; then
  pass "the mint gate is unchanged: only the capability input and its deprecated alias decide whether a token is minted"
else
  fail "the mint gate is '$workflow_mint_gate_line', expected the capability input and its deprecated alias alone"
fi

for mechanism_named_scope_input in github-app-repositories app-repositories token-repositories installation-repositories; do
  if grep -qF "$mechanism_named_scope_input" "$WORKFLOW"; then
    fail "the workflow names the repository scope after the mechanism: $mechanism_named_scope_input"
  else
    pass "the workflow carries no mechanism-named repository scope input: $mechanism_named_scope_input"
  fi
done

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

if echo "$authenticate_block" | grep -qF 'ORG_READ_ACCESS_ENABLED: ${{ inputs.enable-org-read-access || inputs.enable-github-app-auth }}'; then
  pass "the shared script is told the token is organization-wide only when either capability input is set"
else
  fail "the organization-access flag passed to the shared script is not alias-aware or not conditional"
fi

if grep -qF 'ORG_READ_INSTALL_URL_REWRITES' "$WORKFLOW"; then
  fail "workflow still names the token's scope after one of its mechanisms"
else
  pass "workflow carries no mechanism-named ORG_READ_INSTALL_URL_REWRITES"
fi

# --- No checkout can reinstate the repository-scoped authorization header ---
# actions/checkout writes http.https://github.com/.extraheader into the LOCAL
# config of the repository it checks out. Nix's remote HEAD read runs
# `git ls-remote --symref` in the working directory, so it reads that header and
# gets a 404 for every other repository; the shared script clears it. A checkout
# running after that step would put it straight back.

last_checkout_line="$(awk 'index($0, "uses: actions/checkout@") { line = NR } END { print line + 0 }' "$WORKFLOW")"
authenticate_step_line="$(line_of 'name: Authenticate git and Nix to github.com' "$WORKFLOW")"
if [ "$last_checkout_line" -gt 0 ] &&
  [[ -n "$authenticate_step_line" && "$authenticate_step_line" -gt "$last_checkout_line" ]]; then
  pass "authentication runs after every checkout, so no checkout can reinstate the repository-scoped header"
else
  fail "a checkout runs after authentication and would reinstate the repository-scoped header"
fi

# The consumer's own checkout keeps its credentials: they are what the default
# repository-token path has always used, and the shared script removes the
# header itself once — and only once — the job holds a wider token.
consumer_checkout_block="$(awk '
  !started && index($0, "uses: actions/checkout@v4") { started = 1; print; next }
  !started { next }
  /^[[:space:]]{6}-[[:space:]]/ { exit }
  { print }
' "$WORKFLOW")"

if echo "$consumer_checkout_block" | grep -qF 'persist-credentials'; then
  fail "the consumer checkout disables persisted credentials, which changes the default repository-token path and still would not cover auth/action.yml"
else
  pass "the consumer checkout keeps its own credential handling"
fi

# The delegation checkout is this repository's own, fetched only to reach the
# shared script, so it has no business leaving a credential behind at all.
if echo "$delegation_block" | grep -qF 'persist-credentials: false'; then
  pass "the delegation checkout persists no credentials of its own"
else
  fail "the delegation checkout persists credentials into the workspace"
fi

local_git_config_writes="$(awk 'index($0, "git config") && index($0, "--local") { count++ } END { print count + 0 }' "$WORKFLOW")"
if [ "$local_git_config_writes" -eq 0 ]; then
  pass "the workflow carries no local git configuration handling of its own"
else
  fail "the workflow has $local_git_config_writes local git config statements, duplicating the shared implementation"
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
  probe-auth-action-self-hosted-darwin-org-read
)
step_driven_probe_jobs=(
  probe-setup-action-org-read
  probe-auth-action-self-hosted-org-read
  probe-auth-action-self-hosted-darwin-org-read
)
# The standalone auth action is proven once per self-hosted platform. darwin is
# the platform LFS-over-token was never proven on, because that runner sat below
# the 2.35.0 floor until the nix-darwin / nix-pin migration.
self_hosted_auth_probes=(
  probe-auth-action-self-hosted-org-read:x86_64-linux
  probe-auth-action-self-hosted-darwin-org-read:macos-arm64-nix-darwin
)
probe_gate='if: ${{ github.event_name == '"'"'workflow_dispatch'"'"' && inputs.run-org-read-probes }}'
audit_job=probe-log-credential-audit
audit_gate='if: ${{ always() && github.event_name == '"'"'workflow_dispatch'"'"' && inputs.run-org-read-probes }}'

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

# Nothing UNGATED may need a probe, or the probe would be created on a pull
# request despite its own gate. The log audit is the one permitted dependent,
# and it carries the same gate, so the permitted set is exactly one name.
# `needs:` is read as a block as well as inline, because the audit's dependency
# list is a block sequence and an inline-only check would read it as absent.
list_validate_jobs() {
  awk '
    /^jobs:/ { in_jobs = 1; next }
    !in_jobs { next }
    /^[a-zA-Z_]/ { in_jobs = 0; next }
    /^  [a-zA-Z_][a-zA-Z0-9_-]*:[[:space:]]*$/ {
      sub(/:[[:space:]]*$/, "")
      sub(/^  /, "")
      print
    }
  ' "$VALIDATE"
}

job_needs_a_probe() {
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*needs:/ {
      in_needs = 1
      if (index($0, "probe-")) { found = 1 }
      next
    }
    in_needs && /^[[:space:]]*-[[:space:]]/ {
      if (index($0, "probe-")) { found = 1 }
      next
    }
    in_needs && /[^[:space:]]/ { in_needs = 0 }
    END { exit !found }
  '
}

probe_dependent_jobs=""
while IFS= read -r validate_job; do
  if job_needs_a_probe "$(extract_validate_job "$validate_job")"; then
    probe_dependent_jobs="$probe_dependent_jobs$validate_job "
  fi
done < <(list_validate_jobs)

if [ "$probe_dependent_jobs" = "$audit_job " ]; then
  pass "the log audit is the only job that depends on a probe job"
else
  fail "jobs depending on a probe are '$probe_dependent_jobs', expected only '$audit_job'"
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

# The probes are the only live evidence that organization read access works, and
# the organization-wide default is the path every existing consumer takes, so no
# probe may narrow the scope. One that passed org-read-repositories would prove a
# narrowed token and leave the default unproven.
scoped_probe_jobs=""
for probe_job in "${probe_jobs[@]}"; do
  if extract_validate_job "$probe_job" | grep -qF 'org-read-repositories'; then
    scoped_probe_jobs="$scoped_probe_jobs$probe_job "
  fi
done
if [ -z "$scoped_probe_jobs" ]; then
  pass "every probe exercises the organization-wide default scope, so the probe evidence covers the path existing consumers take"
else
  fail "probes '$scoped_probe_jobs' narrow the repository scope, so the organization-wide default path is unproven"
fi

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

  # "Before the auth action" is not strict enough on its own: actions/checkout
  # and the credential-free A/B check both run before it and both touch the
  # network, and the A/B check's whole value is that it runs against a cache no
  # earlier authenticated run has warmed. The clear has to be the FIRST step of
  # the job, not merely an early one.
  probe_first_step="$(printf '%s\n' "$probe_block" | awk '
    /^      -[[:space:]]/ {
      sub(/^[[:space:]]*-[[:space:]]*/, "")
      print
      exit
    }
  ')"
  if [ "$probe_first_step" = "name: Clear the Nix git and fetcher caches" ]; then
    pass "$probe_job clears the cache as its very first step"
  else
    fail "$probe_job's first step is '$probe_first_step', so something runs before the cache is cleared"
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

  # The A/B check is credential-free by CONSTRUCTION, and the construction has
  # to be additive. `env -u NIX_USER_CONF_FILES` was the original attempt and it
  # did the OPPOSITE of what it claimed: unsetting the variable does not take
  # Nix's user configuration out of scope, it makes Nix fall back to its DEFAULT
  # user-config list, whose first entry is $HOME/.config/nix/nix.conf — the file
  # earlier revisions of this repository poisoned with netrc-file = /tmp/netrc
  # on self-hosted runners. Nix then presented a stale token to a PUBLIC
  # repository and was answered 401 Bad credentials.
  if printf '%s\n' "$probe_block" | awk '!/^[[:space:]]*#/' | grep -qF 'env -u NIX_USER_CONF_FILES'; then
    fail "$probe_job isolates the A/B check by UNSETTING NIX_USER_CONF_FILES, which restores Nix's default user-config list and reads the host's own nix.conf"
  else
    pass "$probe_job does not treat unsetting NIX_USER_CONF_FILES as isolation"
  fi

  if echo "$probe_block" | grep -qF 'NIX_USER_CONF_FILES="$empty_nix_conf" nix eval'; then
    pass "$probe_job points Nix at an EMPTY user configuration, replacing the default list rather than restoring it"
  else
    fail "$probe_job does not point Nix at an empty user configuration for the A/B check"
  fi

  # A command-line --option outranks every configuration file, including the
  # SYSTEM one. Without it, /etc/nix/nix.conf's netrc-file still reaches this
  # check — which is exactly how dell-foo's stale system netrc broke it.
  if echo "$probe_block" | grep -qF -e '--option netrc-file "$empty_netrc"'; then
    pass "$probe_job overrides netrc-file on the command line, so no configuration file can supply a credential"
  else
    fail "$probe_job does not override netrc-file, so the system nix.conf can still hand it a credential"
  fi

  if echo "$probe_block" | grep -qF -e '--option access-tokens ""'; then
    pass "$probe_job clears access-tokens for the A/B check"
  else
    fail "$probe_job leaves access-tokens in scope for a check that must carry no credential"
  fi

  for empty_isolation_file in ': > "$empty_nix_conf"' ': > "$empty_netrc"'; do
    if echo "$probe_block" | grep -qF "$empty_isolation_file"; then
      pass "$probe_job creates the isolation file it points Nix at: $empty_isolation_file"
    else
      fail "$probe_job points Nix at an isolation file it never creates: $empty_isolation_file"
    fi
  done

  for isolation_file_path in 'empty_nix_conf="$RUNNER_TEMP/credential-free-nix.conf"' 'empty_netrc="$RUNNER_TEMP/credential-free-netrc"'; do
    if echo "$probe_block" | grep -qF "$isolation_file_path"; then
      pass "$probe_job keeps its isolation file job-scoped under RUNNER_TEMP: $isolation_file_path"
    else
      fail "$probe_job does not keep its isolation file under RUNNER_TEMP: $isolation_file_path"
    fi
  done

  # A request carrying no credential cannot be rejected for its credential, so a
  # 401 means host state defeated the isolation and no result in the run means
  # anything. It must never fall through to the generic no-phrase-matched red,
  # which reads as an endpoint-discovery problem.
  if echo "$probe_block" | grep -qF '::error::401 Bad credentials from a check that carries no credential'; then
    pass "$probe_job reports a 401 as defeated isolation rather than as an endpoint result"
  else
    fail "$probe_job does not distinguish a 401 caused by leaked host credentials from an endpoint-discovery failure"
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

  # Every step-driven probe has to run unchanged on BSD userland and on a
  # self-hosted runner service's curated PATH. That rules out two separate
  # classes of construct: GNU-only spellings that a BSD tool rejects outright
  # (`grep -P`, `readlink -f`, GNU `sed -i`, `stat -c`, `mktemp -p`), and tools
  # that are simply absent from a runner service PATH — dell-foo's carries
  # neither gawk nor diffutils, which is what broke the first self-heal
  # revision. Comment lines are stripped first so prose naming a construct can
  # neither satisfy nor break the assertion about the code.
  probe_code="$(printf '%s\n' "$probe_block" | awk '!/^[[:space:]]*#/')"
  for non_portable_construct in 'grep -P' 'readlink -f' 'sed -i' 'stat -c' 'stat -f' 'mktemp -p' 'awk ' 'cmp '; do
    if printf '%s\n' "$probe_code" | grep -qF -e "$non_portable_construct"; then
      fail "$probe_job uses '$non_portable_construct', which is GNU-only or absent from a self-hosted runner service PATH"
    else
      pass "$probe_job avoids the non-portable construct '$non_portable_construct'"
    fi
  done

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

# --- The standalone auth action is proven on BOTH self-hosted platforms ---
#
# aarch64-darwin was the one platform where LFS over the token path had never
# been proven: admins-mac-mini ran Determinate Nix 2.34.7, below the 2.35.0
# floor, so it could not have passed the guard, let alone the LFS fetch. It now
# runs upstream 2.35.1 under nix-darwin, so the gap is closable and closed. The
# two probes are deliberate siblings — same structure, same proofs, same
# hardening — and the assertions below are what keeps them siblings.

self_hosted_auth_probe_labels=""
for self_hosted_auth_probe in "${self_hosted_auth_probes[@]}"; do
  self_hosted_auth_probe_job="${self_hosted_auth_probe%%:*}"
  self_hosted_auth_probe_label="${self_hosted_auth_probe##*:}"
  self_hosted_auth_probe_block="$(extract_validate_job "$self_hosted_auth_probe_job")"
  # Read back the label the job actually declares, never the one expected, so
  # the coverage check below sees the workflow rather than this suite's list.
  self_hosted_auth_probe_declared_label="$(printf '%s\n' "$self_hosted_auth_probe_block" | awk '
    index($0, "runs-on:") {
      sub(/^[[:space:]]*runs-on:[[:space:]]*/, "")
      print
      exit
    }
  ')"

  if [ "$self_hosted_auth_probe_declared_label" = "$self_hosted_auth_probe_label" ]; then
    pass "$self_hosted_auth_probe_job runs on the self-hosted runner $self_hosted_auth_probe_label"
  else
    fail "$self_hosted_auth_probe_job runs on '$self_hosted_auth_probe_declared_label', expected the self-hosted runner $self_hosted_auth_probe_label"
  fi

  # The DEV-757 build_workstation_index shape is the standalone action WITHOUT
  # the setup composite. A probe that reached for setup would not prove it.
  if echo "$self_hosted_auth_probe_block" | grep -qF 'uses: ./auth'; then
    pass "$self_hosted_auth_probe_job exercises the standalone auth action"
  else
    fail "$self_hosted_auth_probe_job does not exercise the standalone auth action"
  fi

  if echo "$self_hosted_auth_probe_block" | grep -qF 'uses: ./setup'; then
    fail "$self_hosted_auth_probe_job uses the setup composite, so it does not prove the standalone path"
  else
    pass "$self_hosted_auth_probe_job never uses the setup composite"
  fi

  # actionlint rejects any runs-on label it does not know, so a self-hosted
  # label that is not registered reds the lints job on every pull request —
  # before a probe is ever dispatched.
  if awk -v needle="- $self_hosted_auth_probe_declared_label" '
    /^self-hosted-runner:/ { in_runner = 1; next }
    in_runner && /^[a-zA-Z_]/ { in_runner = 0 }
    in_runner && index($0, needle) { found = 1 }
    END { exit !found }
  ' "$ACTIONLINT_CONFIG"; then
    pass "the self-hosted label $self_hosted_auth_probe_declared_label is registered in .github/actionlint.yaml"
  else
    fail "the self-hosted label $self_hosted_auth_probe_declared_label is not registered in .github/actionlint.yaml, so actionlint reds the lints job"
  fi

  self_hosted_auth_probe_labels="$self_hosted_auth_probe_labels$self_hosted_auth_probe_declared_label "
done

# Both self-hosted platforms, and both distinct: two probes pointed at the same
# label would look like coverage and prove one platform twice.
if [ "$self_hosted_auth_probe_labels" = "x86_64-linux macos-arm64-nix-darwin " ]; then
  pass "the standalone auth action is proven on both self-hosted platforms, x86_64-linux and macos-arm64-nix-darwin"
else
  fail "the self-hosted auth probes cover '$self_hosted_auth_probe_labels', expected 'x86_64-linux macos-arm64-nix-darwin '"
fi

# Every self-hosted runner label in the workflow's default runner-map is proven
# by one of these probes. A label with no probe is an unproven platform.
while IFS= read -r default_runner_label; do
  [ -n "$default_runner_label" ] || continue
  case " $self_hosted_auth_probe_labels" in
    *" $default_runner_label "*)
      pass "the default runner-map label $default_runner_label is proven by a self-hosted auth probe"
      ;;
    *)
      fail "the default runner-map label $default_runner_label has no self-hosted auth probe, so that platform is unproven"
      ;;
  esac
done < <(awk '
  index($0, "\"aarch64-darwin\":") || index($0, "\"x86_64-linux\":") {
    sub(/^[^:]*:[[:space:]]*"/, "")
    sub(/".*$/, "")
    print
  }
' "$WORKFLOW" | sort -u)

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

# --- The probe log credential audit ---
#
# The audit is a SEPARATE job on purpose. A job cannot read its own log — the
# jobs/{id}/logs endpoint answers 404 while the job is in progress — so the
# in-job version this replaces failed closed on every single run and could
# never pass. Worse, the runner echoes each `run:` body into the log, so an
# in-job scan would have matched its own source and reported a false-positive
# leak the moment the 404 was fixed. Both defects are structural, and only a
# job that runs after the probes and is never itself audited removes them.

audit_block="$(extract_validate_job "$audit_job")"

if [ -n "$audit_block" ]; then
  pass "the probe log credential audit job exists: $audit_job"
else
  fail "the probe log credential audit job is missing: $audit_job"
fi

# always() overrides only the implicit needs-succeeded condition, never an
# explicit term, so the dispatch gate on the same line still excludes a pull
# request while a FAILED probe's log is still scanned.
if echo "$audit_block" | grep -qF "$audit_gate"; then
  pass "the audit carries always() plus the identical dispatch gate the probes carry"
else
  fail "the audit does not carry always() plus the probes' dispatch gate"
fi

if echo "$audit_block" | grep -qF "github.event_name == 'workflow_dispatch'"; then
  pass "the audit is gated on the workflow_dispatch event"
else
  fail "the audit is not gated on the workflow_dispatch event, so a pull request could run it"
fi

if echo "$audit_block" | grep -qF 'inputs.run-org-read-probes'; then
  pass "the audit is gated on the explicit run-org-read-probes opt-in"
else
  fail "the audit is not gated on the run-org-read-probes opt-in, so a plain dispatch would run it"
fi

if echo "$audit_block" | grep -qF 'always()'; then
  pass "the audit runs even when a probe failed, so a leak in a failed probe is still caught"
else
  fail "the audit skips when a probe failed, so a leak in a failed probe would go unscanned"
fi

# Waiting on the probes is the whole fix: a needed job has completed, so its log
# is flushed and retrievable rather than 404.
for probe_job in "${probe_jobs[@]}"; do
  if echo "$audit_block" | awk -v needle="- $probe_job" '
    /^[[:space:]]*needs:/ { in_needs = 1; next }
    in_needs && index($0, needle) { found = 1 }
    in_needs && /^[[:space:]]*[a-zA-Z_]/ { in_needs = 0 }
    END { exit !found }
  '; then
    pass "the audit waits for $probe_job to complete before reading its log"
  else
    fail "the audit does not wait for $probe_job, so its log may still be unreadable"
  fi

  if echo "$audit_block" | awk -v needle="$probe_job" '
    index($0, "AUDITED_PROBE_JOBS:") { in_list = 1; next }
    in_list && !/^        [^ ]/ { in_list = 0 }
    in_list && index($0, needle) { found = 1 }
    END { exit !found }
  '; then
    pass "the audit scans the log of $probe_job"
  else
    fail "the audit does not scan the log of $probe_job"
  fi
done

# The audit's own log is the one log that legitimately holds the scan patterns,
# so auditing itself would be a guaranteed false-positive leak.
if echo "$audit_block" | grep -qF "$audit_job"; then
  fail "the audit names itself in its own body, so it can wait on or scan itself"
else
  pass "the audit never waits on or scans its own log"
fi

audited_names="$(echo "$audit_block" | awk '
  index($0, "AUDITED_PROBE_JOBS:") { in_list = 1; next }
  in_list && !/^        [^ ]/ { in_list = 0 }
  in_list && index($0, "probe-") { count++ }
  END { print count + 0 }
')"
if [ "$audited_names" -eq "${#probe_jobs[@]}" ]; then
  pass "the audit scans exactly the ${#probe_jobs[@]} probe jobs and nothing else"
else
  fail "the audit scans $audited_names jobs, expected exactly ${#probe_jobs[@]}"
fi

audit_needs_count="$(echo "$audit_block" | awk '
  /^[[:space:]]*needs:/ { in_needs = 1; next }
  in_needs && /^[[:space:]]*-[[:space:]]/ { count++; next }
  in_needs && /[^[:space:]]/ { in_needs = 0 }
  END { print count + 0 }
')"
if [ "$audit_needs_count" -eq "${#probe_jobs[@]}" ]; then
  pass "the audit waits for exactly the ${#probe_jobs[@]} probe jobs and nothing else"
else
  fail "the audit waits for $audit_needs_count jobs, expected exactly ${#probe_jobs[@]}"
fi

# --- Audit parity is discovered from the workflow, not from the list above ---
#
# The two assertions above compare the audit against this suite's hard-coded
# probe list, so extending both together still passes while the workflow itself
# has drifted. This one reads the probe jobs out of validate.yml instead: a
# fourth probe added without folding its name into AUDITED_PROBE_JOBS makes the
# audit fail closed at runtime on "no job matching an audited name", and one
# added without folding it into needs: makes the audit read a log that may not
# be flushed. Both are caught here rather than on a dispatch.

declared_probe_jobs="$(list_validate_jobs | grep '^probe-' | grep -vx "$audit_job")"

declared_probe_job_count=0
while IFS= read -r declared_probe_job; do
  [ -n "$declared_probe_job" ] || continue
  declared_probe_job_count=$((declared_probe_job_count + 1))

  if echo "$audit_block" | awk -v needle="$declared_probe_job" '
    index($0, "AUDITED_PROBE_JOBS:") { in_list = 1; next }
    in_list && !/^        [^ ]/ { in_list = 0 }
    in_list && $1 == needle { found = 1 }
    END { exit !found }
  '; then
    pass "every probe declared in validate.yml is in the audited-name list: $declared_probe_job"
  else
    fail "probe $declared_probe_job is declared in validate.yml but absent from AUDITED_PROBE_JOBS, so the audit fails closed on 'no job matching an audited name'"
  fi

  if echo "$audit_block" | awk -v needle="- $declared_probe_job" '
    /^[[:space:]]*needs:/ { in_needs = 1; next }
    in_needs && index($0, needle) { found = 1 }
    in_needs && /^[[:space:]]*[a-zA-Z_]/ { in_needs = 0 }
    END { exit !found }
  '; then
    pass "every probe declared in validate.yml is waited for by the audit: $declared_probe_job"
  else
    fail "probe $declared_probe_job is declared in validate.yml but absent from the audit's needs:, so its log may be unflushed when the audit reads it"
  fi
done <<< "$declared_probe_jobs"

if [ "$declared_probe_job_count" -eq "${#probe_jobs[@]}" ]; then
  pass "validate.yml declares exactly the ${#probe_jobs[@]} probe jobs this suite asserts on"
else
  fail "validate.yml declares $declared_probe_job_count probe jobs but this suite asserts on ${#probe_jobs[@]}"
fi

if echo "$audit_block" | grep -qF 'runs-on: ubuntu-latest'; then
  pass "the audit runs on a GitHub-hosted Linux runner"
else
  fail "the audit does not run on a GitHub-hosted Linux runner"
fi

if echo "$audit_block" | grep -qF 'timeout-minutes: 10'; then
  pass "the audit is bounded to ten minutes"
else
  fail "the audit is not bounded to ten minutes"
fi

if echo "$audit_block" | grep -qF 'actions: read'; then
  pass "the audit holds the actions: read permission it needs to read job logs"
else
  fail "the audit cannot read job logs without the actions: read permission"
fi

# It reads logs and nothing else: no token is minted for it, and it fetches
# nothing, so it holds no credential that could enter the log it writes.
if echo "$audit_block" | grep -qF 'id-token: write'; then
  fail "the audit requests id-token: write, which it has no use for"
else
  pass "the audit requests no id-token: write"
fi

if echo "$audit_block" | grep -qF 'CI_FETCH_APP'; then
  fail "the audit is handed App credentials it has no use for"
else
  pass "the audit is handed no App credentials"
fi

for audit_surface in 'uses: ./setup' 'uses: ./auth' 'uses: ./.github/workflows/workflow.yml'; do
  if echo "$audit_block" | grep -qF "$audit_surface"; then
    fail "the audit invokes $audit_surface, so it authenticates rather than only auditing"
  else
    pass "the audit does not invoke $audit_surface"
  fi
done

# Fail closed, and say WHICH failure it is. Every branch that cannot complete
# the scan reports the cannot-read wording; only a log that was read in full
# can report a leak.
audit_incomplete_conditions=(
  "this run's job list could not be read"
  "were returned on one page"
  "or nested under it, so its log was never scanned"
  "rather than completed"
  "could not be read after 3 attempts"
)
for audit_incomplete_condition in "${audit_incomplete_conditions[@]}"; do
  if echo "$audit_block" | grep -qF "::error::AUDIT INCOMPLETE, NOT A LEAK: " &&
    echo "$audit_block" | grep -qF "$audit_incomplete_condition"; then
    pass "the audit fails closed when it cannot scan: $audit_incomplete_condition"
  else
    fail "the audit does not fail closed when it cannot scan: $audit_incomplete_condition"
  fi
done

audit_incomplete_branches="$(echo "$audit_block" | awk '
  index($0, "::error::AUDIT INCOMPLETE, NOT A LEAK:") { count++ }
  END { print count + 0 }
')"
if [ "$audit_incomplete_branches" -eq "${#audit_incomplete_conditions[@]}" ]; then
  pass "all ${#audit_incomplete_conditions[@]} unscannable conditions fail closed, and no other branch claims to"
else
  fail "$audit_incomplete_branches branches report an unscannable condition, expected ${#audit_incomplete_conditions[@]}"
fi

if echo "$audit_block" | grep -qF '::error::CREDENTIAL LEAK: '; then
  pass "a credential found in a fully-read log is reported as a leak"
else
  fail "the audit reports no distinct credential-leak failure"
fi

# The two reds must never read alike: one means nothing was ruled out, the other
# means something was found.
if echo "$audit_block" | grep -qF 'was read in full and contains'; then
  pass "the leak wording states the log was read in full, distinguishing it from the cannot-read failure"
else
  fail "the leak wording does not distinguish itself from the cannot-read failure"
fi

# A success exit anywhere inside the audit would let a branch that skipped the
# scan report green.
if echo "$audit_block" | grep -qE 'exit 0'; then
  fail "the audit contains an 'exit 0', so some branch can report success without scanning"
else
  pass "the audit contains no early success exit"
fi

# Matched credential material is never echoed: only -q greps run over a job log,
# so the audit can never become the leak it reports.
audit_non_quiet_greps="$(echo "$audit_block" | awk '
  index($0, "grep ") && !index($0, "grep -q") { count++ }
  END { print count + 0 }
')"
if [ "$audit_non_quiet_greps" -eq 0 ]; then
  pass "the audit only ever greps quietly, so it cannot print matched credential material"
else
  fail "the audit runs $audit_non_quiet_greps non-quiet greps, which could print a credential"
fi

if echo "$audit_block" | grep -qF "grep -q 'PRIVATE KEY'" &&
  echo "$audit_block" | grep -qF 'gh[psu]_'; then
  pass "the audit scans for both installation-token and private-key material"
else
  fail "the audit does not scan for both installation-token and private-key material"
fi

if echo "$audit_block" | grep -qF '|| true'; then
  fail "the audit uses '|| true' (fail-fast violation)"
else
  pass "the audit contains no '|| true'"
fi

# --- The scan patterns may not appear in any log the audit reads ---
#
# The runner echoes every `run:` body into the job log under its "Run" group. A
# scan literal sitting in an audited job's source is therefore GUARANTEED to
# appear in the log that job produces, and the audit would match its own words
# and report a leak that does not exist. This is not hypothetical: it is the
# second defect in the in-job design that this job replaces.

validate_outside_audit="$(awk -v job="  $audit_job:" '
  $0 == job { in_audit = 1; next }
  in_audit && /^  [a-zA-Z_#]/ { in_audit = 0 }
  !in_audit { print }
' "$VALIDATE")"

for scan_literal in 'PRIVATE KEY' '[A-Za-z0-9_]{20,}'; do
  literal_outside_audit="$(printf '%s\n' "$validate_outside_audit" | awk -v needle="$scan_literal" '
    index($0, needle) { count++ }
    END { print count + 0 }
  ')"
  if [ "$literal_outside_audit" -eq 0 ]; then
    pass "the scan literal '$scan_literal' appears in no job the audit reads"
  else
    fail "the scan literal '$scan_literal' appears $literal_outside_audit times in a job the audit reads, which is a guaranteed false positive"
  fi
done

# Probe 1's log is produced by the reusable workflow and the composites it
# calls, so their sources have to stay clear of the scan literals too.
for audited_source in "$WORKFLOW" "$SETUP_ACTION" "$REPO_ROOT/auth/action.yml" "$REPO_ROOT/auth/authenticate.sh"; do
  if grep -qF 'PRIVATE KEY' "$audited_source"; then
    fail "$(basename "$audited_source") contains the literal 'PRIVATE KEY', which the audit would match in a probe log"
  else
    pass "$(basename "$audited_source") contains no scan literal the audit would match"
  fi
done

# --- No probe reads a job log itself any more ---
#
# The regression this whole redesign exists to prevent: a running job asking
# GitHub for its own log gets a 404 and fails closed forever.

for probe_job in "${probe_jobs[@]}"; do
  probe_block="$(extract_validate_job "$probe_job")"
  if echo "$probe_block" | grep -qF 'actions/jobs/'; then
    fail "$probe_job reads a job log from inside itself, which 404s while the job runs"
  else
    pass "$probe_job reads no job log from inside itself"
  fi

  if echo "$probe_block" | grep -qF 'actions: read'; then
    fail "$probe_job still requests actions: read, which only a log reader needs"
  else
    pass "$probe_job requests no actions: read permission"
  fi
done

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

# --- Regression guard: the five persistent credential artifacts stay dead ---
#
# Earlier revisions of this repository wrote five credential artifacts and
# removed none of them. HOME and /tmp persist between jobs on a self-hosted
# runner, so a dead installation token was found in plaintext in a runner
# user's HOME hours after its job ended, and every later job — including jobs
# that asked for no organization access at all — picked it up and was answered
# 401 Bad credentials even by PUBLIC repositories. No surface may write any of
# them again. auth/authenticate.sh names them only to remove them, which the
# setup-action-structure suite asserts separately.

AUTH_SCRIPT="$REPO_ROOT/auth/authenticate.sh"
AUTH_ACTION="$REPO_ROOT/auth/action.yml"

legacy_emissions=(
  '> "${HOME}/.netrc"'
  '> "${HOME}/.git-credentials"'
  '> /tmp/netrc'
  'git config --global credential.helper store'
  "netrc-file = /tmp/netrc\\n"
)
for legacy_surface in "$WORKFLOW" "$SETUP_ACTION" "$AUTH_ACTION" "$AUTH_SCRIPT" "$VALIDATE"; do
  legacy_surface_label="${legacy_surface#"$REPO_ROOT"/}"
  for legacy_emission in "${legacy_emissions[@]}"; do
    if grep -qF -e "$legacy_emission" "$legacy_surface"; then
      fail "$legacy_surface_label writes a persistent credential artifact again: $legacy_emission"
    else
      pass "$legacy_surface_label does not write the persistent credential artifact: $legacy_emission"
    fi
  done
done

# The smoke job is the only place this is checked on a REAL runner, so it has to
# state the leftovers are gone rather than merely that new files are job-scoped.
smoke_block="$(extract_validate_job setup-composite-smoke)"

smoke_leftover_checks=(
  'test ! -e /tmp/netrc'
  '"$HOME/.netrc still carries a login x-access-token entry"'
  '"$HOME/.git-credentials still carries an x-access-token credential"'
)
for smoke_leftover_check in "${smoke_leftover_checks[@]}"; do
  if echo "$smoke_block" | grep -qF -e "$smoke_leftover_check"; then
    pass "the setup composite smoke job proves this leftover is gone on a real runner: $smoke_leftover_check"
  else
    fail "the setup composite smoke job does not prove this leftover is gone: $smoke_leftover_check"
  fi
done

if echo "$smoke_block" | grep -qF "grep -qE '^[[:space:]]*(extra-)?access-tokens|^[[:space:]]*netrc-file'"; then
  pass "the setup composite smoke job proves the user nix.conf carries no job credential settings"
else
  fail "the setup composite smoke job does not check the user nix.conf for job credential settings"
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
