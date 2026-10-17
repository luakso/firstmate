#!/usr/bin/env bash
# fm-container-deliver.sh - publish a contained direct-PR ship's ready branch
# from the host: verify it, push it with the host's own git credentials, open
# or refresh its pull request with gh-axi, and watch the PR's CI. Firstmate
# runs it after such a ship reports `done: ready in branch <branch> for host
# delivery` (docs/container-runtime.md "Host-side delivery").
#
# Usage: fm-container-deliver.sh <task-id> [--ci-wait <seconds>]
#   --ci-wait <seconds>  how long to wait for the PR's checks to settle
#                        (default 1800; 0 reports the PR without waiting)
# FM_CONTAINER_DELIVER_CI_INTERVAL (default 30) is the seconds between check
# reads, and FM_CONTAINER_DELIVER_CI_GRACE (default 180) how long an empty
# check list is awaited before the PR is reported as having no CI.
#
# WHY THE HOST. A contained worker (bin/fm-container-lib.sh) holds no forge
# credentials and has no route to the forge, so a poisoned dependency running
# in its build can push nothing anywhere. This script does only the outward
# steps and never runs project code: no build, test, lint, formatter, git
# hook, or agent runs here. The worker can rewrite anything under the clone's
# .git, even swap the directory, so git never runs in the clone's repository.
# Every git command runs in a private bare repository in a temporary directory,
# with config this script writes: hooks, fsmonitor, the untracked cache,
# commit-graphs, multi-pack-indexes, and pack bitmaps off, and no filter or
# helper defined. It holds a copy of the clone's own object store and borrows
# only the project clone's. The clone's HEAD, branch ref, index, info/exclude,
# and config are read as plain data, and the clone itself is touched only as
# the work tree of the clean-tree status, which runs no git inside a
# submodule. Only the push reads the host's git config, for its credentials;
# it pushes to the project clone's origin URL and never recurses into
# submodules.
#
# WHAT IT REFUSES. It publishes nothing unless every check passes, in order:
#   1. the task record (state/<id>.meta) is a ship with mode=direct-PR and
#      runtime=container, with a valid recorded branch and clone_base=, and
#      its worktree is the task clone this home made for it
#      (fm_task_clone_owned), whose .git holds no commondir file;
#   2. the clone is not shallow, it borrows objects only from its project
#      clone's object store (objects/info/alternates), and its own object
#      store, copied into the private repository without objects/info, holds
#      only regular files and directories, so every object it pushes is one
#      it or its project holds;
#   3. the clone's .git/HEAD reads `ref: refs/heads/<branch>` for the recorded
#      branch, and that ref, loose or in packed-refs, names a commit;
#   4. the clone has no uncommitted change and no untracked file it does not
#      ignore, read against a private copy of its index, a submodule counting
#      only by the commit it records;
#   5. the branch tip descends from clone_base and adds at least one commit;
#   6. no commit after clone_base, merges included, touches a protected path:
#      anything under .github/ in any letter case, which holds the workflows,
#      actions, CODEOWNERS, and other files that decide what GitHub runs with
#      the repository's secrets and who must approve;
#   7. the clone's recorded origin URL is exactly its project clone's origin
#      URL, which names a github.com repository;
#   8. data/<id>/delivery-evidence.md is a regular file, not a symlink, of at
#      most 48 KiB of text whose first line is `head: <the tip's full SHA>`;
#   9. gh-axi is installed.
# A refusal names the failed check, changes nothing, and exits 1.
#
# WHAT IT DOES. It pushes the verified SHA, not the branch name, to
# refs/heads/<branch> at the project clone's origin URL with --no-verify and
# without --force, so a commit made after the checks is never published and a
# remote branch that diverged is refused rather than overwritten, and records
# that SHA as delivered_head= in the task record under its meta lock. It
# refreshes the body of the branch's open PR, or opens one against the
# project's default branch titled with the oldest new commit's subject, and
# marks it ready if it opened as a draft. The PR body is the commit list plus the worker's evidence file, all
# worker-written text. The task's control lock is held from the first check
# through the PR, so teardown, relaunch, or a second delivery cannot
# interleave; it is released before the CI wait.
# It then reads the PR's checks (gh-axi pr checks) until they settle or
# --ci-wait runs out, trusting a read only once gh-axi reports the PR's head
# commit is the pushed SHA (a stale or unreadable head counts as pending, so a
# redelivery never reports the previous head's checks), and appends exactly
# one line to state/<id>.status, the channel the worker reports on, unless the
# task record changed meanwhile:
#   done: PR <url> checks green              every check passed
#   done: PR <url> (no CI checks reported)   none appeared within the grace
#   done: PR <url> (CI checks not settled)   the wait ran out, or --ci-wait 0
#   blocked: PR <url> checks failed: ...     with the failing check names;
#     their failed-job logs are saved for firstmate to relay to the worker in
#     the host-only <task-dir>/container/ci-failures.md, which the container
#     never mounts and teardown removes with the clone
# A done: is the ordinary direct-PR ready signal, which bin/fm-dod-lib.sh
# accepts only while the clone's HEAD is the recorded delivered_head. Exit
# status: 0 after a done:, 3 after the blocked: line, 1 on a refusal or
# failure, 2 on bad usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-task-clone-lib.sh
. "$SCRIPT_DIR/fm-task-clone-lib.sh"
# shellcheck source=bin/fm-container-lib.sh
. "$SCRIPT_DIR/fm-container-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

