#!/usr/bin/env bash
# Behavior tests for the container runtime level (bin/fm-container-lib.sh,
# bin/fm-container-run.sh, bin/fm-container-proxy.mjs, and the container path
# of bin/fm-spawn.sh). No real container runs: a fake `podman` records the
# exact argv, the env file it was handed, and what it could reach, and plays
# the container's hook events back into the event file. The live counterpart,
# which needs podman and a built image, is
# tests/fm-container-runtime-live-e2e.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

RUNNER="$ROOT/bin/fm-container-run.sh"
PROXY="$ROOT/bin/fm-container-proxy.mjs"
TMP_ROOT=$(fm_test_tmproot fm-container-runtime)
export FM_TASK_CLONE_ROOT="$TMP_ROOT/task-clones"
TOKEN_VALUE='sk-ant-oat01-faketoken_ABC-123'

command -v node >/dev/null 2>&1 || fail "node is required by these tests and by the container runtime"

# A fake podman for the runner: `rm` is recorded and succeeds; `run` records
# its argv (NUL-separated), the env file's content, the runner's argv[0], and
# whether the mounted proxy socket answers, then appends hook events and exits
# with FM_FAKE_PODMAN_STATUS.
make_fake_podman() {  # <fakebin>
  cat > "$1/podman" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_PODMAN_LOG:?}
if [ "${1:-}" != run ]; then
  printf '%s\n' "$*" >> "$log.calls"
  [ "${1:-}" != rm ] || exit "${FM_FAKE_PODMAN_RM_STATUS:-0}"
  exit 0
fi
printf '%s\0' "$@" > "$log.argv"
prev=
for a in "$@"; do
  if [ "$prev" = --env-file ]; then cat "$a" > "$log.envfile"; fi
  case "$a" in
    type=bind,src=*,dst=/run/fm-proxy.sock) sock=${a#type=bind,src=}; sock=${sock%,dst=*}; [ -S "$sock" ] && echo socket-up > "$log.socket" ;;
    type=bind,src=*) events_candidate=${a#type=bind,src=}; events_candidate=${events_candidate%%,*}
      case "$events_candidate" in */events) events=$events_candidate ;; esac ;;
  esac
  prev=$a
done
ps -o args= -p "$PPID" > "$log.parent"
if [ -n "${events:-}" ]; then
  printf 'busy user-prompt-submit\n' >> "$events"
  sleep 0.6
  cat "${FM_FAKE_BUSY_RECORD:-/dev/null}" > "$log.busy-mid" 2>/dev/null || true
  printf 'not a hook event\nidle stop\n' >> "$events"
  sleep 0.6
fi
exit "${FM_FAKE_PODMAN_STATUS:-0}"
SH
  chmod +x "$1/podman"
}

# A complete runner world: task channels, a token, an armed busy contract, and
# a spec naming them. Sets W_* globals.
make_runner_world() {  # <name>
  local name=$1 w
  w="$TMP_ROOT/$name"
  W=$w
  W_FAKEBIN="$w/fakebin"
  W_LOG="$w/podman"
  mkdir -p "$W_FAKEBIN" "$w/clone/repo" "$w/project-objects" "$w/clone/container/home/.claude" \
    "$w/state/t1.inbox/handled" "$w/state/operational-inbox" "$w/data/t1" "$w/skills" "$w/config"
  git init -q "$w/clone/repo"
  : > "$w/clone/container/events"
  : > "$w/state/t1.status"
  printf 'brief\n' > "$w/state/operational-inbox/launch-1.msg"
  printf '%s\n' "$TOKEN_VALUE" > "$w/config/container-claude-token"
  chmod 600 "$w/config/container-claude-token"
  make_fake_podman "$W_FAKEBIN"
  W_GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$w/state" t1) || fail "$name: could not arm the busy contract"
  cat > "$w/clone/container/spec" <<EOF
id=t1
name=fm-t1-abcdef012345
home_hash=abcdef012345
image=localhost/test-image:1
pids_limit=2048
memory=8g
cargo_volume=fm-cargo-proj
worktree=$w/clone/repo
objects=$w/project-objects
home=$w/clone/container/home
events=$w/clone/container/events
proxy_log=$w/clone/container/proxy.log
status=$w/state/t1.status
inbox=$w/state/t1.inbox
data=$w/data/t1
record=$w/state/operational-inbox/launch-1.msg
skills=$w/skills
token=$w/config/container-claude-token
state=$w/state
busy_gen=$W_GEN
turnend=$w/state/t1.turn-ended
git_name=Test Builder
git_email=builder@example.invalid
EOF
}

