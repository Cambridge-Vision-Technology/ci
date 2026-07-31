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
# at mode 600. This script writes nothing into HOME and nothing at a fixed path,
# so no plaintext credential it creates survives the job on a self-hosted runner.
#
# It does DELETE from HOME, and only there. Earlier revisions of this repository
# wrote five credential artifacts and removed none of them:
#
#   $HOME/.netrc                                     machine github.com entry
#   /tmp/netrc                                       the same entry, fixed path
#   $HOME/.git-credentials                           https://x-access-token:…
#   global credential.helper store                   bound to the file above
#   ${XDG_CONFIG_HOME:-$HOME/.config}/nix/nix.conf   netrc-file = /tmp/netrc
#
# HOME and /tmp persist between jobs on a self-hosted runner, so those files
# outlive the job that wrote them. A dead installation token was found in
# plaintext in a runner user's HOME hours after its job ended, and any step that
# runs before this script — or that loses NIX_USER_CONF_FILES — still picks the
# stale token up and is answered 401 Bad credentials, even by a PUBLIC
# repository. Removing them is therefore not optional and not conditional; see
# remove_legacy_credential_artifacts.

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

# Every filter below is written in bash builtins alone — no awk, no sed, no cmp.
# That is a hard requirement, not a preference. A self-hosted runner service
# runs with a curated PATH rather than a login shell's: dell-foo's carries
# coreutils, git, grep, sed, jq and curl, and carries NEITHER gawk NOR
# diffutils. An awk in this cleanup is a `command not found` on exactly the
# machines that hold the leaked credential, which is the one place the cleanup
# has to work. bash itself is the only interpreter guaranteed to be present,
# because it is what runs this script.
#
# Keeping the filters in-process also means no filtered COPY of a credential
# file is ever written to disk. An awk pipeline had to stage one under
# RUNNER_TEMP, which briefly put the very token being removed back on the
# filesystem.

# Scratch state shared by the filters. A filter appends the lines it is keeping
# and raises legacy_removed_entry when it drops one this repository wrote.
legacy_kept_lines=()
legacy_removed_entry=false

reset_legacy_filter() {
  legacy_kept_lines=()
  legacy_removed_entry=false
}

keep_legacy_line() {
  legacy_kept_lines+=("$1")
}

# Rewrites a machine-owner file only when the filter actually removed one of
# this repository's own entries. legacy_removed_entry is that decision, taken by
# the filter that recognised its own handiwork; a file we never wrote into never
# raises it and is left with its original inode, mode, owner and modification
# time untouched. When our entry was the only thing in it, the file goes away
# entirely rather than being left as an empty stub the machine owner never asked
# for. Redirecting into the target rather than moving a new file over it keeps
# the machine owner's inode, mode and ownership even when the file does survive.
apply_legacy_filter() {
  local target="$1" description="$2"
  local line has_content=false
  if [ "$legacy_removed_entry" != true ]; then
    return 0
  fi
  for line in ${legacy_kept_lines[@]+"${legacy_kept_lines[@]}"}; do
    case "$line" in
      *[![:space:]]*)
        has_content=true
        break
        ;;
    esac
  done
  if [ "$has_content" = true ]; then
    printf '%s\n' "${legacy_kept_lines[@]}" > "$target"
    echo "authenticate.sh: removed a legacy ${description} from ${target}; every other entry in it was preserved" >&2
  else
    rm -f "$target"
    echo "authenticate.sh: removed ${target}, which held nothing but a legacy ${description}" >&2
  fi
}

# A netrc belongs to the machine owner, so only entries with the exact shape
# earlier revisions of this repository emitted are removed:
#
#   machine github.com
#   login x-access-token
#   password <token>
#
# The match is on the whole entry, not on the machine name: a github.com entry
# with any other login is the machine owner's own credential, an entry carrying
# any further key is not one we wrote, and any other machine is none of our
# business. All of those survive. An entry is anything from a `machine` or
# `default` token up to the next one, so a file that mixes ours with the
# owner's loses only ours.
legacy_netrc_entry_lines=()
legacy_netrc_entry_tokens=()

# Decides one accumulated entry. An entry is ours only when its tokens are
# EXACTLY the six this repository emitted and nothing further, so an entry
# carrying an account, a port or a second machine keyword is not ours and
# survives. Anything not recognised is kept line for line, which is what makes a
# mixed file lose only our entry.
flush_legacy_netrc_entry() {
  local line entry_is_ours=false
  if [ "${#legacy_netrc_entry_lines[@]}" -eq 0 ]; then
    return 0
  fi
  if [ "${#legacy_netrc_entry_tokens[@]}" -eq 6 ] &&
    [ "${legacy_netrc_entry_tokens[0]}" = "machine" ] &&
    [ "${legacy_netrc_entry_tokens[1]}" = "github.com" ] &&
    [ "${legacy_netrc_entry_tokens[2]}" = "login" ] &&
    [ "${legacy_netrc_entry_tokens[3]}" = "x-access-token" ] &&
    [ "${legacy_netrc_entry_tokens[4]}" = "password" ]; then
    entry_is_ours=true
  fi
  if [ "$entry_is_ours" = true ]; then
    legacy_removed_entry=true
  else
    for line in "${legacy_netrc_entry_lines[@]}"; do
      keep_legacy_line "$line"
    done
  fi
  legacy_netrc_entry_lines=()
  legacy_netrc_entry_tokens=()
}

