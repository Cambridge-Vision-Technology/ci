#!/usr/bin/env bash
set -euo pipefail

# Contract tests for the composite actions and the shared authentication
# implementation they delegate to:
#
#   setup/action.yml       the full setup composite
#   auth/action.yml        the standalone organization read access action
#   auth/authenticate.sh   the single implementation that writes credentials
#
# Pattern modelled after tests/workflow-structure/test.sh — pure shell, no
# YAML parser, structural grep + line-bounded block extraction.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ACTION="$REPO_ROOT/setup/action.yml"
AUTH_ACTION="$REPO_ROOT/auth/action.yml"
AUTH_SCRIPT="$REPO_ROOT/auth/authenticate.sh"
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

count_occurrences() {
  awk -v needle="$1" 'index($0, needle) { count++ } END { print count + 0 }' "$2"
}

line_of() {
  awk -v needle="$1" 'index($0, needle) { print NR; exit }' "$2"
}

# Extracts the minimum Nix version guard body from any surface. Handles both
# the composite actions (four-space step indent) and the reusable workflow
# (six-space step indent). Whole-line comments are dropped so prose about the
# guard can neither satisfy nor break an assertion about its code.
extract_guard_body() {
  awk '
    index($0, "name: Verify Nix meets the minimum supported version") { in_guard = 1; next }
    !in_guard { next }
    /^[[:space:]]*-[[:space:]]+(name:|uses:)/ { exit }
    /^[[:space:]]*#/ { next }
    { print }
  ' "$1"
}

# --- Files exist at the conventional paths ---

for required_file in "$ACTION" "$AUTH_ACTION" "$AUTH_SCRIPT"; do
  if [[ -f "$required_file" ]]; then
    pass "file exists: ${required_file#"$REPO_ROOT"/}"
  else
    fail "file does not exist: $required_file"
    echo ""
    echo "Results: $passed passed, $failed failed"
    exit 1
  fi
done

if [[ -x "$AUTH_SCRIPT" ]]; then
  pass "auth/authenticate.sh is executable"
else
  fail "auth/authenticate.sh is not executable"
fi

# --- Both actions are declared as composites ---

for composite in "$ACTION" "$AUTH_ACTION"; do
  if grep -qE "^[[:space:]]*using:[[:space:]]*[\"']?composite" "$composite"; then
    pass "declares 'using: composite': ${composite#"$REPO_ROOT"/}"
  else
    fail "does not declare 'using: composite': ${composite#"$REPO_ROOT"/}"
  fi
done

# --- setup/action.yml inputs ---

expected_inputs=(
  enable-ssh-agent
  ssh-private-key
  enable-lfs
  fetch-depth
  checkout
  github-token
  enable-org-read-access
  github-app-id
  github-app-private-key
)
for input_name in "${expected_inputs[@]}"; do
  if grep -qE "^[[:space:]]+${input_name}:" "$ACTION"; then
    pass "setup input declared: $input_name"
  else
    fail "setup input missing: $input_name"
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

if grep -A8 '^[[:space:]]*github-app-private-key:' "$ACTION" | grep -qiE 'secret|sensitive'; then
  pass "github-app-private-key input description mentions secret/sensitive"
else
  fail "github-app-private-key input description does not mention secret/sensitive"
fi

# --- Default values are sane ---

for boolean_input in enable-ssh-agent enable-lfs enable-org-read-access; do
  if grep -A10 "^[[:space:]]*${boolean_input}:" "$ACTION" | grep -qE "^[[:space:]]+default:[[:space:]]*['\"]?false['\"]?"; then
    pass "$boolean_input defaults to false"
  else
    fail "$boolean_input does not default to false"
  fi
done

if grep -A8 '^[[:space:]]*checkout:' "$ACTION" | grep -qE "^[[:space:]]+default:[[:space:]]*['\"]?true['\"]?"; then
  pass "checkout defaults to true"
else
  fail "checkout does not default to true"
fi

if grep -A8 '^[[:space:]]*github-token:' "$ACTION" | grep -qF 'default: ${{ github.token }}'; then
  pass "github-token defaults to the repository token"
else
  fail "github-token does not default to the repository token"
fi

# --- App credential inputs are optional on both composites ---

for composite in "$ACTION" "$AUTH_ACTION"; do
  for optional_input in github-app-id github-app-private-key; do
    if grep -A8 "^[[:space:]]*${optional_input}:" "$composite" | grep -q 'required: false'; then
      pass "${optional_input} stays optional in ${composite#"$REPO_ROOT"/}"
    else
      fail "${optional_input} is not optional in ${composite#"$REPO_ROOT"/}"
    fi
  done
done