run_runner() {  # <command...>
  FM_FAKE_PODMAN_LOG="$W_LOG" FM_FAKE_BUSY_RECORD="$W/state/t1.busy-state" TERM=xterm-256color \
    PATH="$W_FAKEBIN:$PATH" "$RUNNER" "$W/clone/container/spec" -- "$@"
}

test_runner_runs_podman_with_exactly_the_isolation_flags() {
  local out status actual expected w
  make_runner_world flags
  w=$W
  out=$(FM_FAKE_PODMAN_STATUS=7 run_runner env CLAUDE_X=1 claude --flag 'doorbell text' 2>&1)
  status=$?
  expect_code 7 "$status" "the runner must exit with podman's status"$'\n'"$out"
  actual=$(tr '\0' '\n' < "$W_LOG.argv")
  expected=$(printf '%s\n' \
    run --rm -it \
    --name fm-t1-abcdef012345 \
    --label io.firstmate.task=t1 --label io.firstmate.home=abcdef012345 \
    --userns=keep-id --read-only --tmpfs /tmp --cap-drop all \
    --security-opt no-new-privileges --pids-limit 2048 --memory 8g \
    --network none --workdir "$w/clone/repo" \
    --env-file "<ENVFILE>" \
    -e "HOME=$w/clone/container/home" -e "CLAUDE_CONFIG_DIR=$w/clone/container/home/.claude" \
    -e CARGO_HOME=/cargo \
    -e HTTPS_PROXY=http://127.0.0.1:3128 -e https_proxy=http://127.0.0.1:3128 \
    -e HTTP_PROXY=http://127.0.0.1:3128 -e http_proxy=http://127.0.0.1:3128 \
    -e NO_PROXY= -e no_proxy= \
    -e DISABLE_AUTOUPDATER=1 -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    -e ENABLE_CLAUDEAI_MCP_SERVERS=false -e COMPACT_ADVISER_DISABLE=1 \
    -e FM_TASK_ID=t1 -e TERM=xterm-256color -e LANG=C.UTF-8 \
    -e "GIT_AUTHOR_NAME=Test Builder" -e "GIT_COMMITTER_NAME=Test Builder" \
    -e GIT_AUTHOR_EMAIL=builder@example.invalid -e GIT_COMMITTER_EMAIL=builder@example.invalid \
    --mount "type=bind,src=$w/clone/repo,dst=$w/clone/repo" \
    --mount "type=bind,src=$w/clone/repo/.git/config,dst=$w/clone/repo/.git/config,ro=true" \
    --mount "type=bind,src=$w/clone/repo/.git/hooks,dst=$w/clone/repo/.git/hooks,ro=true" \
    --mount "type=bind,src=$w/project-objects,dst=$w/project-objects,ro=true" \
    --mount "type=bind,src=$w/clone/container/home,dst=$w/clone/container/home" \
    --mount "type=bind,src=$w/clone/container/events,dst=$w/clone/container/events" \
    --mount "type=bind,src=$w/state/t1.status,dst=$w/state/t1.status" \
    --mount "type=bind,src=$w/state/t1.inbox,dst=$w/state/t1.inbox" \
    --mount "type=bind,src=$w/data/t1,dst=$w/data/t1" \
    --mount "type=bind,src=$w/state/operational-inbox/launch-1.msg,dst=$w/state/operational-inbox/launch-1.msg,ro=true" \
    --mount "type=bind,src=$w/skills,dst=$w/skills,ro=true" \
    --mount "type=bind,src=<SOCK>,dst=/run/fm-proxy.sock" \
    --mount type=volume,src=fm-cargo-proj,dst=/cargo \
    --entrypoint /usr/bin/tini localhost/test-image:1 \
    -- /bin/sh -c 'socat TCP-LISTEN:3128,bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:/run/fm-proxy.sock & exec "$@"' fm-container-entry \
    env CLAUDE_X=1 claude --flag 'doorbell text')
  # The private env file and socket live in a fresh directory per launch.
  actual=$(printf '%s\n' "$actual" | sed -E 's#^/.*/fmc\.[A-Za-z0-9]+/env$#<ENVFILE>#; s#^type=bind,src=/.*/fmc\.[A-Za-z0-9]+/proxy\.sock,#type=bind,src=<SOCK>,#')
  [ "$actual" = "$expected" ] || fail "podman argv differs"$'\n'"--- expected ---"$'\n'"$expected"$'\n'"--- actual ---"$'\n'"$actual"
  pass "the runner runs podman with exactly the isolation flags, mounts, and environment"
}

