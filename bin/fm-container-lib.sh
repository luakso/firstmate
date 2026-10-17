#!/usr/bin/env bash
# fm-container-lib.sh - the "container" runtime level for Claude ship and scout
# workers (docs/container-runtime.md owns the operator contract and
# docs/configuration.md "Container runtime" the config schema).
#
# A project opts in with config/container/<project>; every other project keeps
# its ordinary launch. In the container level the worker pane runs
# bin/fm-container-run.sh, which runs `podman run --rm -it` with the argv this
# library builds instead of running claude on the host. Sourced by
# bin/fm-spawn.sh, bin/fm-container-run.sh, and bin/fm-teardown.sh; it has no
# side effects on source.
#
# WHAT EXISTS INSIDE. Nothing from the host is mounted except this exact list,
# every entry at the same path it has on the host so the brief's paths, git's
# alternates, and Claude's --add-dir grants mean the same thing inside:
#   - the task's own clone, read-write, except its .git/config and .git/hooks,
#     which are mounted read-only over it: Firstmate's own git commands read
#     the clone on the host (teardown's landed-work checks, the local merge),
#     and a worker that could set core.fsmonitor or plant a hook there would
#     have them run its code outside the container, which is the same reason the
#     Claude sandbox denies writes to both;
#   - the project clone's git object store, read-only, which the clone borrows
#     through objects/info/alternates (bin/fm-task-clone-lib.sh);
#   - the task's container home, read-write: HOME and CLAUDE_CONFIG_DIR, so the
#     worker's transcripts and Claude state stay in the task area and never in
#     the captain's ~/.claude;
#   - the task's hook-event file, read-write (see THE HOOK RELAY);
#   - the task's Firstmate channels: state/<id>.status and state/<id>.inbox
#     read-write, data/<id> read-write, the one operational-inbox record that
#     carries this launch's brief read-only, and the code root's .agents/skills
#     read-only, which the launch brief names;
#   - the per-launch proxy socket, at /run/fm-proxy.sock;
#   - the project's named cargo cache volume, at /cargo (CARGO_HOME).
# The rootfs is read-only with a private /tmp, every capability is dropped,
# no-new-privileges is set, pids and memory are limited, and the container has
# no network namespace beyond loopback (--network none). No Docker or Podman
# socket is ever mounted.
#
# NETWORK. --network none leaves the container nothing but loopback, so it fails
# closed: the only way out is the per-launch Unix socket of
# bin/fm-container-proxy.mjs, a host-side CONNECT proxy that the runner starts
# and that tunnels exactly FM_CONTAINER_ALLOWED_HOSTS and refuses everything
# else. Inside, socat bridges 127.0.0.1:3128 to that socket and HTTPS_PROXY
# points every client at it. A host-side proxy was chosen over an in-namespace
# firewall (the shape of Anthropic's reference devcontainer) because a firewall
# needs NET_ADMIN inside the container, contradicting --cap-drop all, and
# filters IP addresses that CDN-fronted hosts such as static.crates.io rotate;
# the proxy decides on the requested host name and resolves it on the host.
#
# THE HOOK RELAY. Claude's lifecycle hooks run inside the container, so they
# cannot run bin/fm-busy-event.sh against this home's state/ directory, which
# is never mounted. A container launch's hooks instead append one fixed event
# line to the task's event file, and the runner, a host process outside the
# container, applies each recognised line to the busy-state contract and the
# turn-ended notification exactly as the host hooks would
# (fm_container_relay_event). Unrecognised lines are ignored.
#
# LOGIN. Claude inside the container authenticates with a long-lived token the
# captain creates with `claude setup-token` and stores in
# config/container-claude-token, mode 0600. The runner reads it at launch and
# hands it to podman through a 0600 env file in a private directory it removes
# on exit, so the token is never on a command line or in the task records.

FM_CONTAINER_LIB_DIR=$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; CDPATH='' cd "${d:-/}" && pwd -P)

