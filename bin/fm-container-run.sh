#!/usr/bin/env bash
# fm-container-run.sh - run one Claude worker inside its rootless Podman
# container, as the foreground command of the worker's pane.
#
# Usage: fm-container-run.sh <spec-file> -- <command...>
#   <spec-file>  the per-launch spec bin/fm-spawn.sh writes beside the task
#                clone (fm_container_spec_write in bin/fm-container-lib.sh,
#                which also owns what the container can see and reach)
#   <command>    what runs inside: for a worker, the claude launch
#
# bin/fm-spawn.sh puts this script, not claude, in the pane of a project that
# selects the container runtime (docs/container-runtime.md). The script stays
# on the host for the container's whole life and owns everything that must not
# enter it:
#   1. It re-executes itself under argv[0] fm-claude-container, so the
#      backends' liveness probes read the pane as a live Claude agent for as
#      long as the container runs and as agent-free once it exits.
#   2. It reads the captain's token (config/container-claude-token) and writes
#      it into a 0600 env file inside a private 0700 directory, which it
#      removes on exit; the token never reaches a command line.
#   3. It starts bin/fm-container-proxy.mjs on a Unix socket in that directory
#      with the exact allow-list, and refuses to launch if the proxy does not
#      come up.
#   4. It relays the container's hook events to the busy-state contract and
#      the turn-ended notification (fm_container_relay_event), and after the
#      container exits records a session end, so a container that died without
#      its SessionEnd hook never leaves a stale busy record.
#   5. It runs `podman run` with fm_container_podman_args and exits with
#      podman's status, so the pane returns to its shell exactly when the
#      container is gone (--rm removes it).
# Firstmate's own supervision, the proxy, and the relay never enter the
# container.
# shellcheck disable=SC2154 # the FM_CS_* spec fields are set by fm_container_spec_load (bin/fm-container-lib.sh).
set -u

if [ "${FM_CONTAINER_RUN_NAMED:-}" != 1 ]; then
  FM_CONTAINER_RUN_NAMED=1 exec -a fm-claude-container "${BASH:-bash}" "$0" "$@"
fi
unset FM_CONTAINER_RUN_NAMED

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=bin/fm-container-lib.sh
. "$SCRIPT_DIR/fm-container-lib.sh"

die() {
  echo "fm-container-run: $*" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/{/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
[ $# -ge 3 ] && [ "$2" = -- ] || die "usage: fm-container-run.sh <spec-file> -- <command...>"
SPEC=$1
shift 2

fm_container_spec_load "$SPEC" || exit 1
fm_container_token_read "$FM_CS_token" || exit 1
command -v podman >/dev/null 2>&1 || die "podman is not installed; this project selects the container runtime (docs/container-runtime.md)"
command -v node >/dev/null 2>&1 || die "node is not installed; the container runtime's egress proxy needs it"
[ -f "$FM_CS_events" ] || die "the hook event file $FM_CS_events is missing"
if [ ! -f "$FM_CS_worktree/.git/config" ] || [ -L "$FM_CS_worktree/.git/config" ] ||
  [ ! -d "$FM_CS_worktree/.git/hooks" ] || [ -L "$FM_CS_worktree/.git/hooks" ]; then
  die "the task clone's .git/config and .git/hooks must be a regular file and a directory, which the container mounts read-only"
fi
[ -f "$FM_CS_status" ] || die "the status log $FM_CS_status is missing"

PRIVATE=
PROXY_PID=
RELAY_PID=
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  [ -z "$RELAY_PID" ] || kill "$RELAY_PID" 2>/dev/null || true
  [ -z "$PROXY_PID" ] || kill "$PROXY_PID" 2>/dev/null || true
  [ -z "$PRIVATE" ] || rm -rf -- "$PRIVATE"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# A Unix socket path is limited to about 104 bytes, so the private directory
# sits under TMPDIR only while that keeps the socket path short, else /tmp.
private_base=${TMPDIR:-/tmp}
private_base=${private_base%/}
[ "${#private_base}" -le 60 ] || private_base=/tmp
PRIVATE=$(umask 077 && mktemp -d "$private_base/fmc.XXXXXXXX") || die "could not create a private directory for the launch"
ENVFILE="$PRIVATE/env"
SOCK="$PRIVATE/proxy.sock"
(umask 077 && printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$FM_CONTAINER_TOKEN" >"$ENVFILE") || die "could not write the private env file"
unset FM_CONTAINER_TOKEN

proxy_args=(--socket "$SOCK")
[ -z "$FM_CS_proxy_log" ] || proxy_args+=(--log "$FM_CS_proxy_log")
for host in $FM_CONTAINER_ALLOWED_HOSTS; do
  proxy_args+=(--allow "$host")
done
(umask 077 && exec node "$SCRIPT_DIR/fm-container-proxy.mjs" "${proxy_args[@]}" </dev/null) &
PROXY_PID=$!
for _ in $(seq 1 50); do
  [ -S "$SOCK" ] && break
  kill -0 "$PROXY_PID" 2>/dev/null || break
  sleep 0.1
done
[ -S "$SOCK" ] || die "the egress proxy did not start; refusing to launch the container without it"

# Events from an earlier incarnation of this task would replay under the new
# gen, so the relay starts from an empty file. Truncating keeps the inode the
# container's bind mount holds.
: >"$FM_CS_events" || die "could not reset the hook event file $FM_CS_events"
RELAY_STOP="$PRIVATE/relay-stop"
relay_loop() {
  local buf='' chunk stopping=0
  exec 3<"$FM_CS_events" || return 1
  while :; do
    while IFS= read -r chunk <&3; do
      fm_container_relay_event "$buf$chunk" "$FM_CS_state" "$FM_CS_id" "$FM_CS_busy_gen" "$FM_CS_turnend"
      buf=
    done
    buf=$buf$chunk
    [ "$stopping" = 0 ] || break
    if [ -e "$RELAY_STOP" ]; then
      stopping=1
      continue
    fi
    sleep 0.2
  done
  exec 3<&-
}
relay_loop </dev/null &
RELAY_PID=$!

# A container left stopped by a crashed earlier run would hold the name.
podman rm --ignore "$FM_CS_name" >/dev/null 2>&1 || true
fm_container_podman_args "$SOCK" "$ENVFILE" "${TERM:-xterm-256color}" || exit 1
podman "${FM_CONTAINER_ARGS[@]}" "$@"
status=$?

: >"$RELAY_STOP"
wait "$RELAY_PID" 2>/dev/null || true
RELAY_PID=
fm_container_relay_event 'idle session-end' "$FM_CS_state" "$FM_CS_id" "$FM_CS_busy_gen" "$FM_CS_turnend"
exit "$status"
