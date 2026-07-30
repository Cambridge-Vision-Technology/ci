#!/usr/bin/env bash
set -euo pipefail

# Environment contract. A shell script cannot receive GitHub Actions inputs, so
# every parameter arrives as an environment variable:
#
#   ORG_READ_TOKEN            GitHub token presented to github.com.
#   ORG_READ_OWNER            Organization that scopes Nix extra-access-tokens.
#   ORG_READ_ACCESS_ENABLED   "true" when ORG_READ_TOKEN can read the whole
#                             organization rather than one repository. It installs
#                             the github.com insteadOf rewrites and clears the
#                             repository-scoped credential actions/checkout leaves
#                             in the workspace repository.
#   RUNNER_TEMP               Job-scoped directory that holds every token-bearing file.
#   GITHUB_ENV                Job-scoped environment file that points Nix at the
#                             job-scoped configuration.
#   HOME                      Location of the global git configuration.
#
# Every file this script writes that carries the token lives under RUNNER_TEMP
# at mode 600. Nothing token-bearing is written into HOME, so no plaintext
# credential survives the job on a self-hosted runner.

require_environment() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "authenticate.sh: required environment variable ${name} is unset or empty" >&2
    exit 1
  fi
}

trimmed() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# An optional value pattern confines the removal to the entries this repository
# installs, or in the --local scope to the one entry actions/checkout installs.
# Without one, --unset-all deletes whatever the machine owner or the consumer
# configured, which is not ours to destroy.
unset_git_key() {
  local scope="$1"
  local key="$2"
  local status=0
  shift 2
  git config "$scope" --unset-all "$key" "$@" || status=$?
  # Status 5 means the key was absent, which is the normal first-run case.
  if [ "$status" -ne 0 ] && [ "$status" -ne 5 ]; then
    echo "authenticate.sh: git config ${scope} --unset-all ${key} failed with status ${status}" >&2
    exit "$status"
  fi
}

# git resolves --local against the repository containing the working directory,
# which is where actions/checkout put the credential and where Nix reads a
# remote HEAD from. A job that checked nothing out is a legitimate caller —
# auth/action.yml exists for jobs that manage their own workspace — so an absent
# repository is reported and skipped rather than treated as a failure.
current_git_repository() {
  local status=0 output
  output="$(git rev-parse --absolute-git-dir 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    printf '%s' "$output"
    return
  fi
  echo "authenticate.sh: the working directory $(pwd) is not inside a git repository: ${output}" >&2
}

system_managed_netrc_file() {
  local system_nix_conf line key value found=""
  for system_nix_conf in /etc/nix/nix.conf /etc/nix/nix.custom.conf; do
    [ -f "$system_nix_conf" ] || continue
    [ -r "$system_nix_conf" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      key="${line%%=*}"
      [ "$key" != "$line" ] || continue
      key="$(trimmed "$key")"
      [ "$key" = "netrc-file" ] || continue
      value="${line#*=}"
      found="$(trimmed "$value")"
    done < "$system_nix_conf"
  done
  printf '%s' "$found"
}

# NIX_USER_CONF_FILES replaces the default user configuration list rather than
# extending it, so the machine owner's own file has to be carried forward
# explicitly. Nix applies the list in reverse, so the first entry wins.
default_nix_user_conf_files() {
  local config_directory files=""
  while IFS= read -r config_directory; do
    [ -n "$config_directory" ] || continue
    if [ -n "$files" ]; then
      files="${files}:"
    fi
    files="${files}${config_directory}/nix/nix.conf"
  done < <(printf '%s\n%s\n' "${XDG_CONFIG_HOME:-${HOME}/.config}" "${XDG_CONFIG_DIRS:-/etc/xdg}" | tr ':' '\n')
  printf '%s' "$files"
}

require_environment ORG_READ_TOKEN
require_environment ORG_READ_OWNER
require_environment ORG_READ_ACCESS_ENABLED
require_environment RUNNER_TEMP
require_environment GITHUB_ENV
require_environment HOME

case "$ORG_READ_ACCESS_ENABLED" in
  true | false) ;;
  *)
    echo "authenticate.sh: ORG_READ_ACCESS_ENABLED must be 'true' or 'false', got '${ORG_READ_ACCESS_ENABLED}'" >&2
    exit 1
    ;;
esac

if [ ! -d "$RUNNER_TEMP" ]; then
  echo "authenticate.sh: RUNNER_TEMP=${RUNNER_TEMP} is not a directory" >&2
  exit 1
fi

rm -f "${RUNNER_TEMP}"/github-org-read-netrc.* \
  "${RUNNER_TEMP}"/github-org-read-credentials.* \
  "${RUNNER_TEMP}"/github-org-read-nix-conf.*

# Nix's Git-LFS batch calls and its curl transfers read a netrc file directly,
# named by the netrc-file setting. A job-scoped directory keeps concurrent jobs
# on a self-hosted runner from colliding and lets the runner reclaim the token
# when the job ends.
credential_file="$(mktemp "${RUNNER_TEMP}/github-org-read-netrc.XXXXXXXX")"
chmod 600 "$credential_file"
printf 'machine github.com\nlogin x-access-token\npassword %s\n' "$ORG_READ_TOKEN" > "$credential_file"