# --- The deprecated alias belongs to workflow.yml alone ---
# setup/action.yml never published enable-github-app-auth, so adding it here
# would be a compatibility shim for zero consumers.

for aliasless_surface in "$ACTION" "$AUTH_ACTION"; do
  if grep -q 'enable-github-app-auth' "$aliasless_surface"; then
    fail "${aliasless_surface#"$REPO_ROOT"/} declares enable-github-app-auth, an input it never published"
  else
    pass "${aliasless_surface#"$REPO_ROOT"/} carries no enable-github-app-auth alias"
  fi
done

if grep -q 'enable-github-app-auth' "$WORKFLOW"; then
  pass "the deprecated enable-github-app-auth alias is retained on workflow.yml, which did publish it"
else
  fail "the deprecated enable-github-app-auth alias was dropped from workflow.yml"
fi

# --- Required step names are present ---

required_steps=(
  "Clean up stale git credential config"
  "Mint GitHub App organization installation token"
  "Authenticate git and Nix to github.com"
  "Detect existing Nix"
  "Install Nix when absent"
  "Verify Nix meets the minimum supported version"
  "Add GitHub SSH host keys"
)
for step_name in "${required_steps[@]}"; do
  if grep -qE "name:[[:space:]]*${step_name}" "$ACTION"; then
    pass "step exists: $step_name"
  else
    fail "step missing: $step_name"
  fi
done

# --- Stale credential cleanup stays inline and runs before checkout ---

cleanup_block=""
in_step=false
while IFS= read -r line; do
  if [[ "$line" == *"name: Clean up stale git credential config"* ]]; then
    in_step=true
    cleanup_block+="$line"$'\n'
    continue
  fi
  if $in_step; then
    if [[ "$line" =~ ^[[:space:]]{4}-[[:space:]]+(name:|uses:) ]]; then
      break
    fi
    cleanup_block+="$line"$'\n'
  fi
done < "$ACTION"

cleanup_line="$(line_of 'name: Clean up stale git credential config' "$ACTION")"
checkout_line="$(line_of 'uses: actions/checkout@v4' "$ACTION")"

if [[ -n "$cleanup_line" && -n "$checkout_line" && "$cleanup_line" -lt "$checkout_line" ]]; then
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

# --- Delegation to the single shared implementation ---

if grep -qF '"$GITHUB_ACTION_PATH/../auth/authenticate.sh"' "$ACTION"; then
  pass "setup composite delegates to the shared auth/authenticate.sh"
else
  fail "setup composite does not delegate to the shared auth/authenticate.sh"
fi

if grep -qF '"$GITHUB_ACTION_PATH/authenticate.sh"' "$AUTH_ACTION"; then
  pass "auth composite delegates to the shared auth/authenticate.sh"
else
  fail "auth composite does not delegate to the shared auth/authenticate.sh"
fi

for composite in "$ACTION" "$AUTH_ACTION"; do
  authenticate_steps="$(count_occurrences 'name: Authenticate git and Nix to github.com' "$composite")"
  if [ "$authenticate_steps" -eq 1 ]; then
    pass "exactly one authentication step in ${composite#"$REPO_ROOT"/}"
  else
    fail "${composite#"$REPO_ROOT"/} has $authenticate_steps authentication steps, expected exactly 1"
  fi

  app_token_steps="$(count_occurrences 'actions/create-github-app-token@' "$composite")"
  if [ "$app_token_steps" -eq 1 ]; then
    pass "exactly one create-github-app-token step in ${composite#"$REPO_ROOT"/}"
  else
    fail "${composite#"$REPO_ROOT"/} has $app_token_steps create-github-app-token steps, expected exactly 1"
  fi

  if grep -qF 'actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0' "$composite"; then
    pass "App token action pinned to v3.2.0 commit in ${composite#"$REPO_ROOT"/}"
  else
    fail "App token action not pinned to v3.2.0 commit in ${composite#"$REPO_ROOT"/}"
  fi

  if grep -qF 'permission-contents: read' "$composite" && grep -qF 'owner: ${{ github.repository_owner }}' "$composite"; then
    pass "App token downscoped to contents: read for the owner installation in ${composite#"$REPO_ROOT"/}"
  else
    fail "App token not downscoped to contents: read for the owner installation in ${composite#"$REPO_ROOT"/}"
  fi

  if grep -qF '|| true' "$composite"; then
    fail "${composite#"$REPO_ROOT"/} uses '|| true' (fail-fast violation)"
  else
    pass "${composite#"$REPO_ROOT"/} contains no '|| true'"
  fi
done

# --- Neither composite carries credential-writing logic of its own ---