# shellcheck disable=SC2034  # read by bin/fm-container-run.sh
# The exact egress allow-list. api.anthropic.com is the only host Claude Code
# needs with a CLAUDE_CODE_OAUTH_TOKEN login once nonessential traffic is
# disabled; index.crates.io serves the sparse index and static.crates.io the
# crate downloads.
FM_CONTAINER_ALLOWED_HOSTS="api.anthropic.com:443 index.crates.io:443 static.crates.io:443"
FM_CONTAINER_DEFAULT_PIDS_LIMIT=2048
FM_CONTAINER_DEFAULT_MEMORY=8g
FM_CONTAINER_PROXY_PORT=3128
FM_CONTAINER_PROXY_SOCKET=/run/fm-proxy.sock
FM_CONTAINER_CARGO_HOME=/cargo

# The project's opt-in file. Prints its path.
fm_container_config_path() {  # <config-dir> <project-name>
  printf '%s/container/%s\n' "$1" "$2"
}

# Parse config/container/<project>. Returns 0 and sets FM_CONTAINER_IMAGE,
# FM_CONTAINER_PIDS_LIMIT, and FM_CONTAINER_MEMORY when the project opts in;
# returns 1 when it does not (no file); returns 2 after printing an error when
# the file exists but is unreadable or malformed, so a caller refuses rather
# than launching the project outside the container it selected.
# shellcheck disable=SC2034  # the FM_CONTAINER_* results are read by callers
fm_container_project_config() {  # <config-dir> <project-name>
  local file line key value lineno=0 image='' pids='' memory=''
  FM_CONTAINER_IMAGE=
  FM_CONTAINER_PIDS_LIMIT=
  FM_CONTAINER_MEMORY=
  case "$2" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  file=$(fm_container_config_path "$1" "$2")
  [ -e "$file" ] || [ -L "$file" ] || return 1
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    echo "error: $file must be a readable regular file of key=value lines (image, pids-limit, memory)" >&2
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    case "$line" in
      ''|'#'*) continue ;;
      *=*) ;;
      *)
        echo "error: $file line $lineno is not key=value: $line" >&2
        return 2
        ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      image)
        case "$value" in
          ''|*[!A-Za-z0-9._/:@-]*)
            echo "error: $file line $lineno: image must be a podman image reference such as localhost/tokenbook-dev:latest" >&2
            return 2
            ;;
        esac
        image=$value
        ;;
      pids-limit)
        case "$value" in
          ''|*[!0-9]*|0*)
            echo "error: $file line $lineno: pids-limit must be a positive integer" >&2
            return 2
            ;;
        esac
        pids=$value
        ;;
      memory)
        case "$value" in
          [1-9]*) ;;
          *)
            echo "error: $file line $lineno: memory must be a size such as 8g or 4096m" >&2
            return 2
            ;;
        esac
        case "${value%[bkmgBKMG]}" in
          *[!0-9]*)
            echo "error: $file line $lineno: memory must be a size such as 8g or 4096m" >&2
            return 2
            ;;
        esac
        memory=$value
        ;;
      *)
        echo "error: $file line $lineno: unknown key '$key'; accepted keys are image, pids-limit, memory" >&2
        return 2
        ;;
    esac
  done <"$file"
  if [ -z "$image" ]; then
    echo "error: $file names no image; add a line such as image=localhost/tokenbook-dev:latest" >&2
    return 2
  fi
  FM_CONTAINER_IMAGE=$image
  FM_CONTAINER_PIDS_LIMIT=${pids:-$FM_CONTAINER_DEFAULT_PIDS_LIMIT}
  FM_CONTAINER_MEMORY=${memory:-$FM_CONTAINER_DEFAULT_MEMORY}
  return 0
}

# The captain's Claude login for container workers.
fm_container_token_path() {  # <config-dir>
  printf '%s/container-claude-token\n' "$1"
}

