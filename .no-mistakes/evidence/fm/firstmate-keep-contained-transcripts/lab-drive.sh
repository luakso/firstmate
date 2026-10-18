#!/usr/bin/env bash
# Live lab driver for "archive contained workers' session transcripts at teardown".
# Usage: lab-drive.sh <repo-root> <scenario: happy|symlink|fail-then-retry|uncontained>
# Builds a disposable marked lab FM_HOME and a disposable host HOME, launches a
# REAL rootless Podman container through bin/fm-container-run.sh (a probe stands
# in for claude: it writes Claude-shaped session transcripts into its own
# CLAUDE_CONFIG_DIR and then idles), and runs the REAL bin/fm-teardown.sh.
set -u
ROOT=$1 SCEN=$2
REAL_HOME=$HOME
export XDG_DATA_HOME="$REAL_HOME/.local/share" XDG_CONFIG_HOME="$REAL_HOME/.config"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
HH=$(mktemp -d "${TMPDIR:-/tmp}/fm-labhost.XXXXXX")
export HOME="$HH" FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TASK_CLONE_ROOT
TMUXD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
export TMUX_TMPDIR="$TMUXD"; unset TMUX
ID=t1
cleanup() {
  [ -n "${NAME:-}" ] && podman rm -f --ignore "$NAME" >/dev/null 2>&1
  podman volume rm -f "fm-cargo-labtest-$$" >/dev/null 2>&1
  tmux kill-server 2>/dev/null
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
  chmod -R u+rwX "$LAB" "$HH" 2>/dev/null; rm -rf "$LAB" "$HH"
}
trap cleanup EXIT
echo "== scenario: $SCEN"
echo "lab FM_HOME=$LAB  host HOME=$HH"