for composite in "$ACTION" "$AUTH_ACTION"; do
  for forbidden in 'machine github.com' 'credential.helper' '.git-credentials' 'netrc-file' '/tmp/netrc' 'x-access-token'; do
    if grep -qF "$forbidden" "$composite"; then
      fail "${composite#"$REPO_ROOT"/} contains its own credential-writing logic: $forbidden"
    else
      pass "${composite#"$REPO_ROOT"/} contains no credential-writing logic for: $forbidden"
    fi
  done
done

setup_insteadof="$(awk '/^[[:space:]]*#/ { next } index($0, "insteadOf") { count++ } END { print count + 0 }' "$ACTION")"
if [ "$setup_insteadof" -eq 1 ]; then
  pass "insteadOf appears in setup/action.yml only in the inline stale cleanup"
else
  fail "insteadOf appears $setup_insteadof times in setup/action.yml, expected only the inline stale cleanup"
fi

auth_action_insteadof="$(awk '/^[[:space:]]*#/ { next } index($0, "insteadOf") { count++ } END { print count + 0 }' "$AUTH_ACTION")"
if [ "$auth_action_insteadof" -eq 0 ]; then
  pass "auth/action.yml installs no rewrites of its own"
else
  fail "auth/action.yml installs rewrites of its own"
fi

# --- Capability-named token selection ---

if grep -qF "ORG_READ_TOKEN: \${{ inputs.enable-org-read-access == 'true' && steps.org-read-app-token.outputs.token || inputs.github-token }}" "$ACTION"; then
  pass "setup composite selects the App token from the capability input"
else
  fail "setup composite does not select the App token from the capability input"
fi

for composite in "$ACTION" "$AUTH_ACTION"; do
  if grep -qF "ORG_READ_ACCESS_ENABLED: \${{ inputs.enable-org-read-access == 'true' && 'true' || 'false' }}" "$composite"; then
    pass "${composite#"$REPO_ROOT"/} tells the shared script when the token is organization-wide"
  else
    fail "${composite#"$REPO_ROOT"/} does not pass ORG_READ_ACCESS_ENABLED from the capability input"
  fi

  if grep -qF 'ORG_READ_INSTALL_URL_REWRITES' "$composite"; then
    fail "${composite#"$REPO_ROOT"/} still names the token's scope after one of its mechanisms"
  else
    pass "${composite#"$REPO_ROOT"/} carries no mechanism-named ORG_READ_INSTALL_URL_REWRITES"
  fi
done

if grep -qF "ORG_READ_TOKEN: \${{ inputs.enable-org-read-access == 'true' && steps.org-read-app-token.outputs.token || inputs.github-token }}" "$AUTH_ACTION"; then
  pass "auth composite selects the App token from the capability input"
else
  fail "auth composite does not select the App token from the capability input"
fi

for composite in "$ACTION" "$AUTH_ACTION"; do
  if grep -qF 'ORG_READ_OWNER: ${{ github.repository_owner }}' "$composite"; then
    pass "${composite#"$REPO_ROOT"/} scopes Nix access tokens to the repository owner"
  else
    fail "${composite#"$REPO_ROOT"/} does not scope Nix access tokens to the repository owner"
  fi
done

# --- The auth action's contract is an environment side effect ---

if grep -qE '^[[:space:]]{2}token:' "$AUTH_ACTION"; then
  fail "auth/action.yml exposes an output named 'token'"
else
  pass "auth/action.yml exposes no output named 'token'"
fi

if grep -qE '^[[:space:]]{2}org-read-token:' "$AUTH_ACTION"; then
  pass "auth/action.yml names its escape-hatch output org-read-token"
else
  fail "auth/action.yml does not name its escape-hatch output org-read-token"
fi

if grep -qE '^[[:space:]]*enable-org-read-access:' "$AUTH_ACTION"; then
  pass "auth/action.yml exposes the capability input enable-org-read-access"
else
  fail "auth/action.yml does not expose the capability input enable-org-read-access"
fi

# --- The shared script is the only credential-writing implementation ---

credential_writers=0
credential_writer_files=()
while IFS= read -r candidate; do
  if grep -qF 'machine github.com' "$candidate"; then
    credential_writers=$((credential_writers + 1))
    credential_writer_files+=("${candidate#"$REPO_ROOT"/}")
  fi
done < <(find "$REPO_ROOT/auth" "$REPO_ROOT/setup" "$REPO_ROOT/.github" -type f)

if [ "$credential_writers" -eq 1 ] && [ "${credential_writer_files[0]}" = "auth/authenticate.sh" ]; then
  pass "auth/authenticate.sh is the only credential-writing implementation"
else
  fail "expected exactly auth/authenticate.sh to write credentials, found: ${credential_writer_files[*]-none}"
fi

# --- The shared script's own contract ---