# Refuse a token file that is missing, not a regular file this user owns,
# readable or writable by group or others, or not exactly one token. On success
# sets FM_CONTAINER_TOKEN; it is never printed.
# shellcheck disable=SC2034  # FM_CONTAINER_TOKEN is read by callers
fm_container_token_read() {  # <token-file>
  local file=$1 mode token extra
  FM_CONTAINER_TOKEN=
  if [ ! -f "$file" ] || [ -L "$file" ] || [ ! -r "$file" ]; then
    echo "error: $file must be a readable regular file holding the token from \`claude setup-token\`; create it with mode 0600" >&2
    return 1
  fi
  [ -O "$file" ] || {
    echo "error: $file is not owned by this user" >&2
    return 1
  }
  mode=$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file" 2>/dev/null) || mode=
  case "$mode" in
    600|400) ;;
    *)
      echo "error: $file has mode ${mode:-unknown}; a Claude login must be readable by its owner only, so chmod 600 it" >&2
      return 1
      ;;
  esac
  {
    IFS= read -r token || [ -n "$token" ]
    extra=$(cat)
  } <"$file"
  token=${token%$'\r'}
  case "$token" in
    ''|*[!A-Za-z0-9._~+/=-]*)
      echo "error: $file must hold exactly one token on its first line, as \`claude setup-token\` prints it" >&2
      return 1
      ;;
  esac
  if [ -n "$(printf '%s' "$extra" | tr -d '[:space:]')" ]; then
    echo "error: $file must hold exactly one token on its first line, as \`claude setup-token\` prints it" >&2
    return 1
  fi
  FM_CONTAINER_TOKEN=$token
}

# A short stable hash of a home path, for container names and labels.
fm_container_home_hash() {  # <home>
  local root hash
  root=$(cd "$1" 2>/dev/null && pwd -P) || root=$1
  if command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | sha256sum | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | shasum -a 256 | awk '{print $1}')
  else
    return 1
  fi
  printf '%s\n' "${hash:0:12}"
}

# The task's one container name. Podman refuses a second container under a
# name already in use, so two launches of one task can never run at once.
fm_container_name() {  # <task-id> <home>
  local hash
  hash=$(fm_container_home_hash "$2") || return 1
  printf 'fm-%s-%s\n' "$1" "$hash"
}

fm_container_cargo_volume() {  # <project-name>
  printf 'fm-cargo-%s\n' "$1"
}

# The host-only directory beside a task clone that holds the container launch's
# spec, event file, proxy log, and the home mounted inside. It lives in the
# clone's task directory, so the task-clone teardown removes it with the clone.
fm_container_dir() {  # <worktree>
  printf '%s/container\n' "${1%/*}"
}

# Write the per-launch spec the runner reads: one key=value per line. Values
# never hold a newline; a path that podman's --mount syntax cannot carry (a
# comma, or a colon) is refused here, before any launch.
fm_container_spec_write() {  # <spec-file> <key=value>...
  local file=$1 tmp entry
  shift
  for entry in "$@"; do
    case "$entry" in
      *$'\n'*) echo "error: container spec value holds a newline: ${entry%%=*}" >&2; return 1 ;;
      *=*) ;;
      *) echo "error: container spec entry is not key=value: $entry" >&2; return 1 ;;
    esac
  done
  tmp="$file.tmp.$$"
  (umask 077 && printf '%s\n' "$@" >"$tmp") || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file"
}

# Load a spec into FM_CS_<key> variables. Refuses an unknown key, so a spec
# written by a newer Firstmate cannot be half-read, and a missing required one.
# shellcheck disable=SC2034  # the FM_CS_* fields are read by callers
fm_container_spec_load() {  # <spec-file>
  local file=$1 line key value
  [ -f "$file" ] && [ -r "$file" ] || { echo "error: container spec $file is not readable" >&2; return 1; }
  FM_CS_id='' FM_CS_name='' FM_CS_image='' FM_CS_pids_limit='' FM_CS_memory='' FM_CS_cargo_volume=''
  FM_CS_worktree='' FM_CS_objects='' FM_CS_home='' FM_CS_events='' FM_CS_status='' FM_CS_inbox=''
  FM_CS_data='' FM_CS_record='' FM_CS_skills='' FM_CS_token='' FM_CS_state='' FM_CS_busy_gen=''
  FM_CS_turnend='' FM_CS_proxy_log='' FM_CS_home_hash='' FM_CS_git_name='' FM_CS_git_email=''
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      id) FM_CS_id=$value ;;
      name) FM_CS_name=$value ;;
      image) FM_CS_image=$value ;;
      pids_limit) FM_CS_pids_limit=$value ;;
      memory) FM_CS_memory=$value ;;
      cargo_volume) FM_CS_cargo_volume=$value ;;
      worktree) FM_CS_worktree=$value ;;
      objects) FM_CS_objects=$value ;;
      home) FM_CS_home=$value ;;
      events) FM_CS_events=$value ;;
      status) FM_CS_status=$value ;;
      inbox) FM_CS_inbox=$value ;;
      data) FM_CS_data=$value ;;
      record) FM_CS_record=$value ;;
      skills) FM_CS_skills=$value ;;
      token) FM_CS_token=$value ;;
      state) FM_CS_state=$value ;;
      busy_gen) FM_CS_busy_gen=$value ;;
      turnend) FM_CS_turnend=$value ;;
      proxy_log) FM_CS_proxy_log=$value ;;
      home_hash) FM_CS_home_hash=$value ;;
      git_name) FM_CS_git_name=$value ;;
      git_email) FM_CS_git_email=$value ;;
      *) echo "error: container spec $file has unknown key '$key'" >&2; return 1 ;;
    esac
  done <"$file"
  for key in id name image pids_limit memory cargo_volume worktree home events status inbox data token state; do
    value=FM_CS_$key
    [ -n "${!value}" ] || { echo "error: container spec $file has no $key" >&2; return 1; }
  done
}