test_runner_mounts_nothing_outside_the_allow_list() {
  local src allowed count=0
  make_runner_world allow-list
  FM_FAKE_PODMAN_STATUS=0 run_runner claude >/dev/null 2>&1 || fail "the runner failed"
  allowed=$(printf '%s\n' "$W/clone/repo" "$W/clone/repo/.git/config" "$W/clone/repo/.git/hooks" "$W/project-objects" "$W/clone/container/home" \
    "$W/clone/container/events" "$W/state/t1.status" "$W/state/t1.inbox" "$W/data/t1" \
    "$W/state/operational-inbox/launch-1.msg" "$W/skills")
  while IFS= read -r src; do
    count=$((count + 1))
    case "$src" in
      */fmc.*/proxy.sock) continue ;;
    esac
    printf '%s\n' "$allowed" | grep -qxF -- "$src" || fail "the container mounts $src, which is not on the allow-list"
  done < <(tr '\0' '\n' < "$W_LOG.argv" | sed -n 's#^type=bind,src=\([^,]*\),.*#\1#p')
  [ "$count" -eq 12 ] || fail "expected 12 bind mounts, found $count"
  tr '\0' '\n' < "$W_LOG.argv" | grep -E 'docker\.sock|podman\.sock|/run/user/|^-v$|^--volume|--privileged|--net(work)?=host|^--cap-add' \
    && fail "the container argv carries a socket, host network, privilege, or unlisted volume flag"
  tr '\0' '\n' < "$W_LOG.argv" | grep -qxF -- "--network" || fail "the container argv has no --network"
  tr '\0' '\n' < "$W_LOG.argv" | grep -qxF -- "type=bind,src=$W/clone/repo/.git/config,dst=$W/clone/repo/.git/config,ro=true" \
    || fail "the clone's git config is writable inside the container, so host-side git could run a planted fsmonitor"
  tr '\0' '\n' < "$W_LOG.argv" | grep -qxF -- "type=bind,src=$W/clone/repo/.git/hooks,dst=$W/clone/repo/.git/hooks,ro=true" \
    || fail "the clone's git hooks are writable inside the container"
  pass "the container mounts nothing outside the allow-list and no runtime socket"
}

test_runner_hands_the_token_only_through_a_private_env_file() {
  local out
  make_runner_world token
  out=$(FM_FAKE_PODMAN_STATUS=0 run_runner claude 2>&1) || fail "the runner failed"$'\n'"$out"
  assert_equals "CLAUDE_CODE_OAUTH_TOKEN=$TOKEN_VALUE" "$(cat "$W_LOG.envfile")" "the env file must carry the token"
  tr '\0' '\n' < "$W_LOG.argv" | grep -qF -- "$TOKEN_VALUE" && fail "the token reached the podman command line"
  assert_not_contains "$out" "$TOKEN_VALUE" "the runner printed the token"
  if find /tmp "${TMPDIR:-/tmp}" -maxdepth 2 -path '*/fmc.*/env' -user "$(id -u)" -exec grep -lF -- "$TOKEN_VALUE" {} + 2>/dev/null | grep -q .; then
    fail "a private env file holding the token survived the launch"
  fi
  assert_equals socket-up "$(cat "$W_LOG.socket" 2>/dev/null)" "the proxy socket was not listening when the container started"
  pass "the token reaches podman only through a private env file removed after the launch"
}