if [ "$(sed -n '2p' "$AUTH_SCRIPT")" = "set -euo pipefail" ]; then
  pass "auth/authenticate.sh sets -euo pipefail"
else
  fail "auth/authenticate.sh does not set -euo pipefail on its second line"
fi

for forbidden in '|| true' '2>/dev/null'; do
  if grep -qF "$forbidden" "$AUTH_SCRIPT"; then
    fail "auth/authenticate.sh uses '$forbidden' (fail-fast violation)"
  else
    pass "auth/authenticate.sh contains no '$forbidden'"
  fi
done

if grep -qF -- '-ne 5' "$AUTH_SCRIPT"; then
  pass "auth/authenticate.sh handles git config --unset-all status 5 explicitly"
else
  fail "auth/authenticate.sh does not handle git config --unset-all status 5 explicitly"
fi

if grep -qF '${RUNNER_TEMP}/github-org-read-netrc.XXXXXXXX' "$AUTH_SCRIPT"; then
  pass "auth/authenticate.sh writes the credential file under RUNNER_TEMP"
else
  fail "auth/authenticate.sh does not write the credential file under RUNNER_TEMP"
fi

if grep -qF '/tmp/netrc' "$AUTH_SCRIPT"; then
  fail "auth/authenticate.sh still uses the fixed path /tmp/netrc"
else
  pass "auth/authenticate.sh does not use the fixed path /tmp/netrc"
fi

for job_scoped_file in \
  '${RUNNER_TEMP}/github-org-read-credentials.XXXXXXXX' \
  '${RUNNER_TEMP}/github-org-read-nix-conf.XXXXXXXX'; do
  if grep -qF "$job_scoped_file" "$AUTH_SCRIPT"; then
    pass "auth/authenticate.sh keeps this file under RUNNER_TEMP: $job_scoped_file"
  else
    fail "auth/authenticate.sh does not keep this file under RUNNER_TEMP: $job_scoped_file"
  fi
done

for restricted_file in credential_file git_credential_file nix_conf; do
  if grep -qF "chmod 600 \"\$${restricted_file}\"" "$AUTH_SCRIPT"; then
    pass "auth/authenticate.sh restricts \$${restricted_file} to mode 600"
  else
    fail "auth/authenticate.sh does not restrict \$${restricted_file} to mode 600"
  fi
done

# --- No token-bearing file is written into HOME ---
# A token written under HOME outlives the job on a self-hosted runner, and
# replacing machine-owner files there destroys configuration that is not ours.

for home_write in '${HOME}/.netrc' '${HOME}/.git-credentials' 'ln -s' 'mkdir -p "$nix_conf_directory"'; do
  if grep -qF "$home_write" "$AUTH_SCRIPT"; then
    fail "auth/authenticate.sh still writes into HOME: $home_write"
  else
    pass "auth/authenticate.sh does not write into HOME: $home_write"
  fi
done

home_writes="$(awk '/^[[:space:]]*#/ { next } /(rm|ln|mv|cp|touch|chmod|>)/ && /\$\{?HOME\}?\// { count++ } END { print count + 0 }' "$AUTH_SCRIPT")"
if [ "$home_writes" -eq 0 ]; then
  pass "auth/authenticate.sh never creates, replaces or deletes a file under HOME"
else
  fail "auth/authenticate.sh has $home_writes statements that create, replace or delete files under HOME"
fi

# --- Nix is reconfigured through the job-scoped environment, not HOME state ---

if grep -qF 'NIX_USER_CONF_FILES=%s' "$AUTH_SCRIPT" && grep -qF '>> "$GITHUB_ENV"' "$AUTH_SCRIPT"; then
  pass "auth/authenticate.sh points Nix at the job-scoped configuration through GITHUB_ENV"
else
  fail "auth/authenticate.sh does not point Nix at the job-scoped configuration through GITHUB_ENV"
fi

if grep -qF 'inherited_nix_user_conf_files' "$AUTH_SCRIPT"; then
  pass "auth/authenticate.sh carries the machine owner's existing Nix configuration forward"
else
  fail "auth/authenticate.sh drops the machine owner's existing Nix configuration"
fi

# --- Only the credential helper this repository installed is removed ---

if grep -qF "unset_git_key --global credential.helper '^store([[:space:]]|\$)'" "$AUTH_SCRIPT"; then
  pass "auth/authenticate.sh removes only the store credential helper it installed"
else
  fail "auth/authenticate.sh does not confine the credential.helper removal to its own store helper"
fi