fm_container_mount_path_ok() {  # <path>
  case "$1" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *,*|*:*|*$'\n'*) return 1 ;;
  esac
  return 0
}

# Build the complete `podman run` argv for a loaded spec into FM_CONTAINER_ARGS,
# ending with the image and the in-container entry prefix; the caller appends
# the command to run. <proxy-socket> and <env-file> are the runner's private
# per-launch files. This function is the single owner of every flag, mount,
# and environment value a container launch carries.
fm_container_podman_args() {  # <proxy-socket> <env-file> [<term>]
  local sock=$1 envfile=$2 term=${3:-xterm-256color} path proxy
  local -a mounts=()
  proxy="http://127.0.0.1:$FM_CONTAINER_PROXY_PORT"
  for path in "$FM_CS_worktree" "$FM_CS_objects" "$FM_CS_home" "$FM_CS_events" "$FM_CS_status" \
    "$FM_CS_inbox" "$FM_CS_data" "$FM_CS_record" "$FM_CS_skills" "$sock"; do
    [ -n "$path" ] || continue
    fm_container_mount_path_ok "$path" || {
      echo "error: container mount path '$path' must be absolute and free of commas and colons" >&2
      return 1
    }
  done
  case "$FM_CS_cargo_volume" in
    ''|*[!A-Za-z0-9_.-]*) echo "error: container cargo volume name '$FM_CS_cargo_volume' is invalid" >&2; return 1 ;;
  esac
  mounts+=(--mount "type=bind,src=$FM_CS_worktree,dst=$FM_CS_worktree")
  mounts+=(--mount "type=bind,src=$FM_CS_worktree/.git/config,dst=$FM_CS_worktree/.git/config,ro=true")
  mounts+=(--mount "type=bind,src=$FM_CS_worktree/.git/hooks,dst=$FM_CS_worktree/.git/hooks,ro=true")
  [ -z "$FM_CS_objects" ] || mounts+=(--mount "type=bind,src=$FM_CS_objects,dst=$FM_CS_objects,ro=true")
  mounts+=(--mount "type=bind,src=$FM_CS_home,dst=$FM_CS_home")
  mounts+=(--mount "type=bind,src=$FM_CS_events,dst=$FM_CS_events")
  mounts+=(--mount "type=bind,src=$FM_CS_status,dst=$FM_CS_status")
  mounts+=(--mount "type=bind,src=$FM_CS_inbox,dst=$FM_CS_inbox")
  mounts+=(--mount "type=bind,src=$FM_CS_data,dst=$FM_CS_data")
  [ -z "$FM_CS_record" ] || mounts+=(--mount "type=bind,src=$FM_CS_record,dst=$FM_CS_record,ro=true")
  [ -z "$FM_CS_skills" ] || mounts+=(--mount "type=bind,src=$FM_CS_skills,dst=$FM_CS_skills,ro=true")
  mounts+=(--mount "type=bind,src=$sock,dst=$FM_CONTAINER_PROXY_SOCKET")
  mounts+=(--mount "type=volume,src=$FM_CS_cargo_volume,dst=$FM_CONTAINER_CARGO_HOME")
  FM_CONTAINER_ARGS=(
    run --rm -it
    --name "$FM_CS_name"
    --label "io.firstmate.task=$FM_CS_id"
    --label "io.firstmate.home=$FM_CS_home_hash"
    --userns=keep-id
    --read-only
    --tmpfs /tmp
    --cap-drop all
    --security-opt no-new-privileges
    --pids-limit "$FM_CS_pids_limit"
    --memory "$FM_CS_memory"
    --network none
    --workdir "$FM_CS_worktree"
    --env-file "$envfile"
    -e "HOME=$FM_CS_home"
    -e "CLAUDE_CONFIG_DIR=$FM_CS_home/.claude"
    -e "CARGO_HOME=$FM_CONTAINER_CARGO_HOME"
    -e "HTTPS_PROXY=$proxy" -e "https_proxy=$proxy"
    -e "HTTP_PROXY=$proxy" -e "http_proxy=$proxy"
    -e "NO_PROXY=" -e "no_proxy="
    -e "DISABLE_AUTOUPDATER=1"
    -e "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
    -e "ENABLE_CLAUDEAI_MCP_SERVERS=false"
    -e "COMPACT_ADVISER_DISABLE=1"
    -e "FM_TASK_ID=$FM_CS_id"
    -e "TERM=$term"
    -e "LANG=C.UTF-8"
  )
  if [ -n "$FM_CS_git_name" ]; then
    FM_CONTAINER_ARGS+=(-e "GIT_AUTHOR_NAME=$FM_CS_git_name" -e "GIT_COMMITTER_NAME=$FM_CS_git_name")
  fi
  if [ -n "$FM_CS_git_email" ]; then
    FM_CONTAINER_ARGS+=(-e "GIT_AUTHOR_EMAIL=$FM_CS_git_email" -e "GIT_COMMITTER_EMAIL=$FM_CS_git_email")
  fi
  FM_CONTAINER_ARGS+=("${mounts[@]}")
  # tini is PID 1 so signals reach claude and the bridge is reaped; the bridge
  # gives every proxy-aware client a TCP proxy on loopback.
  # shellcheck disable=SC2016  # "$@" expands inside the container's sh
  FM_CONTAINER_ARGS+=(
    --entrypoint /usr/bin/tini
    "$FM_CS_image"
    -- /bin/sh -c "socat TCP-LISTEN:$FM_CONTAINER_PROXY_PORT,bind=127.0.0.1,reuseaddr,fork UNIX-CONNECT:$FM_CONTAINER_PROXY_SOCKET & exec \"\$@\"" fm-container-entry
  )
}