test_runner_refuses_a_token_others_can_read() {
  local out status
  make_runner_world token-mode
  chmod 644 "$W/config/container-claude-token"
  out=$(run_runner claude 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "the runner launched with a group- and world-readable token"
  assert_contains "$out" "mode 644" "the refusal must name the token file's mode"
  assert_not_contains "$out" "$TOKEN_VALUE" "the refusal printed the token"
  assert_absent "$W_LOG.argv" "podman ran despite the refused token"
  pass "the runner refuses a token file others can read"
}

test_runner_refuses_when_the_proxy_cannot_start() {
  local out status
  make_runner_world no-proxy
  printf '#!/usr/bin/env bash\nexit 1\n' > "$W_FAKEBIN/node"
  chmod +x "$W_FAKEBIN/node"
  out=$(run_runner claude 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "the runner launched without its egress proxy"
  assert_contains "$out" "egress proxy did not start" "the refusal must name the proxy"
  assert_absent "$W_LOG.argv" "podman ran without the egress proxy"
  pass "the runner refuses to start a container whose egress proxy is not up"
}

test_runner_relays_hook_events_to_the_host_busy_contract() {
  make_runner_world relay
  FM_FAKE_PODMAN_STATUS=0 run_runner claude >/dev/null 2>&1 || fail "the runner failed"
  assert_contains "$(cat "$W_LOG.busy-mid")" "state=busy source=claude-hook event=user-prompt-submit" \
    "the relayed UserPromptSubmit did not open a busy turn on the host"
  assert_present "$W/state/t1.turn-ended" "the relayed Stop did not touch the host turn-ended notification"
  assert_contains "$(cat "$W/state/t1.busy-state")" "state=idle source=claude-hook event=session-end" \
    "the runner did not close the record with a session end after the container exited"
  assert_contains "$(cat "$W/state/t1.busy-state")" "gen=$W_GEN" "the relay used a gen other than the one the host armed"
  pass "the runner relays the container's hook events to the host busy contract and turn-end notification"
}

test_runner_reads_as_a_live_claude_agent() {
  local parent argv0
  make_runner_world liveness
  FM_FAKE_PODMAN_STATUS=0 run_runner claude >/dev/null 2>&1 || fail "the runner failed"
  parent=$(cat "$W_LOG.parent")
  argv0=${parent%%[[:space:]]*}
  assert_equals fm-claude-container "$argv0" "the runner did not re-execute under its liveness name"
  # shellcheck source=bin/fm-agent-process-lib.sh
  . "$ROOT/bin/fm-agent-process-lib.sh"
  assert_equals agent "$(fm_agent_process_classify bash "$argv0" "$parent")" \
    "a pane running the container runner must classify as a live agent"
  pass "a pane running the container runner reads as a live Claude agent to both liveness probes"
}

# The proxy is exercised through its CLI against a local upstream: an allowed
# CONNECT tunnels, while an unlisted host, an allowed host on another port, and
# a plain HTTP request are refused without any network.
test_proxy_tunnels_only_allow_listed_hosts() {
  local dir out
  dir="$TMP_ROOT/proxy"
  mkdir -p "$dir"
  out=$(node --input-type=module - "$PROXY" "$dir" <<'JS'
import { spawn } from "node:child_process";
import http from "node:http";
import net from "node:net";
import { existsSync, readFileSync } from "node:fs";
const [proxy, dir] = process.argv.slice(2);
const upstream = net.createServer((s) => s.on("data", (d) => s.write("echo:" + d)));
await new Promise((r) => upstream.listen(0, "127.0.0.1", r));
const port = upstream.address().port;
const sock = `${dir}/p.sock`;
const child = spawn(process.execPath, [proxy, "--socket", sock, "--log", `${dir}/log`, "--allow", `localhost:${port}`]);
for (let i = 0; i < 100 && !existsSync(sock); i++) await new Promise((r) => setTimeout(r, 50));
function connect(target) {
  return new Promise((resolve) => {
    const req = http.request({ socketPath: sock, method: "CONNECT", path: target });
    req.on("connect", (res, socket) => {
      if (res.statusCode !== 200) { socket.destroy(); return resolve(String(res.statusCode)); }
      socket.write("hi");
      socket.once("data", (d) => { socket.destroy(); resolve(`200 ${d}`); });
    });
    req.on("error", (e) => resolve(`error ${e.message}`));
    req.end();
  });
}
const results = [];
results.push(await connect(`localhost:${port}`));
results.push(await connect(`LOCALHOST:${port}`));
results.push(await connect("example.com:443"));
results.push(await connect(`localhost:${port + 1}`));
results.push(await connect(`127.0.0.1:${port}`));
results.push(await new Promise((resolve) => {
  const req = http.request({ socketPath: sock, method: "GET", path: "http://example.com/" }, (res) => { res.resume(); resolve(String(res.statusCode)); });
  req.on("error", (e) => resolve(`error ${e.message}`));
  req.end();
}));
child.kill();
upstream.close();
console.log(results.join("|"));
console.log(readFileSync(`${dir}/log`, "utf8").trim().split("\n").map((l) => l.split(" ").slice(1).join(" ")).join("|"));
JS
)
  local verdicts log
  verdicts=$(printf '%s\n' "$out" | sed -n 1p)
  log=$(printf '%s\n' "$out" | sed -n 2p)
  case "$verdicts" in
    "200 echo:hi|200 echo:hi|403|403|403|405") ;;
    *) fail "proxy verdicts differ: $verdicts" ;;
  esac
  assert_contains "$log" "refused example.com:443" "the proxy did not log the refused host"
  assert_contains "$log" "allowed localhost:" "the proxy did not log the allowed tunnel"
  assert_contains "$log" "refused-method GET" "the proxy did not log the refused plain request"
  pass "the egress proxy tunnels only allow-listed host:port pairs and refuses everything else"
}