# --- The checkout credential cannot reach Nix's remote HEAD read ---
# actions/checkout leaves a repository-scoped credential in the workspace
# repository's LOCAL config:
#   http.https://github.com/.extraheader = AUTHORIZATION: basic <base64 token>
# Nix's two git calls do not see the same configuration. The fetch runs as
# `git -C <nix cache directory>` and never reads it, but the HEAD read runs
# `git ls-remote --symref` in the process working directory, which in a job IS
# the checked-out repository. It therefore answers 404 for every other
# repository, Nix falls back to 'master', and the fetch fails on any repository
# whose default branch is 'main'. An explicit Authorization header also stops
# git consulting the credential helper, so the organization token never gets
# offered on that call.

if grep -qF "unset_git_key --local 'http.https://github.com/.extraHeader' '^AUTHORIZATION:'" "$AUTH_SCRIPT"; then
  pass "auth/authenticate.sh clears the actions/checkout authorization header from the workspace repository"
else
  fail "auth/authenticate.sh leaves the repository-scoped actions/checkout authorization header in place, so Nix's remote HEAD read cannot see past this repository"
fi

# Without the value pattern this would delete whatever extra headers the
# consumer configured locally, which are not ours to destroy.
if awk '
  index($0, "unset_git_key --local") && index($0, "^AUTHORIZATION:") { found = 1 }
  END { exit !found }
' "$AUTH_SCRIPT"; then
  pass "the local removal is confined by value pattern to the header actions/checkout writes"
else
  fail "the local removal is not confined by a value pattern, so it can delete consumer-owned local configuration"
fi

# Only when the job holds an organization-wide token. On the default path the
# repository token is exactly as narrow as the checkout credential, so removing
# it would change behaviour for no gain.
if awk '
  index($0, "if [ \"$ORG_READ_ACCESS_ENABLED\" = true ]; then") { in_branch = 1; next }
  in_branch && /^fi$/ { in_branch = 0; next }
  in_branch && index($0, "unset_git_key --local") { found = 1 }
  END { exit !found }
' "$AUTH_SCRIPT"; then
  pass "the checkout credential is cleared only when organization read access is enabled"
else
  fail "the checkout credential removal is not guarded by ORG_READ_ACCESS_ENABLED, so it changes the default repository-token path"
fi

local_scope_uses="$(awk '/^[[:space:]]*#/ { next } index($0, "--local") { count++ } END { print count + 0 }' "$AUTH_SCRIPT")"
if [ "$local_scope_uses" -eq 1 ]; then
  pass "auth/authenticate.sh touches the consumer's local git configuration exactly once"
else
  fail "auth/authenticate.sh touches the consumer's local git configuration $local_scope_uses times, expected only the checkout authorization header"
fi

# A job that checked nothing out is a legitimate caller of auth/action.yml, so
# an absent repository is probed for explicitly and reported, never suppressed.
if grep -qF 'git rev-parse --absolute-git-dir 2>&1' "$AUTH_SCRIPT"; then
  pass "auth/authenticate.sh probes for the workspace repository and keeps the failure text"
else
  fail "auth/authenticate.sh does not probe for the workspace repository with an explicit rev-parse that keeps its failure text"
fi

if grep -qF 'no workspace repository, so there is no actions/checkout authorization header to clear' "$AUTH_SCRIPT"; then
  pass "auth/authenticate.sh says so when there is no workspace repository, rather than skipping silently"
else
  fail "auth/authenticate.sh skips the checkout credential removal silently when there is no workspace repository"
fi

# Both scopes go through the one helper that tolerates status 5 and nothing
# else, so neither can regress into `|| true`.
if grep -qF 'git config "$scope" --unset-all "$key" "$@" || status=$?' "$AUTH_SCRIPT"; then
  pass "global and local removals share one helper that branches on the exit status"
else
  fail "global and local removals do not share one status-checking helper"
fi

# auth/action.yml is the surface where the CONSUMER performs the checkout. It
# must not perform one itself — the fix has to work on a checkout it never saw.
if grep -qE 'uses:[[:space:]]*actions/checkout' "$AUTH_ACTION"; then
  fail "auth/action.yml performs a checkout of its own, so it no longer models the consumer-checkout case"
else
  pass "auth/action.yml performs no checkout, so the fix covers a checkout it never performed"
fi

# Stripping persisted credentials at checkout time would fix Nix's HEAD read on
# the two surfaces that own a checkout and do nothing for auth/action.yml, which
# owns none. One mechanism in the shared script covers all three, and leaves
# actions/checkout's own operation and its post-job cleanup untouched.
if grep -qF 'persist-credentials' "$ACTION"; then
  fail "setup/action.yml disables persisted checkout credentials instead of using the shared removal, which cannot cover auth/action.yml"
else
  pass "setup/action.yml leaves actions/checkout's own credential handling alone"
fi