EVIDENCE_MAX_BYTES=49152
CI_INTERVAL=${FM_CONTAINER_DELIVER_CI_INTERVAL:-30}
CI_GRACE=${FM_CONTAINER_DELIVER_CI_GRACE:-180}
CI_WAIT=1800

usage() {
  sed -n '2,/^set -u/{/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
ID=${1:-}
if [ -z "$ID" ] || ! fm_pr_task_id_valid "$ID"; then
  echo "usage: fm-container-deliver.sh <task-id> [--ci-wait <seconds>]" >&2
  exit 2
fi
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --ci-wait)
      [ $# -ge 2 ] || { echo "error: --ci-wait needs a number of seconds" >&2; exit 2; }
      CI_WAIT=$2
      shift 2
      ;;
    *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
for value in "$CI_WAIT" "$CI_INTERVAL" "$CI_GRACE"; do
  case "$value" in
    ''|*[!0-9]*) echo "error: CI wait, interval, and grace must be whole seconds" >&2; exit 2 ;;
  esac
done

refuse() {
  echo "fm-container-deliver: refusing to deliver $ID: $*" >&2
  exit 1
}
die() {
  echo "fm-container-deliver: $ID: $*" >&2
  exit 1
}

META="$STATE/$ID.meta"
[ -f "$META" ] || refuse "no task record at $META"
meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2-
}

PRIVATE=
CONTROL_LOCK=
META_LOCK=
META_TMP=
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  [ -z "$META_LOCK" ] || fm_lock_release "$META_LOCK" || true
  [ -z "$CONTROL_LOCK" ] || fm_lock_release "$CONTROL_LOCK" || true
  [ -z "$PRIVATE" ] || { chmod -R u+w -- "$PRIVATE" 2>/dev/null; rm -rf -- "$PRIVATE"; }
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

CONTROL_LOCK="$STATE/.control-$ID.lock"
if ! fm_lock_try_acquire "$CONTROL_LOCK"; then
  CONTROL_LOCK=
  refuse "another control action holds task $ID's lock; retry when it has finished"
fi
PRIVATE=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/fm-deliver.XXXXXXXX") || die "could not create a private directory"