# The Claude hook command a container launch writes for one lifecycle event:
# it appends the fixed event line to the task's event file, which the runner
# relays on the host.
fm_container_hook_command() {  # <events-file> <state> <event>
  local q
  q=$(printf '%s' "$1" | sed "s/'/'\\\\''/g")
  printf "printf '%%s\\\\n' '%s %s' >> '%s' 2>/dev/null || true" "$2" "$3" "$q"
}

# Apply one relayed event line to the host's busy-state contract and turn-end
# notification, with the incarnation gen the host minted. Only the four lines
# a container launch's hooks write are recognised; anything else is ignored.
fm_container_relay_event() {  # <line> <state-dir> <task-id> <gen> <turnend>
  local line=$1 state=$2 id=$3 gen=$4 turnend=$5 to event
  case "$line" in
    'busy user-prompt-submit') to=busy event=user-prompt-submit ;;
    'idle stop') to=idle event=stop ;;
    'idle stop-failure') to=idle event=stop-failure ;;
    'idle session-end') to=idle event=session-end ;;
    *) return 0 ;;
  esac
  [ "$event" != stop ] || touch "$turnend" 2>/dev/null || true
  [ -n "$gen" ] || return 0
  "$FM_CONTAINER_LIB_DIR/fm-busy-event.sh" apply "$state" "$id" "$to" --gen "$gen" \
    --source claude-hook --event "$event" >/dev/null 2>&1 || true
}

# Remove a task's container, running or not. Teardown calls this before it
# reaps the task's processes and removes its clone; the shared cargo volume is
# left in place. A host without podman can hold no container.
fm_container_remove() {  # <container-name>
  local name=$1
  case "$name" in
    ''|*[!A-Za-z0-9_.-]*) echo "error: '$name' is not a container name this runtime made" >&2; return 1 ;;
  esac
  command -v podman >/dev/null 2>&1 || return 0
  podman rm --force --ignore --time 10 "$name" >/dev/null 2>&1 || {
    echo "error: podman could not remove container $name" >&2
    return 1
  }
}
