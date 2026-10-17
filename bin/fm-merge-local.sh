#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's immutable ship branch recorded in
# state/<task-id>.meta ("fm/<id>" for records created before that field existed).
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# The task's existing per-task control lock serializes the captain-hold check
# through that fast-forward. A still-held or unreadable row refuses before the
# merge, so a captain approval must be recorded as an `answer --release` before
# this entrypoint is invoked. The lock ends when the fast-forward returns;
# docs/captain-hold-lifecycle.md owns the accepted merge-to-cleanup residual.
# A sandboxed task's branch lives only in its own task clone
# (state/<id>.meta worktree_layout=clone; bin/fm-task-clone-lib.sh), so every
# check reads it there, through the clone's view of the project's objects, and
# only after the captain-hold check is it fetched into the project under the
# temporary ref refs/fm-task-clone/<task-id>, fast-forwarded onto, and the
# temporary ref deleted again; the project never gains a branch for it.
# A contained task's clone (runtime=container) is read only as data
# (bin/fm-task-clone-lib.sh "CONTAINED CLONES"): its branch is copied into a
# private snapshot, which every check reads and the project fetches from.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-task-clone-lib.sh
. "$SCRIPT_DIR/fm-task-clone-lib.sh"
if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid local merge request" >&2
  exit 2
fi
ID=$1
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor). This action is deliberately NOT
# relocated under the away-posture record: unlike the PR merge it has no
# record-side grant gate of its own, so a parked main keeps it held for the
# captain's return. This precedes reading the task record, because the wrong
# actor is refused for its role whatever it says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"

[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN

MERGE_CONTROL_LOCK=
IMPORT_REF=
MERGE_PRIVATE=
merge_control_cleanup() {
  [ -z "$IMPORT_REF" ] || git -C "$PROJ" update-ref -d "$IMPORT_REF" 2>/dev/null || true
  [ -z "$MERGE_PRIVATE" ] || { chmod -R u+w -- "$MERGE_PRIVATE" 2>/dev/null; rm -rf -- "$MERGE_PRIVATE"; }
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

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

BRANCH=$(grep '^branch=' "$META" | cut -d= -f2- || true)
[ -n "$BRANCH" ] || BRANCH="fm/$ID"
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: task $ID has an invalid recorded ship branch '$BRANCH'" >&2
  exit 1
fi
CLONE=
CLONE_SHAPE=
if [ "$(grep '^worktree_layout=' "$META" | cut -d= -f2- || true)" = clone ]; then
  CLONE=$(grep '^worktree=' "$META" | cut -d= -f2- || true)
  CLONE_SHAPE=$(fm_task_clone_shape "$META")
  fm_task_clone_owned "$CLONE" "$ID" "$FM_HOME" "$CLONE_SHAPE" || { echo "error: task $ID's recorded clone ${CLONE:-<missing>} is not the task clone this home made for it; refusing to merge from it" >&2; exit 1; }
  MERGE_REPO=$CLONE
else
  MERGE_REPO=$PROJ
fi
FETCH_SOURCE=$CLONE
if [ "$CLONE_SHAPE" = container ]; then
  MERGE_PRIVATE=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/fm-merge-local.XXXXXXXX") || { echo "error: could not create a private directory to read task $ID's clone" >&2; exit 1; }
  CLONE_GIT_DIR="$(cd "$CLONE" && pwd -P)/.git"
  fm_task_clone_snapshot "$CLONE_GIT_DIR" "$MERGE_PRIVATE/repo.git" "$PROJ" || { echo "error: cannot read task $ID's clone $CLONE as data: $FM_TASK_CLONE_ERROR" >&2; exit 1; }
  fm_task_clone_snapshot_ref "$CLONE_GIT_DIR" "refs/heads/$BRANCH" || true
  FETCH_SOURCE=$MERGE_PRIVATE/repo.git
fi
merge_repo_git() {
  if [ "$CLONE_SHAPE" = container ]; then
    fm_task_clone_snapshot_git "$@"
  else
    git -C "$MERGE_REPO" "$@"
  fi
}
BRANCH_TIP=$(merge_repo_git rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}") || { echo "error: branch $BRANCH does not exist in $MERGE_REPO" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }
DEFAULT_TIP=$(git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$DEFAULT^{commit}") || { echo "error: cannot resolve local $DEFAULT in $PROJ" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH. A task clone
# reads the project's commits through its alternates, so it can answer this.
if ! merge_repo_git merge-base --is-ancestor "$DEFAULT_TIP" "$BRANCH_TIP"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
hold_status=0
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
case "$hold_status" in
  0)
    echo "error: task $ID is still held for the captain; release it before merging" >&2
    exit 1
    ;;
  1|3) ;;
  *)
    echo "error: could not determine whether task $ID is still held for the captain; refusing to merge" >&2
    exit 1
    ;;
esac
merge_status=0
if [ -n "$CLONE" ]; then
  IMPORT_REF="refs/fm-task-clone/$ID"
  git -C "$PROJ" fetch --quiet --no-tags --no-write-fetch-head "$FETCH_SOURCE" "+refs/heads/$BRANCH:$IMPORT_REF" || {
    echo "error: could not fetch $BRANCH from task clone $CLONE into $PROJ" >&2
    exit 1
  }
  [ "$(git -C "$PROJ" rev-parse --verify --quiet "$IMPORT_REF^{commit}" || true)" = "$BRANCH_TIP" ] || {
    echo "error: $BRANCH moved in task clone $CLONE while it was being fetched; refusing to merge an unchecked head" >&2
    exit 1
  }
fi
git -C "$PROJ" merge --ff-only "$BRANCH_TIP" >/dev/null || merge_status=$?
if [ -n "$IMPORT_REF" ]; then
  git -C "$PROJ" update-ref -d "$IMPORT_REF" || true
  IMPORT_REF=
fi
fm_lock_release "$MERGE_CONTROL_LOCK" || true
MERGE_CONTROL_LOCK=
[ "$merge_status" -eq 0 ] || exit "$merge_status"
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
[ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-fleet-ledger.sh" merged "$ID" local || true
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