setup_last_checkout_line="$(awk 'index($0, "uses: actions/checkout@") { line = NR } END { print line + 0 }' "$ACTION")"
setup_authenticate_step_line="$(line_of 'name: Authenticate git and Nix to github.com' "$ACTION")"
if [ "$setup_last_checkout_line" -gt 0 ] &&
  [[ -n "$setup_authenticate_step_line" && "$setup_authenticate_step_line" -gt "$setup_last_checkout_line" ]]; then
  pass "authentication runs after every checkout in setup/action.yml, so no checkout can reinstate the header"
else
  fail "a checkout in setup/action.yml runs after authentication and would reinstate the repository-scoped header"
fi

rewrite_forms=(
  'insteadOf "git@github.com:"'
  'insteadOf "ssh://git@github.com/"'
  'insteadOf "git+ssh://git@github.com/"'
)
for rewrite_form in "${rewrite_forms[@]}"; do
  if grep -qF "$rewrite_form" "$AUTH_SCRIPT"; then
    pass "auth/authenticate.sh installs rewrite form: $rewrite_form"
  else
    fail "auth/authenticate.sh does not install rewrite form: $rewrite_form"
  fi
done

if grep -qE 'load-bearing' "$AUTH_SCRIPT"; then
  pass "auth/authenticate.sh documents which rewrite form is load-bearing"
else
  fail "auth/authenticate.sh does not document which rewrite form is load-bearing"
fi

if grep -qF 'extra-access-tokens = github.com/%s=%s' "$AUTH_SCRIPT"; then
  pass "auth/authenticate.sh sets path-prefix scoped extra-access-tokens"
else
  fail "auth/authenticate.sh does not set path-prefix scoped extra-access-tokens"
fi

clobbering_access_tokens="$(awk '/^[[:space:]]*#/ { next } /(^|[^-])access-tokens/ { count++ } END { print count + 0 }' "$AUTH_SCRIPT")"
if [ "$clobbering_access_tokens" -eq 0 ]; then
  pass "auth/authenticate.sh never sets the clobbering access-tokens setting"
else
  fail "auth/authenticate.sh sets the clobbering access-tokens setting"
fi

if grep -qF '/etc/nix/nix.conf /etc/nix/nix.custom.conf' "$AUTH_SCRIPT" &&
  grep -qF 'cat "$system_netrc_file" >> "$credential_file"' "$AUTH_SCRIPT"; then
  pass "auth/authenticate.sh preserves a system-managed netrc rather than clobbering it"
else
  fail "auth/authenticate.sh does not preserve a system-managed netrc"
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

# --- ssh-agent step is gated on enable-ssh-agent input ---

ssh_agent_window="$(grep -A4 -E 'name:[[:space:]]*Start ssh-agent' "$ACTION")"

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

# --- Conditional upstream Nix installation contract ---

extract_named_step() {
  local step_name="$1"
  local in_step=false
  while IFS= read -r line; do
    if [[ "$line" == *"name: ${step_name}" ]]; then
      in_step=true
      echo "$line"
      continue
    fi
    if $in_step; then
      if [[ "$line" =~ ^[[:space:]]{4}-[[:space:]]+(name:|uses:) ]]; then
        break
      fi
      echo "$line"
    fi
  done < "$ACTION"
}

detect_nix_block="$(extract_named_step 'Detect existing Nix')"
install_nix_block="$(extract_named_step 'Install Nix when absent')"

detect_nix_line="$(line_of 'name: Detect existing Nix' "$ACTION")"
install_nix_line="$(line_of 'name: Install Nix when absent' "$ACTION")"

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

if echo "$install_nix_block" | grep -qF "github_access_token: \${{ inputs.enable-org-read-access == 'true' && steps.org-read-app-token.outputs.token || inputs.github-token }}"; then
  pass "upstream installer token selection follows the capability input"
else
  fail "upstream installer token selection does not follow the capability input"
fi

setup_authenticate_line="$(line_of 'name: Authenticate git and Nix to github.com' "$ACTION")"
if [[ -n "$setup_authenticate_line" && -n "$install_nix_line" && "$setup_authenticate_line" -gt "$install_nix_line" ]]; then
  pass "authentication runs after conditional Nix installation"
else
  fail "authentication must run after conditional Nix installation"
fi

# --- Fail-fast minimum Nix version guard ---
# Nix below 2.35.0 builds a malformed Git-LFS endpoint and GitHub answers HTTP
# 422 before it evaluates any credential, so the organization token path cannot
# serve Git LFS. Both this composite and the reusable workflow carry the guard,
# and on both the floor is a literal — a consumer input would let callers
# silently lower it back under the defect.

