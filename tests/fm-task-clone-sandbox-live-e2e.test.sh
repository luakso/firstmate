#!/usr/bin/env bash
# Opt-in credentialed Claude live guard for the sandboxed task clone
# (bin/fm-task-clone-lib.sh; docs/configuration.md "The task clone").
# Proves, against the real installed Claude Code sandbox with the fence's core
# settings (bin/fm-spawn.sh's claude_sandbox_settings: sandbox on, no
# unsandboxed escape, start refused when the sandbox is unavailable), that a
# worker whose Bash runs in its own task clone:
#   - commits in its own clone, so the probe really ran inside the fence;
#   - cannot write the project clone's shared git data: a branch ref, the
#     object store;
#   - cannot write another task's git data: another task's clone, or another
#     task's linked-worktree entry in the project clone.
# So the case cannot pass vacuously, the same probe launched in a linked
# worktree of the same project must still write the project clone's refs: that
# is the gap the clone layout closes, and it proves the probe's writes are real.
# Every verdict is read from the filesystem and the probe's own record, never
# from the model's reply. Each launch submits one short prompt, so the guard
# spends model tokens and stays opt-in. The project, clones, and Claude's
# project entries live in a disposable lab; Claude keeps using its existing
# managed authentication.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_TASK_CLONE_SANDBOX_LIVE,FM_CLAUDE_LIVE_E2E claude git jq

# Claude Code's sandbox grants its own temp directory, which is $TMPDIR inside
# a Claude session, so a lab there would read as writable; the lab lives beside
# this checkout instead, as the other Claude live guards' labs do.
LAB="$ROOT/.task-clone-sandbox-live-e2e.$$"
mkdir -p "$LAB"
LAB=$(cd "$LAB" && pwd -P)
PROJECT="$LAB/project"
OTHER_WT="$LAB/other-task-worktree"
HOME_DIR="$LAB/home"
MODEL=${FM_TASK_CLONE_SANDBOX_LIVE_MODEL:-haiku}
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)

cleanup() {
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

fm_git_init_commit "$PROJECT"
fm_git_add_origin "$PROJECT" "$LAB/project.origin.git"
git -C "$PROJECT" worktree add --quiet -b other-task "$OTHER_WT" || fail "could not add the other task's linked worktree"
OTHER_WT_GITDIR=$(git -C "$OTHER_WT" rev-parse --absolute-git-dir)
mkdir -p "$HOME_DIR"

make_clone() {  # <task-id>
  FM_HOME="$HOME_DIR" FM_ROOT="$ROOT" FM_TASK_CLONE_ROOT="$LAB/clones" \
    bash -c '. "$1/bin/fm-task-clone-lib.sh" && fm_task_clone_create "$2" "$3" "$4"' _ \
    "$ROOT" "$PROJECT" "$1" "$HOME_DIR"
}
OWN_CLONE=$(make_clone own-task) || fail "could not create the worker's task clone"
OTHER_CLONE=$(make_clone other-task) || fail "could not create the other task's clone"
SHARED_HEAD=$(git -C "$PROJECT" rev-parse HEAD)

SETTINGS=$(jq -cn '{sandbox: {
  enabled: true,
  failIfUnavailable: true,
  allowUnsandboxedCommands: false,
  network: {strictAllowlist: true, allowedDomains: []}
}}')

# write_probe <file> <record> <label=command>...: a script that attempts each
# write and records `<label>=wrote` or `<label>=refused <error>` in <record>.
write_probe() {
  local file=$1 record=$2 entry
  shift 2
  {
    printf '#!/usr/bin/env bash\n'
    printf 'record=%q\n' "$record"
    cat <<'ATTEMPT'
attempt() {
  local label=$1 out
  shift
  if out=$("$@" 2>&1); then
    printf '%s=wrote\n' "$label"
  else
    printf '%s=refused %s\n' "$label" "$(printf '%s' "$out" | tr '\n' ' ')"
  fi >>"$record"
}
ATTEMPT
    for entry in "$@"; do
      printf 'attempt %s %s\n' "${entry%%=*}" "${entry#*=}"
    done
  } >"$file"
  chmod +x "$file"
}

# run_probe <cwd> <probe>: one sandboxed Claude launch in <cwd> told to run the
# probe once. Its reply is kept only for diagnostics.
run_probe() {
  local cwd=$1 probe=$2 log=$3
  (cd "$cwd" && claude -p --model "$MODEL" --dangerously-skip-permissions --max-turns 4 \
    --settings "$SETTINGS" \
    "Use the Bash tool exactly once to run this exact command, then reply with the single word DONE: bash $probe") \
    >"$log" 2>&1 || true
}