test_runner_refuses_a_spec_with_an_unknown_key() {
  local out status
  make_runner_world spec-key
  printf 'privileged=true\n' >> "$W/clone/container/spec"
  out=$(run_runner claude 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "the runner accepted a spec with an unknown key"
  assert_contains "$out" "unknown key 'privileged'" "the refusal must name the key"
  assert_absent "$W_LOG.argv" "podman ran on a spec it could not fully read"
  pass "the runner refuses a spec it cannot fully read"
}

# --- fm-spawn integration ---------------------------------------------------

make_spawn_world() {  # <name> <project-name>
  local name=$1 proj_name=$2 case_dir
  case_dir="$TMP_ROOT/spawn-$name"
  S_HOME="$case_dir/home"
  S_PROJ="$case_dir/$proj_name"
  S_WT="$case_dir/wt"
  S_LAUNCH="$case_dir/launch.log"
  S_FAKEBIN=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  make_fake_podman "$S_FAKEBIN"
  fm_test_spawn_home "$S_HOME" claude
  fm_git_worktree "$S_PROJ" "$S_WT" "wt-$name"
  git -C "$S_PROJ" config user.name 'Project Builder'
  git -C "$S_PROJ" config user.email 'project@example.invalid'
  printf 'auto\n' > "$S_HOME/config/claude-permission-mode"
  mkdir -p "$S_HOME/config/container"
  printf 'image=localhost/test-image:1\n# a comment\nmemory=4g\n' > "$S_HOME/config/container/$proj_name"
  printf '%s\n' "$TOKEN_VALUE" > "$S_HOME/config/container-claude-token"
  chmod 600 "$S_HOME/config/container-claude-token"
}

run_container_spawn() {  # <id> <spawn-args...>
  local id=$1
  shift
  fm_test_spawn_brief "$S_HOME" "$id"
  : > "$S_LAUNCH"
  FM_FAKE_LAUNCH_LOG="$S_LAUNCH" fm_test_run_spawn "$S_HOME" "${S_PANE:-$FM_TASK_CLONE_ROOT/$id/${S_PROJ##*/}}" \
    "$S_FAKEBIN" "$id" "$S_PROJ" "$@"
}

test_spawn_launches_a_selected_project_inside_its_container() {
  local id=ctr-ship-z1 out status launch clone cdir state_real spec hooks name
  make_spawn_world ship proj-a
  printf 'on\n' > "$S_HOME/config/claude-sandbox"
  out=$(run_container_spawn "$id" --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "a container ship spawn should succeed"$'\n'"$out"
  clone=$(cd "$FM_TASK_CLONE_ROOT/$id/proj-a" && pwd -P) || fail "the container ship got no task clone"
  cdir="${clone%/*}/container"
  state_real=$(cd "$S_HOME/state" && pwd -P)
  launch=$(cat "$S_LAUNCH")
  assert_contains "$launch" "'$ROOT/bin/fm-container-run.sh' '$cdir/spec' -- env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --permission-mode auto " \
    "the pane must run the claude launch through the container runner"
  assert_not_contains "$launch" '"sandbox"' "the container replaces the Claude sandbox, so the launch must not carry it"
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" "the launch forwarded a host Claude config into the container"
  assert_not_contains "$launch" "export CARGO_HOME=" "the launch carried the sandbox's host cache exports"
  spec=$(cat "$cdir/spec")
  name=$(sed -n 's/^container=//p' "$S_HOME/state/$id.meta")
  case "$name" in fm-"$id"-[0-9a-f]*) ;; *) fail "the task record names no container: '$name'" ;; esac
  assert_grep "runtime=container" "$S_HOME/state/$id.meta" "the task record does not say it runs in the container"
  assert_grep "worktree_layout=clone" "$S_HOME/state/$id.meta" "a container task must work in its own clone"
  assert_contains "$spec" "name=$name" "the spec and the task record disagree on the container name"
  assert_contains "$spec" "image=localhost/test-image:1" "the spec lost the configured image"
  assert_contains "$spec" "memory=4g" "the spec lost the configured memory limit"
  assert_contains "$spec" "pids_limit=2048" "the spec lost the default pids limit"
  assert_contains "$spec" "cargo_volume=fm-cargo-proj-a" "the spec does not name the project's cargo volume"
  assert_contains "$spec" "worktree=$clone" "the spec does not mount the task clone"
  assert_contains "$spec" "status=$state_real/$id.status" "the spec does not mount the status log"
  assert_contains "$spec" "inbox=$state_real/$id.inbox" "the spec does not mount the steering inbox"
  assert_contains "$spec" "record=$state_real/operational-inbox/" "the spec does not mount the launch-brief record"
  assert_contains "$spec" "git_name=Project Builder" "the spec lost the clone's git identity"
  assert_not_contains "$spec" "$TOKEN_VALUE" "the spec carries the token itself"
  [ "$(stat -c %a "$cdir/spec" 2>/dev/null || stat -f %Lp "$cdir/spec")" = 600 ] || fail "the spec is readable by others"
  assert_present "$S_HOME/state/$id.status" "the spawn did not create the status log the container mounts"
  hooks=$(cat "$clone/.claude/settings.local.json")
  assert_contains "$hooks" "busy user-prompt-submit' >> '$cdir/events'" "the UserPromptSubmit hook does not append its event for the relay"
  assert_contains "$hooks" "idle stop' >> '$cdir/events'" "the Stop hook does not append its event for the relay"
  assert_not_contains "$hooks" "fm-busy-event.sh" "a container hook calls the host busy writer it cannot reach"
  jq -e '.hasCompletedOnboarding == true' "$cdir/home/.claude/.claude.json" >/dev/null \
    || fail "the container's Claude config was not marked past onboarding"
  jq -e --arg p "$clone" '.projects[$p].hasTrustDialogAccepted == true' "$cdir/home/.claude/.claude.json" >/dev/null \
    || fail "the clone's workspace trust was not registered in the container's own Claude config"
  [ ! -e "$S_HOME/user-home/.claude.json" ] || ! jq -e --arg p "$clone" '.projects[$p]' "$S_HOME/user-home/.claude.json" >/dev/null \
    || fail "the spawn registered the container clone in the captain's own Claude config"
  pass "a selected project's ship launches inside its container, with the sandbox replaced and the relay wired"
}

