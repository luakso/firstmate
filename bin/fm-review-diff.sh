#!/usr/bin/env bash
# Review a crewmate branch against the authoritative base.
#
# Pooled project clones do not keep their local default branch current, so this
# helper compares remote-backed projects against origin/<default> after fetching
# the default branch, and local-only projects against the local default branch.
# When state/<id>.meta records pr= as a GitHub pull-request URL or a bare
# number for an open PR, the compare side is ALWAYS a freshly fetched
# refs/pull/<n>/head by default so review stays current after no-mistakes fix
# rounds push to the PR. A recorded pr_head= is only a fallback when fetch fails
# (stale recorded SHAs must never win over a reachable remote PR head). If
# neither PR head can be resolved, fall back to the local branch with a warning.
# A GitLab merge request and a Gerrit change expose no comparable ref and record
# no pr_head, so a task recording one always takes that warning path;
# docs/architecture.md owns that fallback. Without pr=, compare the task's
# immutable ship branch recorded in state/<id>.meta ("fm/<id>" for records
# created before that field existed), or the worktree's checked-out branch when
# that branch does not exist in the worktree. A recorded branch that is not a
# valid git branch name is refused instead of taking that fallback, the same
# refusal fm-merge-local.sh applies, so a corrupt meta record can never turn a
# review into a diff of the wrong content.
# A task whose record says runtime=container has a worker that can rewrite
# anything under its clone's .git, so for it git never runs in the clone
# (bin/fm-task-clone-lib.sh "CONTAINED CLONES"): the clone's HEAD and the
# branches above are read as data into a private snapshot whose config this
# script writes, the pull-request and default-branch fetches run there from the
# project clone's origin URL, and the diff runs there without the host's
# global config.
# Usage: fm-review-diff.sh <task-id> [--stat]
#   --stat prints only the stat summary; default prints stat summary plus full diff.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  echo "usage: fm-review-diff.sh <task-id> [--stat]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

ID=${1:-}
[ -n "$ID" ] || { usage; exit 1; }
STAT_ONLY=false
case "${2:-}" in
  '') ;;
  --stat) STAT_ONLY=true ;;
  *) usage; exit 1 ;;
esac
[ $# -le 2 ] || { usage; exit 1; }

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }

WT=$(grep '^worktree=' "$META" | cut -d= -f2-)
PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
[ -n "$WT" ] || { echo "error: meta for task $ID is missing worktree=" >&2; exit 1; }
[ -n "$PROJ" ] || { echo "error: meta for task $ID is missing project=" >&2; exit 1; }
[ -d "$WT" ] || { echo "error: worktree for task $ID is missing: $WT" >&2; exit 1; }
[ -d "$PROJ" ] || { echo "error: project for task $ID is missing: $PROJ" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

BRANCH=$(grep '^branch=' "$META" | cut -d= -f2- || true)
[ -n "$BRANCH" ] || BRANCH="fm/$ID"
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: task $ID has an invalid recorded ship branch '$BRANCH'" >&2
  exit 1
fi

CONTAINED=false
if [ "$(grep '^runtime=' "$META" | tail -1 | cut -d= -f2- || true)" = container ]; then
  CONTAINED=true
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  # shellcheck source=bin/fm-task-clone-lib.sh
  . "$SCRIPT_DIR/fm-task-clone-lib.sh"
  fm_task_clone_shaped "$WT" container || { echo "error: worktree for task $ID is not its task clone: $WT" >&2; exit 1; }
  CLONE_GIT_DIR="$(cd "$WT" && pwd -P)/.git"
  PRIVATE=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/fm-review-diff.XXXXXXXX")
  # shellcheck disable=SC2064  # PRIVATE is fixed from here on
  trap "chmod -R u+w -- '$PRIVATE' 2>/dev/null; rm -rf -- '$PRIVATE'" EXIT
  fm_task_clone_snapshot "$CLONE_GIT_DIR" "$PRIVATE/repo.git" "$PROJ" || { echo "error: $FM_TASK_CLONE_ERROR" >&2; exit 1; }
fi
# git reads the worker copy: for a contained task, its private snapshot, where
# only wt_fetch reads the host's own config, for its credentials.
wt_git() {
  if "$CONTAINED"; then
    (cd "$PRIVATE" && "${FM_TASK_CLONE_GIT_ENV[@]}" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@")
  else
    git -C "$WT" "$@"
  fi
}
wt_fetch() {
  if "$CONTAINED"; then
    (cd "$PRIVATE" && "${FM_TASK_CLONE_GIT_ENV[@]}" git "$@")
  else
    git -C "$WT" "$@"
  fi
}
if "$CONTAINED"; then
  CLONE_HEAD=$(fm_task_clone_head_data "$CLONE_GIT_DIR" || true)
  for ref in "refs/heads/$DEFAULT" "refs/heads/$BRANCH" "$CLONE_HEAD"; do
    case "$ref" in refs/heads/*) ;; *) continue ;; esac
    sha=$(fm_task_clone_ref_data "$CLONE_GIT_DIR" "$ref") || continue
    wt_git update-ref "$ref" "$sha" 2>/dev/null || true
  done
  case "$CLONE_HEAD" in
    refs/heads/*) wt_git symbolic-ref HEAD "$CLONE_HEAD" ;;
    ?*) wt_git update-ref --no-deref HEAD "$CLONE_HEAD" 2>/dev/null || true ;;
  esac
  if PROJECT_ORIGIN=$(git -C "$PROJ" remote get-url origin 2>/dev/null); then
    wt_git config remote.origin.url "$PROJECT_ORIGIN"
  fi
fi

if ! wt_git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
  WANT=$BRANCH
  BRANCH=$(wt_git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$BRANCH" ] || { echo "error: ship branch $WANT does not exist and worktree $WT is detached" >&2; exit 1; }
  wt_git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $WT" >&2; exit 1; }
fi

pr_number_from_target() {
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

fetch_pull_head() {
  local n=$1 resolved
  wt_git remote get-url origin >/dev/null 2>&1 || return 1
  # Fetch into a private ref so a later base-branch fetch cannot clobber the
  # compare tip via FETCH_HEAD, and so we never review a stale local object.
  wt_fetch fetch --quiet origin \
    "+refs/pull/$n/head:refs/fm-review/pull/$n/head" >/dev/null 2>&1 || return 1
  resolved=$(wt_git rev-parse --verify "refs/fm-review/pull/$n/head^{commit}" 2>/dev/null) || return 1
  [ -n "$resolved" ] || return 1
  printf '%s' "$resolved"
}

resolve_pr_head() {
  local pr_url=$1 recorded_head=$2 n resolved
  n=$(pr_number_from_target "$pr_url") || true
  if [ -n "$n" ]; then
    if resolved=$(fetch_pull_head "$n"); then
      printf '%s' "$resolved"
      return 0
    fi
  fi
  # Offline / unreachable remote: recorded pr_head is better than the local
  # branch, but never preferred over a successful pull-head fetch above.
  if [ -n "$recorded_head" ] \
    && wt_git cat-file -e "$recorded_head^{commit}" 2>/dev/null; then
    printf '%s' "$recorded_head"
    return 0
  fi
  return 1
}

PR_URL=$(grep '^pr=' "$META" | tail -1 | cut -d= -f2- || true)
PR_HEAD_RECORDED=$(grep '^pr_head=' "$META" | tail -1 | cut -d= -f2- || true)
COMPARE_REF=$BRANCH
if [ -n "$PR_URL" ]; then
  if PR_HEAD=$(resolve_pr_head "$PR_URL" "$PR_HEAD_RECORDED"); then
    COMPARE_REF=$PR_HEAD
  else
    echo "warning: PR head unavailable; diff may lag the open PR (using local branch $BRANCH)" >&2
  fi
fi

if git -C "$PROJ" remote get-url origin >/dev/null 2>&1; then
  # Update the remote-tracking ref itself; a bare single-branch fetch can leave
  # origin/<default> stale on some Git versions and only refresh FETCH_HEAD.
  wt_fetch fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT" --quiet
  BASE="origin/$DEFAULT"
else
  BASE="$DEFAULT"
fi

wt_git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || { echo "error: base $BASE does not exist in $WT" >&2; exit 1; }
wt_git rev-parse --verify --quiet "$COMPARE_REF^{commit}" >/dev/null || { echo "error: compare ref $COMPARE_REF does not resolve in $WT" >&2; exit 1; }

echo "diff base: $BASE"
if wt_git diff --quiet "$BASE...$COMPARE_REF" --; then
  echo "no changes vs $BASE"
  exit 0
fi

wt_git diff --stat "$BASE...$COMPARE_REF" --
if ! "$STAT_ONLY"; then
  echo
  wt_git diff "$BASE...$COMPARE_REF" --
fi