git init -q -b main "$LAB/projects/demo"
git -C "$LAB/projects/demo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
CLONE=$(FM_ROOT="$ROOT" bash -c '. "$1/bin/fm-task-clone-lib.sh" && fm_task_clone_create "$2" t1 "$3"' _ "$ROOT" "$LAB/projects/demo" "$LAB") || { echo "clone create failed"; exit 1; }
TASKDIR=${CLONE%/*}; CDIR="$TASKDIR/container"
echo "task clone: $CLONE"
mkdir -p "$CDIR/home/.claude" "$LAB/state/$ID.inbox/handled" "$LAB/state/operational-inbox" "$LAB/data/$ID" "$LAB/skills"
: > "$CDIR/events"; : > "$LAB/state/$ID.status"
printf 'record\n' > "$LAB/state/operational-inbox/launch-1.msg"
printf 'sk-ant-oat01-labtest-not-a-real-token\n' > "$LAB/config/container-claude-token"; chmod 600 "$LAB/config/container-claude-token"
NAME=$(bash -c '. "$1/bin/fm-container-lib.sh" && fm_container_name "$2" "$3"' _ "$ROOT" "$ID" "$LAB")
OBJECTS=$(cd "$LAB/projects/demo/.git/objects" && pwd -P)
cat > "$CDIR/spec" <<EOF
id=$ID
name=$NAME
home_hash=labtest
image=localhost/tokenbook-dev:latest
pids_limit=2048
memory=4g
cargo_volume=fm-cargo-labtest-$$
worktree=$CLONE
objects=$OBJECTS
home=$CDIR/home
events=$CDIR/events
proxy_log=$CDIR/proxy.log
status=$LAB/state/$ID.status
inbox=$LAB/state/$ID.inbox
data=$LAB/data/$ID
record=$LAB/state/operational-inbox/launch-1.msg
skills=$LAB/skills
token=$LAB/config/container-claude-token
state=$LAB/state
turnend=$LAB/state/$ID.turn-ended
EOF
mkdir -p "$LAB/outside/-captain"; printf '{"captain-secret":true}\n' > "$LAB/outside/-captain/secret.jsonl"
cat > "$CLONE/.probe.sh" <<'PROBE'
set -u
mode=$1 outside=$2
p="$CLAUDE_CONFIG_DIR/projects"
if [ "$mode" = symlink ]; then
  ln -s "$outside" "$p"     # worker plants projects -> a host directory
else
  d="$p/$(pwd | tr '/.' '--')"
  mkdir -p "$d/0f1e2d3c-sess/subagents"
  printf '{"type":"user","sessionId":"0f1e2d3c-sess"}\n{"type":"assistant","message":{"usage":{"input_tokens":12,"output_tokens":34}}}\n' > "$d/0f1e2d3c-sess.jsonl"
  printf '{"type":"assistant","isSidechain":true,"message":{"usage":{"output_tokens":5}}}\n' > "$d/0f1e2d3c-sess/subagents/agent-a1.jsonl"
  printf 'notes\n' > "$d/0f1e2d3c-sess/notes.txt"
  ln -s "$outside/-captain/secret.jsonl" "$d/planted.jsonl"
  mkfifo "$d/pipe.jsonl"
fi
echo "PROBE-READY whoami=$(id -u) HOME=$HOME CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"
ls -laR "$CLAUDE_CONFIG_DIR/projects/" 2>&1 | head -30
exec sleep 3600
PROBE
pmode=normal; [ "$SCEN" = symlink ] && pmode=symlink
if [ "$SCEN" != uncontained ]; then
  tmux new-session -d -s firstmate -n fm-t1 -x 200 -y 50 -c "$CLONE" \
    "$(printf '%q ' "$ROOT/bin/fm-container-run.sh" "$CDIR/spec" -- /bin/sh "$CLONE/.probe.sh" "$pmode" "$LAB/outside"); sleep 3600"
  for _ in $(seq 1 90); do tmux capture-pane -p -t firstmate:fm-t1 2>/dev/null | grep -q PROBE-READY && break; sleep 1; done
  echo "--- container pane (inside the real container) ---"; tmux capture-pane -p -t firstmate:fm-t1 | sed '/^$/d' | head -30
  echo "--- podman ps before teardown ---"; podman ps --filter "name=$NAME" --format '{{.Names}} {{.Status}}'
else
  # Not contained: a clone task whose task dir happens to hold a container/home tree.
  tmux new-session -d -s firstmate -n fm-t1 -x 200 -y 50 -c "$CLONE" "sleep 3600"
  d="$CDIR/home/.claude/projects/-x"; mkdir -p "$d"; printf '{"type":"assistant"}\n' > "$d/s.jsonl"
fi
rm -f "$CLONE/.probe.sh" 2>/dev/null
meta=( "window=firstmate:fm-t1" "endpoint_task_id=$ID" "worktree=$CLONE" "project=$LAB/projects/demo" "kind=scout"
       "worktree_layout=clone" "spawn_gen=lab-$ID" )
[ "$SCEN" = uncontained ] || meta+=( "runtime=container" "container=$NAME" )
printf '%s\n' "${meta[@]}" > "$LAB/state/$ID.meta"
printf '# Report\n\n## Captain questions\nNone.\n' > "$LAB/data/$ID/report.md"
"$ROOT/bin/fm-captain-hold.sh" complete "$ID" --none >/dev/null || echo "captain-hold complete failed"
if [ "$SCEN" = fail-then-retry ]; then
  mkdir -p "$HH/.firstmate"; printf 'not a directory\n' > "$HH/.firstmate/session-archive"
fi
run_td() { echo "\$ HOME=$HH FM_HOME=$LAB bin/fm-teardown.sh $ID"; "$ROOT/bin/fm-teardown.sh" "$ID" 2>&1; echo "teardown exit=$?"; }
run_td
if [ "$SCEN" = fail-then-retry ]; then
  echo "--- after failed archive: task dir and transcript kept? ---"
  ls -la "$CDIR/home/.claude/projects/"*/ 2>&1
  [ -e "$LAB/state/$ID.meta" ] && echo "task record kept: $LAB/state/$ID.meta"
  echo "--- captain fixes the cause and re-runs teardown ---"
  rm -f "$HH/.firstmate/session-archive"
  run_td
fi
echo "--- podman ps -a after teardown (expect nothing) ---"; podman ps -a --filter "name=$NAME" --format '{{.Names}} {{.Status}}'
echo "--- task directory exists? ---"; [ -e "$TASKDIR" ] && echo "PRESENT $TASKDIR" || echo "absent: $TASKDIR"
echo "--- archive tree (host HOME/.firstmate/session-archive) ---"
if [ -e "$HH/.firstmate/session-archive" ]; then
  (cd "$HH/.firstmate" && find session-archive -printf '%M %m %y %p\n' | sort -k4)
  find "$HH/.firstmate/session-archive" -type f -name '*.jsonl' -exec sh -c 'echo "## $1"; cat "$1"' _ {} \;
else echo "no archive created"; fi
echo "--- outside dir untouched ---"; cat "$LAB/outside/-captain/secret.jsonl"
echo "--- real operator archive untouched? ---"; ls -d "$REAL_HOME/.firstmate/session-archive" 2>&1