guard_step_name='name: Verify Nix meets the minimum supported version'
guard_floor_literal='minimum_nix_version="2.35.0"'
guard_block="$(extract_named_step 'Verify Nix meets the minimum supported version')"
guard_line="$(line_of "$guard_step_name" "$ACTION")"

for guard_surface in "$ACTION" "$WORKFLOW"; do
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

  if grep -qF 'echo "::error::$guard_message"' "$guard_surface"; then
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
done

if grep -qE '^[[:space:]]+minimum_nix_version=' "$ACTION"; then
  pass "the floor is declared once at the top of the guard, where it is obvious"
else
  fail "the floor is not declared as a plain shell assignment in setup/action.yml"
fi

if echo "$guard_block" | grep -qF 'RUNNER_LABEL: ${{ runner.name }}'; then
  pass "the guard names the runner it is running on"
else
  fail "the guard does not name the runner it is running on"
fi

if echo "$guard_block" | grep -qF 'exit 1'; then
  pass "the guard step exits non-zero on an unsupported runner"
else
  fail "the guard step never exits non-zero"
fi

guard_message_line="$(awk 'index($0, "guard_message=\"Nix ") { print; exit }' "$ACTION")"
if [[ "$guard_message_line" == *'$found_nix_version'* ]] &&
  [[ "$guard_message_line" == *"\$RUNNER_LABEL"* ]] &&
  [[ "$guard_message_line" == *'$minimum_nix_version'* ]] &&
  [[ "$guard_message_line" == *'HTTP 422'* ]]; then
  pass "the guard message names the found version, runner and required minimum, and why"
else
  fail "the guard message does not name the found version, runner, required minimum and reason"
fi

if [[ -n "$guard_line" && -n "$install_nix_line" && "$guard_line" -gt "$install_nix_line" ]]; then
  pass "the guard runs after conditional Nix installation"
else
  fail "the guard must run after conditional Nix installation"
fi

# The App token is minted earlier in this composite and is already consumed by
# install-nix-action, so the guard cannot and does not gate token use. What it
# gates is the shared authenticate script: the runner is proven to be above the
# floor before any credential is written or Nix is reconfigured.
if [[ -n "$guard_line" && -n "$setup_authenticate_line" && "$guard_line" -lt "$setup_authenticate_line" ]]; then
  pass "the guard runs after Nix installation and before the shared authenticate script configures credentials"
else
  fail "the guard must run before the shared authenticate script configures credentials"
fi

# --- The standalone auth action carries the same floor ---
# It never installs Nix, so it is the surface a self-hosted job uses when it
# manages its own Nix. The floor still has to hold there. An absent `nix` is a
# legitimate credentials-only caller and is skipped explicitly, never with
# `|| true` or a redirected error.

auth_guard_steps="$(count_occurrences "$guard_step_name" "$AUTH_ACTION")"
if [ "$auth_guard_steps" -eq 1 ]; then
  pass "exactly one minimum Nix version guard step in auth/action.yml"
else
  fail "auth/action.yml has $auth_guard_steps minimum Nix version guard steps, expected exactly 1"
fi

auth_floor_literals="$(count_occurrences "$guard_floor_literal" "$AUTH_ACTION")"
if [ "$auth_floor_literals" -eq 1 ]; then
  pass "the 2.35.0 floor is one hard-coded literal in auth/action.yml"
else
  fail "auth/action.yml declares the 2.35.0 floor $auth_floor_literals times, expected exactly 1"
fi