record_value() {  # <record> <label>
  sed -n "s/^$2=//p" "$1" | head -n 1
}

assert_refused_by_fence() {  # <record> <label> <what>
  local value
  value=$(record_value "$1" "$2")
  case "$value" in
    refused*"Read-only file system"*) ;;
    refused*) fail "$3 was refused, but not by the sandbox's read-only mount: $value" ;;
    wrote) fail "$3 succeeded from a sandboxed task clone" ;;
    *) fail "$3 was never attempted; the probe did not run (record: $(cat "$1" 2>/dev/null))" ;;
  esac
}

# The worker in its own clone.
CLONE_RECORD="$LAB/clone-probe.record"
write_probe "$LAB/clone-probe.sh" "$OWN_CLONE/.probe-record" \
  "shared-ref=git -C $(printf '%q' "$PROJECT") update-ref refs/heads/probe-shared $SHARED_HEAD" \
  "shared-objects=touch $(printf '%q' "$PROJECT/.git/objects/probe-file")" \
  "other-clone-ref=git -C $(printf '%q' "$OTHER_CLONE") update-ref refs/heads/probe-other $SHARED_HEAD" \
  "other-worktree-entry=touch $(printf '%q' "$OTHER_WT_GITDIR/probe-file")" \
  "own-commit=git -C $(printf '%q' "$OWN_CLONE") -c core.hooksPath=/dev/null -c user.name=probe -c user.email=probe@example.invalid commit -q --allow-empty -m probe-own"
run_probe "$OWN_CLONE" "$LAB/clone-probe.sh" "$LAB/clone-claude.log"
[ -f "$OWN_CLONE/.probe-record" ] || fail "the sandboxed worker never ran the probe in its task clone; claude ($CLAUDE_VERSION) said: $(tail -n 20 "$LAB/clone-claude.log")"
cp "$OWN_CLONE/.probe-record" "$CLONE_RECORD"

[ "$(record_value "$CLONE_RECORD" own-commit)" = wrote ] \
  || fail "the worker could not commit in its own task clone: $(record_value "$CLONE_RECORD" own-commit)"
[ "$(git -C "$OWN_CLONE" log -1 --format=%s)" = probe-own ] \
  || fail "the worker's own commit did not land in its task clone"
assert_refused_by_fence "$CLONE_RECORD" shared-ref "writing a branch ref of the project clone"
assert_refused_by_fence "$CLONE_RECORD" shared-objects "writing the project clone's object store"
assert_refused_by_fence "$CLONE_RECORD" other-clone-ref "writing another task's clone"
assert_refused_by_fence "$CLONE_RECORD" other-worktree-entry "writing another task's linked-worktree entry"
git -C "$PROJECT" show-ref --verify --quiet refs/heads/probe-shared && fail "the project clone gained the probe's branch ref"
[ ! -e "$PROJECT/.git/objects/probe-file" ] || fail "the project clone's object store gained the probe's file"
git -C "$OTHER_CLONE" show-ref --verify --quiet refs/heads/probe-other && fail "another task's clone gained the probe's branch ref"
[ ! -e "$OTHER_WT_GITDIR/probe-file" ] || fail "another task's worktree entry gained the probe's file"

# The same project seen from a linked worktree: the shared refs are writable.
LINKED_RECORD="$LAB/linked-probe.record"
write_probe "$LAB/linked-probe.sh" "$OTHER_WT/.probe-record" \
  "linked-shared-ref=git -C $(printf '%q' "$PROJECT") update-ref refs/heads/probe-linked $SHARED_HEAD"
run_probe "$OTHER_WT" "$LAB/linked-probe.sh" "$LAB/linked-claude.log"
[ -f "$OTHER_WT/.probe-record" ] || fail "the sandboxed worker never ran the probe in the linked worktree; claude ($CLAUDE_VERSION) said: $(tail -n 20 "$LAB/linked-claude.log")"
cp "$OTHER_WT/.probe-record" "$LINKED_RECORD"
[ "$(record_value "$LINKED_RECORD" linked-shared-ref)" = wrote ] \
  || fail "the control did not reproduce the gap: a sandboxed worker in a linked worktree could not write the project clone's refs ($(record_value "$LINKED_RECORD" linked-shared-ref)), so this guard cannot tell the clone layout's protection from a probe that never writes"
git -C "$PROJECT" show-ref --verify --quiet refs/heads/probe-linked \
  || fail "the linked-worktree control reported a write the project clone does not show"

pass "claude $CLAUDE_VERSION: a sandboxed worker in its own task clone cannot write the project clone's or another task's git data, while a linked worktree still could"