# --- 1. the task record ------------------------------------------------------
KIND=$(meta_value kind)
MODE=$(meta_value mode)
RUNTIME=$(meta_value runtime)
BRANCH=$(meta_value branch)
BASE=$(meta_value clone_base)
WT=$(meta_value worktree)
PROJ=$(meta_value project)
SPAWN_GEN=$(meta_value spawn_gen)
[ "${KIND:-ship}" = ship ] || refuse "it is a ${KIND}, not a ship"
[ "$RUNTIME" = container ] || refuse "it does not run in the container runtime; an ordinary direct-PR worker pushes and opens its own PR"
[ "$MODE" = direct-PR ] || refuse "it ships mode=${MODE:-unset}; host delivery publishes only mode=direct-PR (a local-only ship lands through bin/fm-merge-local.sh)"
if [ -z "$BRANCH" ] || ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  refuse "its record names no valid ship branch"
fi
fm_pr_head_valid "$BASE" || refuse "its record has no clone_base= commit, so its branch cannot be checked against where it started"
if [ -n "$WT" ] && { [ -e "$WT/.git/commondir" ] || [ -L "$WT/.git/commondir" ]; }; then
  refuse "the clone's .git holds a commondir file, which would point git at another repository's config"
fi
fm_task_clone_owned "$WT" "$ID" "$FM_HOME" container || refuse "its recorded worktree ${WT:-<missing>} is not the task clone this home made for it"
CLONE_DIR=$(cd "$WT" 2>/dev/null && pwd -P) || refuse "its recorded worktree $WT is unreadable"
CLONE_GIT_DIR=$CLONE_DIR/.git
[ -n "$PROJ" ] && [ -d "$PROJ" ] || refuse "its project clone ${PROJ:-<missing>} is not a directory"

project_git() {
  fm_task_clone_project_git "$PROJ" "$@"
}
# Every git command runs in this private repository (fm_task_clone_snapshot),
# whose config this script writes; the clone's own git files are only ever
# read as data.
PRIV_GIT=$PRIVATE/repo.git
priv_git() {
  fm_task_clone_snapshot_git "$@"
}