auth_floor_from_input="$(awk 'index($0, "minimum_nix_version=") && (index($0, "inputs.") || index($0, "${{")) { count++ } END { print count + 0 }' "$AUTH_ACTION")"
if [ "$auth_floor_from_input" -eq 0 ]; then
  pass "the floor in auth/action.yml is never read from a consumer input"
else
  fail "auth/action.yml reads the minimum Nix version from an expression, which lets consumers lower the floor"
fi

auth_guard_body="$(extract_guard_body "$AUTH_ACTION")"

if echo "$auth_guard_body" | grep -qF 'if ! command -v nix > /dev/null; then'; then
  pass "auth/action.yml skips the guard through an explicit command -v nix test"
else
  fail "auth/action.yml does not test for nix on PATH with an explicit command -v"
fi

for forbidden in '|| true' '2>/dev/null'; do
  if echo "$auth_guard_body" | grep -qF "$forbidden"; then
    fail "the guard in auth/action.yml uses '$forbidden' to tolerate a missing nix"
  else
    pass "the guard in auth/action.yml contains no '$forbidden'"
  fi
done

auth_guard_successful_exits="$(printf '%s\n' "$auth_guard_body" | awk '/^[[:space:]]*exit 0[[:space:]]*$/ { count++ } END { print count + 0 }')"
if [ "$auth_guard_successful_exits" -eq 2 ]; then
  pass "the guard in auth/action.yml succeeds only when nix is absent or meets the floor"
else
  fail "the guard in auth/action.yml has $auth_guard_successful_exits successful exits, expected the nix-absent and meets-the-floor paths only"
fi

if echo "$auth_guard_body" | grep -qF '::warning::'; then
  fail "the guard in auth/action.yml has a soft-warning path; below the floor must always fail"
else
  pass "the guard in auth/action.yml has no soft-warning path"
fi

if echo "$auth_guard_body" | grep -qF 'RUNNER_OS'; then
  fail "the guard in auth/action.yml branches on the platform, which exempts a runner from the floor"
else
  pass "the guard in auth/action.yml never branches on the platform"
fi

if echo "$auth_guard_body" | grep -qi 'defer'; then
  fail "the guard in auth/action.yml carries a deferral exemption"
else
  pass "the guard in auth/action.yml carries no deferral exemption"
fi

if printf '%s\n' "$auth_guard_body" | awk '
  index($0, "guard_message=\"Nix ") { in_tail = 1; next }
  !in_tail { next }
  /^[[:space:]]*$/ { next }
  { tail = tail $0 "\n"; lines++ }
  END { exit !(lines == 2 && index(tail, "echo \"::error::$guard_message\"") && index(tail, "exit 1")) }
'; then
  pass "a below-floor version in auth/action.yml has exactly one outcome: ::error:: then exit 1"
else
  fail "auth/action.yml does not end the guard with exactly ::error:: and exit 1 after the message"
fi

auth_guard_message_line="$(awk 'index($0, "guard_message=\"Nix ") { print; exit }' "$AUTH_ACTION")"
if [[ "$auth_guard_message_line" == *'$found_nix_version'* ]] &&
  [[ "$auth_guard_message_line" == *"\$RUNNER_LABEL"* ]] &&
  [[ "$auth_guard_message_line" == *'$minimum_nix_version'* ]] &&
  [[ "$auth_guard_message_line" == *'HTTP 422'* ]]; then
  pass "the guard message in auth/action.yml names the found version, runner and required minimum, and why"
else
  fail "the guard message in auth/action.yml does not name the found version, runner, required minimum and reason"
fi

if echo "$auth_guard_body" | grep -qF 'RUNNER_LABEL: ${{ runner.name }}'; then
  pass "the guard in auth/action.yml names the runner it is running on"
else
  fail "the guard in auth/action.yml does not name the runner it is running on"
fi

auth_guard_line="$(line_of "$guard_step_name" "$AUTH_ACTION")"
auth_mint_line="$(line_of 'name: Mint GitHub App organization installation token' "$AUTH_ACTION")"
auth_authenticate_line="$(line_of 'name: Authenticate git and Nix to github.com' "$AUTH_ACTION")"

if [[ -n "$auth_guard_line" && -n "$auth_mint_line" && "$auth_guard_line" -lt "$auth_mint_line" ]]; then
  pass "the guard in auth/action.yml runs before the token is minted, so an unsupported runner costs no credential"
else
  fail "the guard in auth/action.yml must run before the token is minted"
fi

if [[ -n "$auth_guard_line" && -n "$auth_authenticate_line" && "$auth_guard_line" -lt "$auth_authenticate_line" ]]; then
  pass "the guard in auth/action.yml runs before the shared authenticate script configures credentials"
else
  fail "the guard in auth/action.yml must run before the shared authenticate script configures credentials"
fi

if grep -qi 'determinate' "$ACTION"; then
  fail "composite action still references Determinate"
else
  pass "composite action has no Determinate references"
fi

if grep -qi 'magic-nix-cache' "$ACTION"; then
  fail "composite action still references magic-nix-cache"
else
  pass "composite action has no magic-nix-cache references"
fi

# --- Regression guard: no git config --global http.extraHeader (setting) ---

extra_header_settings="$(awk 'index($0, "git config --global") && index($0, ".extraHeader") && !index($0, "--unset") { count++ } END { print count + 0 }' "$ACTION")"
if [ "$extra_header_settings" -ne 0 ]; then
  fail "action sets git config --global http.extraHeader (regression)"
else
  pass "action does not set git config --global http.extraHeader"
fi

# --- The reusable workflow and the composites share one implementation ---

workflow_authenticate_scripts="$(count_occurrences 'auth/authenticate.sh' "$WORKFLOW")"
if [ "$workflow_authenticate_scripts" -ge 1 ]; then
  pass "the reusable workflow also invokes auth/authenticate.sh"
else
  fail "the reusable workflow does not invoke auth/authenticate.sh"
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