test_spawn_gives_a_container_scout_the_container_completion_overlay() {
  local id=ctr-scout-z2 out status
  make_spawn_world scout proj-b
  out=$(run_container_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a container scout spawn should succeed"$'\n'"$out"
  assert_grep "# Captain questions under the container runtime" "$S_HOME/data/$id/launch-brief.md" \
    "a container scout's brief still asks it to run the captain-hold gate it cannot reach"
  assert_grep "runtime=container" "$S_HOME/state/$id.meta" "the scout record does not say it runs in the container"
  pass "a container scout hands its captain-question inventory to firstmate"
}

test_spawn_leaves_unselected_projects_unchanged() {
  local id=ctr-other-z3 out status launch
  make_spawn_world other proj-c
  mv "$S_HOME/config/container/proj-c" "$S_HOME/config/container/some-other-project"
  out=$(S_PANE=$S_WT run_container_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "an unselected project's spawn should succeed"$'\n'"$out"
  launch=$(cat "$S_LAUNCH")
  assert_not_contains "$launch" "fm-container-run.sh" "an unselected project launched in a container"
  assert_no_grep "runtime=" "$S_HOME/state/$id.meta" "an unselected project's record gained a runtime line"
  pass "projects that do not select the container launch exactly as before"
}

expect_container_refusal() {  # <label> <expected-text> <id> <spawn-args...>
  local label=$1 want=$2 id=$3 out status
  shift 3
  out=$(run_container_spawn "$id" "$@")
  status=$?
  [ "$status" -ne 0 ] || fail "$label: the spawn launched"$'\n'"$out"
  assert_contains "$out" "$want" "$label: the refusal does not say why"
  assert_not_contains "$out" "$TOKEN_VALUE" "$label: the refusal printed the token"
  assert_absent "$S_HOME/state/$id.meta" "$label: a task record exists after the refusal"
  assert_absent "$FM_TASK_CLONE_ROOT/$id" "$label: a task clone exists after the refusal"
}

test_spawn_refuses_what_the_container_cannot_run() {
  make_spawn_world refuse-mode proj-d
  expect_container_refusal "no-mistakes ship" "can only ship mode=local-only, not mode=no-mistakes" ctr-r1-z4 --mode no-mistakes --yolo off
  expect_container_refusal "codex harness" "runs only the claude harness" ctr-r2-z4 --harness codex --mode local-only --yolo off
  printf 'bypass\n' > "$S_HOME/config/claude-permission-mode"
  expect_container_refusal "bypass mode" "must be auto" ctr-r3-z4 --mode local-only --yolo off
  printf 'auto\n' > "$S_HOME/config/claude-permission-mode"
  chmod 644 "$S_HOME/config/container-claude-token"
  expect_container_refusal "shared token" "mode 644" ctr-r4-z4 --mode local-only --yolo off
  rm -f "$S_HOME/config/container-claude-token"
  expect_container_refusal "missing token" "container-claude-token must be a readable regular file" ctr-r5-z4 --mode local-only --yolo off
  printf '%s\n' "$TOKEN_VALUE" > "$S_HOME/config/container-claude-token"
  chmod 600 "$S_HOME/config/container-claude-token"
  printf 'image=localhost/x:1\nprivileged=true\n' > "$S_HOME/config/container/proj-d"
  expect_container_refusal "malformed config" "unknown key 'privileged'" ctr-r6-z4 --mode local-only --yolo off
  printf 'memory=8g\n' > "$S_HOME/config/container/proj-d"
  expect_container_refusal "config without image" "names no image" ctr-r7-z4 --mode local-only --yolo off
  printf 'image=localhost/x:1\n' > "$S_HOME/config/container/proj-d"
  rm -f "$S_FAKEBIN/podman"
  PATH=$(fm_test_base_path_sans "$PATH" podman) \
    expect_container_refusal "podman absent" "podman is not installed" ctr-r8-z4 --mode local-only --yolo off
  pass "a project that selects the container refuses every launch the container cannot hold, before any record exists"
}

test_runner_refuses_a_token_others_can_read
test_runner_refuses_when_the_proxy_cannot_start
test_runner_refuses_a_spec_with_an_unknown_key
test_runner_runs_podman_with_exactly_the_isolation_flags
test_runner_mounts_nothing_outside_the_allow_list
test_runner_hands_the_token_only_through_a_private_env_file
test_runner_relays_hook_events_to_the_host_busy_contract
test_runner_reads_as_a_live_claude_agent
test_proxy_tunnels_only_allow_listed_hosts
test_spawn_launches_a_selected_project_inside_its_container
test_spawn_gives_a_container_scout_the_container_completion_overlay
test_spawn_leaves_unselected_projects_unchanged
test_spawn_refuses_what_the_container_cannot_run

echo "# all fm-container-runtime tests passed"