# --- 2. the clone's object sources ---------------------------------------------
[ ! -e "$CLONE_GIT_DIR/shallow" ] && [ ! -L "$CLONE_GIT_DIR/shallow" ] || refuse "the clone is shallow"
project_objects=$(fm_task_clone_project_objects "$PROJ") || refuse "the project clone's object store is unreadable"
alternates="$CLONE_GIT_DIR/objects/info/alternates"
if [ -e "$alternates" ] || [ -L "$alternates" ]; then
  alternates_text=$(fm_task_clone_plain_file "$alternates" 65536) || refuse "the clone's objects/info/alternates is not a regular file"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in /*) ;; *) line="$CLONE_GIT_DIR/objects/$line" ;; esac
    real=$(cd "$line" 2>/dev/null && pwd -P) || real=
    [ -n "$real" ] && [ "$real" = "$project_objects" ] ||
      refuse "the clone borrows objects from $line, not only from its project clone's object store"
  done <<<"$alternates_text"
fi
fm_task_clone_snapshot "$CLONE_GIT_DIR" "$PRIV_GIT" "$PROJ" || refuse "$FM_TASK_CLONE_ERROR"

# --- 3. HEAD is the recorded branch --------------------------------------------
[ "$(fm_task_clone_head_data "$CLONE_GIT_DIR")" = "refs/heads/$BRANCH" ] ||
  refuse "the clone's HEAD is not its recorded branch $BRANCH"
TIP=$(fm_task_clone_ref_data "$CLONE_GIT_DIR" "refs/heads/$BRANCH") || refuse "branch $BRANCH has no commit"
printf '%s\n' "$TIP" >"$PRIV_GIT/HEAD" || die "could not create the private repository"
priv_git rev-parse --verify --quiet "$TIP^{commit}" >/dev/null 2>&1 || refuse "branch $BRANCH has no commit"

# --- 4. nothing uncommitted ------------------------------------------------------
dirty=$(fm_task_clone_status "$CLONE_DIR" --porcelain=v1 --untracked-files=all 2>/dev/null) ||
  refuse "the clone's status, index, or info/exclude could not be read"
[ -z "$dirty" ] || refuse "the clone has uncommitted or untracked changes:"$'\n'"$dirty"

# --- 5. descends from where the clone started ------------------------------------
priv_git merge-base --is-ancestor "$BASE" "$TIP" 2>/dev/null ||
  refuse "branch $BRANCH at $TIP does not descend from the commit its clone started from, $BASE"
[ "$TIP" != "$BASE" ] || refuse "branch $BRANCH adds no commit to $BASE"

# --- 6. protected paths ------------------------------------------------------------
if ! touched=$(priv_git log -m --no-renames --name-only --format= "$BASE..$TIP" -- ':(icase).github' 2>/dev/null); then
  refuse "the branch's changed paths could not be read"
fi
touched=$(printf '%s\n' "$touched" | sed '/^$/d' | sort -u)
[ -z "$touched" ] || refuse "the branch changes paths under .github/, which a contained worker never changes:"$'\n'"$touched"

# --- 7. the push target ------------------------------------------------------------
ORIGIN=
if fm_task_clone_plain_file "$CLONE_GIT_DIR/config" 1048576 >"$PRIVATE/clone-config"; then
  ORIGIN=$(priv_git config --no-includes --file "$PRIVATE/clone-config" --get remote.origin.url 2>/dev/null) || ORIGIN=
fi
PROJECT_ORIGIN=$(project_git config --get remote.origin.url 2>/dev/null) || PROJECT_ORIGIN=
[ -n "$ORIGIN" ] && [ "$ORIGIN" = "$PROJECT_ORIGIN" ] ||
  refuse "the clone's origin '${ORIGIN:-<none>}' is not its project clone's origin '${PROJECT_ORIGIN:-<none>}'"
SLUG=$(fm_task_clone_github_slug "$PROJECT_ORIGIN") ||
  refuse "origin '$PROJECT_ORIGIN' does not name a github.com repository, the only forge host delivery opens PRs on"

# --- 8. the worker's evidence --------------------------------------------------------
EVIDENCE="$DATA/$ID/delivery-evidence.md"
[ -f "$EVIDENCE" ] && [ ! -L "$EVIDENCE" ] || refuse "$EVIDENCE is missing or not a regular file; the contained worker writes it after its checks pass"
evidence_id=$(fm_pr_file_identity "$EVIDENCE") || refuse "$EVIDENCE could not be read"
exec 3<"$EVIDENCE" || refuse "$EVIDENCE could not be opened"
# The worker shares this uid, so confirm the file just opened is the regular
# file checked above and not a symlink swapped in since.
if [ "$(uname)" = Darwin ]; then
  opened_id=$(/usr/bin/stat -L -f '%d:%i' /dev/fd/3 2>/dev/null) || opened_id=
else
  opened_id=$(stat -L -c '%d:%i' /dev/fd/3 2>/dev/null) || opened_id=
fi
[ "$opened_id" = "$evidence_id" ] && [ ! -L "$EVIDENCE" ] ||
  refuse "$EVIDENCE changed while it was being opened"
head -c $((EVIDENCE_MAX_BYTES + 1)) <&3 >"$PRIVATE/evidence" || refuse "$EVIDENCE could not be read"
exec 3<&-
[ "$(wc -c <"$PRIVATE/evidence")" -le "$EVIDENCE_MAX_BYTES" ] || refuse "$EVIDENCE is larger than $EVIDENCE_MAX_BYTES bytes"
[ "$(tr -d '\000' <"$PRIVATE/evidence" | wc -c)" = "$(wc -c <"$PRIVATE/evidence")" ] || refuse "$EVIDENCE is not text"
evidence_head=$(head -n 1 "$PRIVATE/evidence" | tr -d '\r')
[ "$evidence_head" = "head: $TIP" ] ||
  refuse "$EVIDENCE names '${evidence_head:-nothing}' on its first line, not 'head: $TIP'; its checks did not run on this commit"

# --- 9. the forge tool -------------------------------------------------------------
command -v gh-axi >/dev/null 2>&1 || refuse "gh-axi is not installed"

# --- publish ------------------------------------------------------------------------
default_branch() {
  local ref branch
  ref=$(project_git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if project_git show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}
BASE_BRANCH=$(default_branch) || die "could not determine the project's default branch (origin/HEAD, main, or master)"

pr_url_of() {  # <text>
  printf '%s\n' "$1" | grep -oE "https://github\.com/$SLUG/pull/[0-9]+" | head -n 1
}
# gh-axi runs from the private directory with an explicit --repo, so it never
# reads the worker's clone.
gh_axi() {  # <args...>
  (cd "$PRIVATE" && fm_run_timed 120 env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh-axi "$@")
}

# The host's own git config applies to the push alone, for its credentials.
if ! push_out=$(cd "$PRIVATE" && fm_run_timed 300 "${FM_TASK_CLONE_GIT_ENV[@]}" \
  git push --no-verify --recurse-submodules=no --porcelain "$PROJECT_ORIGIN" "$TIP:refs/heads/$BRANCH" 2>&1); then
  die "the push of $TIP to $BRANCH on origin failed; nothing was force-pushed:"$'\n'"$push_out"
fi

# Record what was pushed in the host-owned task record, under its meta lock,
# for the Definition-of-done gate on the PR report.
META_LOCK=$(fm_meta_lock_path "$META") || die "pushed $TIP to $BRANCH, but its task record has no lock path"
fm_lock_acquire_wait "$META_LOCK" || { META_LOCK=; die "pushed $TIP to $BRANCH, but could not lock its task record"; }
state_device=$(fm_pr_file_device "$STATE") || die "pushed $TIP to $BRANCH, but could not read $STATE"
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] &&
  [ "$(fm_pr_file_device "$META")" = "$state_device" ] || die "pushed $TIP to $BRANCH, but its task record is unavailable"
[ "$(meta_value spawn_gen)" = "$SPAWN_GEN" ] || die "pushed $TIP to $BRANCH, but its task record changed meanwhile"
META_TMP=$(mktemp "$STATE/.fm-deliver-meta.XXXXXX") || die "pushed $TIP to $BRANCH, but could not rewrite its task record"
if ! { grep -v '^delivered_head=' "$META" || true; printf 'delivered_head=%s\n' "$TIP"; } >"$META_TMP" ||
  ! chmod 0600 "$META_TMP" || ! fm_pr_private_file_valid "$META_TMP" 600 "$state_device" ||
  ! fm_pr_regular_destination_on_device_or_absent "$META" "$state_device" || ! mv -f -- "$META_TMP" "$META"; then
  die "pushed $TIP to $BRANCH, but could not record delivered_head= in its task record"
fi
META_TMP=
fm_lock_release "$META_LOCK" || true
META_LOCK=

{
  printf '## Commits\n\n'
  priv_git log --reverse --format='- %h %s' "$BASE..$TIP"
  printf '\n## Evidence from the contained worker\n\n'
  tail -n +2 "$PRIVATE/evidence"
  printf '\n---\n'
  printf 'Built, checked, and committed inside its task container, which holds no forge credentials; Firstmate pushed %s and opened this PR from the host without running project code there.\n' "$TIP"
} >"$PRIVATE/body.md" || die "could not write the PR body"
title=$(priv_git log --reverse --format=%s "$BASE..$TIP" | head -n 1)
[ -n "$title" ] || title=$BRANCH

if ! list_out=$(gh_axi pr list --repo "$SLUG" --state open --head "$BRANCH" --limit 1 --fields url); then
  die "pushed $TIP to $BRANCH, but could not look up its PR:"$'\n'"$list_out"
fi
PR_URL=$(pr_url_of "$list_out")
if [ -n "$PR_URL" ]; then
  edit_out=$(gh_axi pr edit "${PR_URL##*/}" --repo "$SLUG" --body-file "$PRIVATE/body.md") ||
    die "pushed $TIP to $BRANCH, but could not refresh the body of $PR_URL:"$'\n'"$edit_out"