remove_legacy_home_netrc() {
  local netrc="${HOME}/.netrc" line token
  local -a line_tokens=()
  [ -f "$netrc" ] || return 0
  reset_legacy_filter
  legacy_netrc_entry_lines=()
  legacy_netrc_entry_tokens=()
  while IFS= read -r line || [ -n "$line" ]; do
    read -ra line_tokens <<< "$line"
    # A `machine` or `default` keyword opens the next entry, so the one being
    # accumulated is complete and can be decided.
    if [ "${#line_tokens[@]}" -gt 0 ] &&
      { [ "${line_tokens[0]}" = "machine" ] || [ "${line_tokens[0]}" = "default" ]; }; then
      flush_legacy_netrc_entry
    fi
    legacy_netrc_entry_lines+=("$line")
    for token in ${line_tokens[@]+"${line_tokens[@]}"}; do
      legacy_netrc_entry_tokens+=("$token")
    done
  done < "$netrc"
  flush_legacy_netrc_entry
  apply_legacy_filter "$netrc" "machine github.com / login x-access-token netrc entry"
}

# Earlier revisions wrote exactly one line here. Any other line is the machine
# owner's or another tool's and is preserved verbatim.
remove_legacy_home_git_credentials() {
  local git_credentials="${HOME}/.git-credentials" line
  [ -f "$git_credentials" ] || return 0
  reset_legacy_filter
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ ^https://x-access-token:[^@/]*@github\.com/?$ ]]; then
      legacy_removed_entry=true
      continue
    fi
    keep_legacy_line "$line"
  done < "$git_credentials"
  apply_legacy_filter "$git_credentials" "https://x-access-token:<token>@github.com credential line"
}

# A fixed path this repository invented, so unlike the files above there is no
# machine-owner claim on it and no shape to check. On a self-hosted runner it is
# also the artifact most likely to be another user's: /tmp is shared and sticky,
# so only the owner may unlink it. That case is reported loudly and is NOT
# fatal, because the alternative is failing every job on the runner forever over
# a file no job is able to remove; the runner owner is the only one who can.
remove_legacy_fixed_path_netrc() {
  local fixed_path_netrc="/tmp/netrc"
  [ -e "$fixed_path_netrc" ] || return 0
  if [ -O "$fixed_path_netrc" ]; then
    rm -f "$fixed_path_netrc"
    echo "authenticate.sh: removed ${fixed_path_netrc}, a token-bearing file earlier revisions of this repository left at a fixed path" >&2
    return 0
  fi
  echo "authenticate.sh: ${fixed_path_netrc} exists and belongs to another user, so this job cannot unlink it from a sticky /tmp. It may still carry a live token: the runner owner has to delete it." >&2
}

# Only the one setting, and only when it still points at the fixed path this
# repository invented. Every other setting in the file is the machine owner's,
# including a netrc-file that names any other path.
remove_legacy_nix_conf_netrc_file() {
  local nix_conf="${XDG_CONFIG_HOME:-${HOME}/.config}/nix/nix.conf" line key value
  [ -f "$nix_conf" ] || return 0
  reset_legacy_filter
  while IFS= read -r line || [ -n "$line" ]; do
    key="${line%%=*}"
    if [ "$key" != "$line" ]; then
      value="${line#*=}"
      if [ "$(trimmed "$key")" = "netrc-file" ] && [ "$(trimmed "$value")" = "/tmp/netrc" ]; then
        legacy_removed_entry=true
        continue
      fi
    fi
    keep_legacy_line "$line"
  done < "$nix_conf"
  apply_legacy_filter "$nix_conf" "netrc-file = /tmp/netrc setting"
}

remove_legacy_credential_artifacts() {
  remove_legacy_home_netrc
  remove_legacy_home_git_credentials
  remove_legacy_fixed_path_netrc
  remove_legacy_nix_conf_netrc_file
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

# Unconditional, and first. Unconditional because a leftover token harms every
# job on the runner regardless of what the current job asked for: the DEFAULT
# path — no organization access, repository token only — is exactly the path
# that gets handed someone else's expired token and a 401 from a public
# repository. Gating the cleanup on ORG_READ_ACCESS_ENABLED would leave the
# machines that need it most untouched. First, because everything below either
# writes the replacement credentials or points Nix at them, and none of that
# should race a stale file that Nix's default user-config list still names.
# It needs no scratch space and no external command: every filter runs in bash
# builtins, so it also works on a runner whose service PATH carries no awk.
remove_legacy_credential_artifacts

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
# machine owner: this script never writes a token there. The one thing it does
# do to that file is take back the entry earlier revisions of this repository
# put in it, which is a different claim — deleting our own leftover is not the
# same as replacing the owner's file. git gets the token through one credential
# helper bound to a job-scoped file instead. Each consumer ends up with exactly
# one mechanism and neither duplicates the other: Nix's LFS transfers cannot
# call a credential helper, and git cannot be pointed at a netrc outside HOME.
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
