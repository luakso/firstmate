#!/usr/bin/env bash
# Live guard for the container runtime level (docs/container-runtime.md "Live
# verification"): runs bin/fm-container-run.sh against real rootless Podman and
# the built worker image, with a probe script in place of claude, so it spends
# no model tokens. It proves, from inside the container, that:
#   - the captain's ~/.claude, ~/Projects, ~/Work, ~/.ssh, and ~/.config are
#     absent, and only the allow-listed task paths exist;
#   - the rootfs is read-only, every capability is dropped, and the user is the
#     host user (keep-id);
#   - no container runtime socket is reachable;
#   - a host that is not on the egress allow-list is refused by the proxy, and
#     a direct connection without the proxy has no route at all;
#   - an allow-listed crates.io host answers, and `cargo build` of a crate with
#     a crates.io dependency succeeds through the proxy.
# Default-on wherever podman runs (fm_live_gate); FM_LIVE_CONTAINER=1 forces it
# and turns a missing tool or image into a failure. The image defaults to
# localhost/tokenbook-dev:latest; FM_CONTAINER_LIVE_IMAGE names another.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_LIVE_CONTAINER podman node git script

IMAGE=${FM_CONTAINER_LIVE_IMAGE:-localhost/tokenbook-dev:latest}
if ! podman image exists "$IMAGE" >/dev/null 2>&1; then
  if [ "${FM_LIVE_CONTAINER:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ]; then
    fail "the worker image $IMAGE is not built; build it as docs/container-runtime.md describes"
  fi
  printf 'skip: live: image %s absent\n' "$IMAGE"
  exit 0
fi

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-container-live)
VOLUME="fm-cargo-livetest-$$"
trap 'podman volume rm -f "$VOLUME" >/dev/null 2>&1 || true; fm_test_cleanup' EXIT

# A task world shaped like a real spawn: a project clone and a task clone that
# borrows its objects, the task channels, a container home, and a dummy token
# (claude never runs here).
W="$TMP_ROOT/w"
mkdir -p "$W/home/state/t1.inbox/handled" "$W/home/state/operational-inbox" "$W/home/data/t1" \
  "$W/home/config" "$W/skills"
fm_git_init_commit "$W/project"
CLONE=$(FM_HOME="$W/home" FM_ROOT="$ROOT" FM_TASK_CLONE_ROOT="$W/clones" \
  bash -c '. "$1/bin/fm-task-clone-lib.sh" && fm_task_clone_create "$2" t1 "$3"' _ \
  "$ROOT" "$W/project" "$W/home") || fail "could not create the task clone"
CDIR="${CLONE%/*}/container"
mkdir -p "$CDIR/home/.claude"
: > "$CDIR/events"
: > "$W/home/state/t1.status"
printf 'record\n' > "$W/home/state/operational-inbox/launch-1.msg"
printf 'sk-ant-oat01-livetest-not-a-real-token\n' > "$W/home/config/container-claude-token"
chmod 600 "$W/home/config/container-claude-token"
OBJECTS=$(cd "$W/project/.git/objects" && pwd -P)
cat > "$CDIR/spec" <<EOF
id=t1
name=fm-livetest-$$
home_hash=livetest
image=$IMAGE
pids_limit=2048
memory=4g
cargo_volume=$VOLUME
worktree=$CLONE
objects=$OBJECTS
home=$CDIR/home
events=$CDIR/events
proxy_log=$CDIR/proxy.log
status=$W/home/state/t1.status
inbox=$W/home/state/t1.inbox
data=$W/home/data/t1
record=$W/home/state/operational-inbox/launch-1.msg
skills=$W/skills
token=$W/home/config/container-claude-token
state=$W/home/state
turnend=$W/home/state/t1.turn-ended
EOF

cat > "$CLONE/probe.sh" <<'PROBE'
set -u
real_home=$1
for p in .claude Projects Work .ssh .config .gitconfig .local; do
  [ ! -e "$real_home/$p" ] || { echo "PRESENT $real_home/$p"; exit 10; }
done
echo "home-absent ok"
awk '$2 == "/" { print $4 }' /proc/mounts | grep -q '^ro' || { echo "rootfs writable"; exit 11; }
touch /cargo/.fm-probe || { echo "cargo cache not writable"; exit 12; }
touch /tmp/fm-probe || { echo "tmp not writable"; exit 12; }
echo "readonly ok"
[ "$(id -u)" = "$2" ] || { echo "uid $(id -u) != $2"; exit 13; }
grep -q '^CapEff:[[:space:]]*0*$' /proc/self/status || { grep CapEff /proc/self/status; exit 14; }
echo "caps ok"
for s in /run/docker.sock /var/run/docker.sock /run/podman/podman.sock "/run/user/$2"; do
  [ ! -e "$s" ] || { echo "PRESENT $s"; exit 15; }
done
echo "sockets ok"
code=$(curl -sS -o /dev/null -w '%{http_code}' https://example.com 2>/dev/null) && { echo "example.com reachable ($code)"; exit 16; }
curl -sS --noproxy '*' --max-time 5 -o /dev/null https://1.1.1.1 2>/dev/null && { echo "direct egress reachable"; exit 17; }
echo "refusal ok"
curl -fsS -o /dev/null https://index.crates.io/config.json || { echo "crates index unreachable"; exit 18; }
echo "allow ok"
cd "$(mktemp -d /tmp/probe.XXXXXX)" || exit 19
mkdir src
printf '[package]\nname = "probe"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\nitoa = "1"\n' > Cargo.toml
printf 'fn main() { println!("{}", itoa::Buffer::new().format(42)); }\n' > src/main.rs
CARGO_TARGET_DIR=/tmp/probe-target cargo build -q || { echo "cargo build failed"; exit 20; }
echo "cargo ok"
PROBE

out=$(cd "$CLONE" && script -q -e -c "$(printf '%q ' "$ROOT/bin/fm-container-run.sh" "$CDIR/spec" -- /bin/sh "$CLONE/probe.sh" "$HOME" "$(id -u)")" /dev/null 2>&1)
status=$?
[ "$status" -eq 0 ] || fail "the container probe failed (exit $status)"$'\n'"$out"$'\n'"--- proxy log ---"$'\n'"$(cat "$CDIR/proxy.log" 2>/dev/null)"
for want in "home-absent ok" "readonly ok" "caps ok" "sockets ok" "refusal ok" "allow ok" "cargo ok"; do
  assert_contains "$out" "$want" "the container probe did not report '$want'"
done
assert_grep "refused example.com:443" "$CDIR/proxy.log" "the proxy did not record refusing example.com"
assert_grep "allowed index.crates.io:443" "$CDIR/proxy.log" "the proxy did not record the crates.io index"
assert_grep "allowed static.crates.io:443" "$CDIR/proxy.log" "the proxy did not record the crate download"
podman container exists "fm-livetest-$$" >/dev/null 2>&1 && fail "the --rm container outlived its run"
pass "podman $(podman --version | awk '{print $NF}'): the container sees only its task, refuses unlisted hosts, and builds with crates"