else
  create_out=$(gh_axi pr create --repo "$SLUG" --title "$title" --body-file "$PRIVATE/body.md" \
    --base "$BASE_BRANCH" --head "$BRANCH") ||
    die "pushed $TIP to $BRANCH, but could not open its PR:"$'\n'"$create_out"
  PR_URL=$(pr_url_of "$create_out")
  [ -n "$PR_URL" ] || die "pushed $TIP to $BRANCH, but gh-axi printed no PR URL:"$'\n'"$create_out"
fi
PR_NUMBER=${PR_URL##*/}
view_out=$(gh_axi pr view "$PR_NUMBER" --repo "$SLUG") || die "opened $PR_URL, but could not read it back:"$'\n'"$view_out"
if printf '%s\n' "$view_out" | grep -qE '^[[:space:]]*draft: yes$'; then
  ready_out=$(gh_axi pr ready "$PR_NUMBER" --repo "$SLUG") || die "$PR_URL opened as a draft and could not be marked ready:"$'\n'"$ready_out"
fi
echo "fm-container-deliver: pushed $TIP to $BRANCH and published $PR_URL"
fm_lock_release "$CONTROL_LOCK" || true
CONTROL_LOCK=

# --- watch CI -------------------------------------------------------------------------
now() { date +%s; }
started=$(now)
verdict=unsettled
checks_out=
while [ "$CI_WAIT" -gt 0 ]; do
  rc=8
  head_out=$(gh_axi api "repos/$SLUG/pulls/$PR_NUMBER" --jq .head.sha) || head_out=
  if [ "$(printf '%s' "$head_out" | tr -d '"[:space:]')" = "$TIP" ]; then
    rc=0
    checks_out=$(gh_axi pr checks "$PR_NUMBER" --repo "$SLUG") || rc=$?
  fi
  case "$rc" in
    0) verdict=green; break ;;
    1)
      # 1 is a failed check, no checks yet, or a gh-axi error; only the first
      # two settle anything.
      if printf '%s\n' "$checks_out" | grep -q 'no check results reported'; then
        [ $(($(now) - started)) -lt "$CI_GRACE" ] || { verdict=none; break; }
      elif printf '%s\n' "$checks_out" | grep '^summary:' | grep -qE '(^|[^0-9])[1-9][0-9]* failed'; then
        verdict=failed
        break
      fi
      ;;
  esac
  [ $(($(now) - started)) -lt "$CI_WAIT" ] || break
  sleep "$CI_INTERVAL"