# Determinate Nix sets a system-level netrc-file and manages that file for
# FlakeHub. netrc-file is scalar and user configuration outranks system
# configuration, so pointing it at this job's file would silently drop those
# entries. Copy them in behind our own entry instead; netrc readers take the
# first matching machine, so the job token still wins for github.com.
system_netrc_file="$(system_managed_netrc_file)"
if [ -n "$system_netrc_file" ] && [ -e "$system_netrc_file" ]; then
  if [ ! -r "$system_netrc_file" ]; then
    echo "authenticate.sh: the system Nix configuration sets netrc-file = ${system_netrc_file}, which this job cannot read; overriding it would silently break FlakeHub and binary cache authentication" >&2
    exit 1
  fi
  cat "$system_netrc_file" >> "$credential_file"
fi

# The git binary reads a netrc only from $HOME/.netrc, which belongs to the
# machine owner and is not ours to replace or delete. git gets the same token
# through one credential helper bound to a job-scoped file instead. Each
# consumer ends up with exactly one mechanism and neither duplicates the other:
# Nix's LFS transfers cannot call a credential helper, and git cannot be
# pointed at a netrc outside HOME.
git_credential_file="$(mktemp "${RUNNER_TEMP}/github-org-read-credentials.XXXXXXXX")"
chmod 600 "$git_credential_file"
printf 'https://x-access-token:%s@github.com\n' "$ORG_READ_TOKEN" > "$git_credential_file"

# The value pattern matches only a bare `store` helper, which earlier revisions
# of this repository installed against the default $HOME/.git-credentials path,
# and the job-scoped `store --file=…` this script installs. Any other helper the
# machine owner configured — osxkeychain, gh, manager, libsecret — is left alone.
unset_git_key --global credential.helper '^store([[:space:]]|$)'
git config --global --add credential.helper "store --file=${git_credential_file}"

unset_git_key --global 'http.https://github.com/.extraHeader'

# actions/checkout leaves a repository-scoped credential in the LOCAL config of
# the repository it checked out:
#
#   http.https://github.com/.extraheader = AUTHORIZATION: basic <base64 token>
#
# That token reads that one repository and nothing else. Nix makes two git calls
# per flake input and they do not see the same configuration. The fetch runs as
# `git -C <nix cache directory>`, outside the workspace, so it uses the
# credential helper installed above. The HEAD read runs `git ls-remote --symref`
# in the process working directory, which in a job IS the checked-out
# repository, so it picks that header up; and an explicit Authorization header
# stops git falling through to the credential helper, so the organization token
# is never offered on that call. Every cross-repository HEAD read then answers
# 404, Nix warns "could not read HEAD ref … using 'master'", and the fetch fails
# on any repository whose default branch is `main`.
#
# Removed only when this job holds an organization-wide token, so the default
# repository-token path keeps the checkout credential it has always had. The
# value pattern confines the removal to the header actions/checkout writes, and
# its own post-job cleanup checks the key exists before unsetting it, so this is
# invisible to it. Git and git-lfs operations against the consumer's own
# repository keep working, through the credential helper installed above, which
# carries the broader organization token. Submodule configurations are left
# untouched: Nix never reads them, and the consumer's submodule operations are
# not ours to disturb.
if [ "$ORG_READ_ACCESS_ENABLED" = true ]; then
  workspace_git_repository="$(current_git_repository)"
  if [ -n "$workspace_git_repository" ]; then
    unset_git_key --local 'http.https://github.com/.extraHeader' '^AUTHORIZATION:'
    echo "authenticate.sh: cleared the actions/checkout authorization header from ${workspace_git_repository}" >&2
  else
    echo "authenticate.sh: no workspace repository, so there is no actions/checkout authorization header to clear" >&2
  fi
fi

unset_git_key --global 'url.https://github.com/.insteadOf'
if [ "$ORG_READ_ACCESS_ENABLED" = true ]; then
  git config --global --add url."https://github.com/".insteadOf "git@github.com:"
  # The load-bearing form: Nix strips the git+ prefix and hands git a plain
  # ssh://git@github.com/… URL. The other two forms are defensive completeness.
  git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"
  git config --global --add url."https://github.com/".insteadOf "git+ssh://git@github.com/"
fi

# The Nix settings that carry the token stay in a job-scoped file too, reached
# through NIX_USER_CONF_FILES rather than by writing $HOME/.config/nix/nix.conf.
# extra-access-tokens is additive; access-tokens would clobber whatever the
# machine already configures. Path-prefix scoping keeps the token off every
# other host and owner.
nix_conf="$(mktemp "${RUNNER_TEMP}/github-org-read-nix-conf.XXXXXXXX")"
chmod 600 "$nix_conf"
{
  printf 'netrc-file = %s\n' "$credential_file"
  printf 'extra-access-tokens = github.com/%s=%s\n' "$ORG_READ_OWNER" "$ORG_READ_TOKEN"
} > "$nix_conf"

inherited_nix_user_conf_files="${NIX_USER_CONF_FILES:-$(default_nix_user_conf_files)}"
export NIX_USER_CONF_FILES="${nix_conf}:${inherited_nix_user_conf_files}"
printf 'NIX_USER_CONF_FILES=%s\n' "$NIX_USER_CONF_FILES" >> "$GITHUB_ENV"

echo "authenticate.sh: netrc credential file ${credential_file} (mode 600)" >&2
echo "authenticate.sh: git credential file ${git_credential_file} (mode 600)" >&2
echo "authenticate.sh: nix configuration ${nix_conf} (mode 600)" >&2
echo "authenticate.sh: organization read access enabled: ${ORG_READ_ACCESS_ENABLED}" >&2