done

failures_file=
if [ "$verdict" = failed ]; then
  failures_file="$(fm_container_dir "$WT")/ci-failures.md"
  {
    printf '# CI failures for %s at %s\n\n' "$PR_URL" "$TIP"
    printf '```\n'
    gh_axi pr checks "$PR_NUMBER" --repo "$SLUG" --failed || true
    printf '```\n'
    runs=$(gh_axi run list --repo "$SLUG" --commit "$TIP" --status failure --limit 10) || runs=
    for run in $(printf '%s\n' "$runs" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p'); do
      printf '\n## Run %s\n\n```\n' "$run"
      gh_axi run view "$run" --repo "$SLUG" --log-failed || true
      printf '```\n'
    done
  } >"$PRIVATE/ci-failures.md" 2>&1
  mv -f "$PRIVATE/ci-failures.md" "$failures_file" 2>/dev/null || failures_file=
fi

case "$verdict" in
  green) line="done [at=$(now)]: PR $PR_URL checks green" ;;
  none) line="done [at=$(now)]: PR $PR_URL (no CI checks reported)" ;;
  unsettled) line="done [at=$(now)]: PR $PR_URL (CI checks not settled)" ;;
  failed)
    failed_names=$(printf '%s\n' "$checks_out" | sed -n 's/^[[:space:]][[:space:]]*\(.*\),fail$/\1/p' | sed 's/^"\(.*\)"$/\1/' |
      tr '\n' ',' | sed 's/,$//; s/,/, /g')
    [ -n "$failures_file" ] || failures_file="the checks of the PR"
    line="blocked [at=$(now)]: PR $PR_URL checks failed: ${failed_names:-see the PR}; failed-job logs for the contained worker are in $failures_file"
    ;;
esac
echo "fm-container-deliver: $line"
# Report only to the incarnation this delivery verified.
if [ "$(meta_value spawn_gen)" != "$SPAWN_GEN" ]; then
  echo "fm-container-deliver: task $ID's record changed during the CI wait; not reporting to its status" >&2
  exit 1
fi
printf '%s\n' "$line" >>"$STATE/$ID.status" || die "could not append to $STATE/$ID.status"
[ ! -e "$CONFIG/fleet-ledger" ] || "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$STATE/$ID.status" >/dev/null 2>&1 || true
[ "$verdict" != failed ] || exit 3
exit 0
