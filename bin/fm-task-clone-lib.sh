#!/usr/bin/env bash
# fm-task-clone-lib.sh - the per-task clone a Claude crewmate or scout works in
# while config/claude-sandbox is on (docs/configuration.md "Claude sandbox").
#
# WHY A CLONE. Claude Code's sandbox lets Bash write the launch directory, and
# when that directory is a linked worktree it also grants the repository's
# shared git directory (verified on 2.1.283: the grant follows a `.git` file's
# gitdir pointer into <common>/worktrees/<name> and back to <common>), leaving
# every branch ref, the object store, and other tasks' worktree entries of the
# project clone writable. A standalone clone keeps its own `.git` inside the
# launch directory, so the fence covers exactly that one repository: the
# project clone's git data and every other task's copy stay read-only.
#
# LAYOUT. <root>/<task-id>/<repo-leaf>, where <root> is $FM_TASK_CLONE_ROOT or
# $HOME/.firstmate/clones/<home-tag> (bin/fm-backend-hometag-lib.sh), so two
# Firstmate homes with the same task id never share a path. The root sits outside
# every Firstmate home, because Claude Code loads each CLAUDE.md from the launch
# directory up to the filesystem root and a clone under a home would load that
# home's supervisor contract. The clone is `git clone --shared` from the project
# clone: it reads the project's objects through objects/info/alternates and
# writes only its own, so it costs a checkout rather than a copy of history. The
# clone's own remote pointing back at the project clone is removed, so a routine
# `git push origin` can never write the project clone, and the clone starts on a
# detached HEAD with no local branches, so every local branch in it is the
# worker's own. What a linked worktree would have shared with the project clone
# and a worker relies on is carried in: the project's remotes (the no-mistakes
# gate excepted, since each copy registers its own), its user.* identity and
# core.hooksPath, its installed hooks, and info/exclude. Nothing else from the
# project's .git/config is.
#
# OWNERSHIP. The task directory holds .fm-task-clone (task id, then home), a
# sibling of the clone rather than a file inside it, so it never dirties the copy
# whose landed work teardown inspects, and a sandboxed worker cannot write it.
# fm_task_clone_owned is the only proof teardown accepts before removing a task
# directory: the recorded worktree must sit directly inside a task directory
# whose marker names this task and home, and must be a standalone repository.
#
# Objects borrowed through alternates stay valid because the project clone only
# fast-forwards its default branch (bin/fm-fleet-sync.sh) and a clone borrows
# nothing else: its remote-tracking refs are replaced before launch.

FM_TASK_CLONE_MARKER=.fm-task-clone

FM_TASK_CLONE_LIB_DIR=$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; CDPATH='' cd "${d:-/}" && pwd -P)
# shellcheck source=bin/fm-path-lib.sh
. "$FM_TASK_CLONE_LIB_DIR/fm-path-lib.sh"

# Print the clone root for this home. FM_HOME and FM_ROOT must be resolved. Only
# creation needs the home tag, so its library loads here rather than with this
# one.
fm_task_clone_root() {
  if [ -n "${FM_TASK_CLONE_ROOT:-}" ]; then
    case "$FM_TASK_CLONE_ROOT" in
      /*) printf '%s\n' "$FM_TASK_CLONE_ROOT" ;;
      *) echo "error: FM_TASK_CLONE_ROOT '$FM_TASK_CLONE_ROOT' must be an absolute path" >&2; return 1 ;;
    esac
    return 0
  fi
  [ -n "${HOME:-}" ] || { echo "error: HOME is not set, so the task clone root cannot be resolved" >&2; return 1; }
  if ! declare -F fm_backend_hometag >/dev/null; then
    # shellcheck source=bin/fm-backend-hometag-lib.sh
    . "$FM_TASK_CLONE_LIB_DIR/fm-backend-hometag-lib.sh" || return 1
  fi
  printf '%s/.firstmate/clones/%s\n' "$HOME" "$(fm_backend_hometag)"
}

# Carry <project>'s remotes (except the no-mistakes gate), user.* identity,
# core.hooksPath, installed hooks, and info/exclude into <clone>, config values
# and multi-valued keys verbatim.
fm_task_clone_copy_settings() {  # <project> <clone>
  local project=$1 clone=$2 entry key value common hook
  while IFS= read -r -d '' entry; do
    key=${entry%%$'\n'*}
    if [ "$key" = "$entry" ]; then
      value=true
    else
      value=${entry#*$'\n'}
    fi
    case "$key" in
      remote.no-mistakes.*) continue ;;
    esac
    git -C "$clone" config --add "$key" "$value" || return 1
  done < <(git -C "$project" config --local -z --get-regexp '^(remote\..*|user\..*|core\.hookspath)$' 2>/dev/null || true)
  common=$(git -C "$project" rev-parse --path-format=absolute --git-common-dir) || return 1
  if ! git -C "$project" config --local --get core.hooksPath >/dev/null 2>&1 && [ -d "$common/hooks" ]; then
    for hook in "$common/hooks"/*; do
      [ -f "$hook" ] || continue
      case "$hook" in *.sample) continue ;; esac
      cp -p -- "$hook" "$clone/.git/hooks/" || return 1
    done
  fi
  if [ -f "$common/info/exclude" ]; then
    mkdir -p "$clone/.git/info" && cp -- "$common/info/exclude" "$clone/.git/info/exclude" || return 1
  fi
}

# Create the clone for <task-id> from <project> and print its path. Refuses an
# existing task directory, which may hold an earlier incarnation's work. A
# failure after the task directory exists removes only what this call created.
fm_task_clone_create() {  # <project> <task-id> <home>
  local project=$1 id=$2 home=$3 root project_real home_real leaf dir clone ref
  project_real=$(cd "$project" 2>/dev/null && pwd -P) || {
    echo "error: project '$project' is not an accessible directory" >&2
    return 1
  }
  home_real=$(cd "$home" 2>/dev/null && pwd -P) || {
    echo "error: Firstmate home '$home' is not an accessible directory" >&2
    return 1
  }
  root=$(fm_task_clone_root) || return 1
  mkdir -p "$root" || {
    echo "error: could not create the task clone root $root" >&2
    return 1
  }
  root=$(cd "$root" && pwd -P) || return 1
  case "$root/" in
    "$home_real"/* | "$project_real"/*)
      echo "error: task clone root $root lies inside '$home_real' or '$project_real'; a clone there would load that tree's instructions and share its checkout" >&2
      return 1
      ;;
  esac
  fm_basename_to leaf "$project_real"
  dir="$root/$id"
  clone="$dir/$leaf"
  if ! mkdir "$dir" 2>/dev/null; then
    echo "error: task clone directory $dir already exists and may hold an earlier copy of task $id's work; inspect it and remove it by hand before respawning" >&2
    return 1
  fi
  if ! printf '%s\n%s\n' "$id" "$home_real" >"$dir/$FM_TASK_CLONE_MARKER" ||
    ! git clone --quiet --shared -- "$project_real" "$clone" ||
    ! git -C "$clone" checkout --quiet --detach ||
    ! git -C "$clone" remote remove origin; then
    echo "error: could not clone $project_real into $clone" >&2
    rm -rf -- "$dir"
    return 1
  fi
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    git -C "$clone" update-ref -d "$ref" || {
      echo "error: could not clear local branch $ref from $clone" >&2
      rm -rf -- "$dir"
      return 1
    }
  done < <(git -C "$clone" for-each-ref --format='%(refname)' refs/heads/)
  if ! fm_task_clone_copy_settings "$project_real" "$clone"; then
    echo "error: could not carry $project_real's remotes, identity, and hooks into $clone" >&2
    rm -rf -- "$dir"
    return 1
  fi
  printf '%s\n' "$clone"
}

# True when <worktree> has a task clone's shape: a standalone repository whose
# git directory is its own .git, beside a task-clone marker this user owns.
# Readers that hold no task identity use this; removal uses fm_task_clone_owned.
# With `container`, for a contained task's clone (see CONTAINED CLONES below),
# the git directory's shape is read from its files - a real .git directory
# holding a regular HEAD file and no commondir - and git never runs in it.
# FM_TASK_CLONE_DIR is left naming the task directory.
FM_TASK_CLONE_DIR=
fm_task_clone_shaped() {  # <worktree> [container]
  local wt_real dir marker git_dir common
  FM_TASK_CLONE_DIR=
  wt_real=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  fm_dirname_to dir "$wt_real"
  marker="$dir/$FM_TASK_CLONE_MARKER"
  [ -f "$marker" ] && [ ! -L "$marker" ] && [ -O "$marker" ] || return 1
  [ -d "$wt_real/.git" ] && [ ! -L "$wt_real/.git" ] || return 1
  if [ "${2:-}" = container ]; then
    [ -f "$wt_real/.git/HEAD" ] && [ ! -L "$wt_real/.git/HEAD" ] || return 1
    [ ! -e "$wt_real/.git/commondir" ] && [ ! -L "$wt_real/.git/commondir" ] || return 1
  else
    git_dir=$(git -C "$wt_real" rev-parse --absolute-git-dir 2>/dev/null) || return 1
    common=$(git -C "$wt_real" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    git_dir=$(cd "$git_dir" 2>/dev/null && pwd -P) || return 1
    common=$(cd "$common" 2>/dev/null && pwd -P) || return 1
    [ "$git_dir" = "$wt_real/.git" ] && [ "$common" = "$git_dir" ] || return 1
  fi
  FM_TASK_CLONE_DIR=$dir
}

# True when <worktree> is the clone fm_task_clone_create made for <task-id> in
# <home>: task-clone shaped, with a marker naming exactly that task and home.
fm_task_clone_owned() {  # <worktree> <task-id> <home> [container]
  local home_real want
  home_real=$(cd "$3" 2>/dev/null && pwd -P) || return 1
  fm_task_clone_shaped "$1" "${4:-}" || return 1
  want=$(printf '%s\n%s' "$2" "$home_real")
  [ "$(cat "$FM_TASK_CLONE_DIR/$FM_TASK_CLONE_MARKER" 2>/dev/null)" = "$want" ] || {
    FM_TASK_CLONE_DIR=
    return 1
  }
}

# Remove the task directory holding <task-id>'s clone, after proving ownership.
# Go module trees and git objects can be read-only, so write permission is
# restored first.
fm_task_clone_remove() {  # <worktree> <task-id> <home>
  fm_task_clone_owned "$1" "$2" "$3" || {
    echo "error: $1 is not a task clone this home made for $2; refusing to remove it" >&2
    return 1
  }
  chmod -R u+w -- "$FM_TASK_CLONE_DIR" 2>/dev/null || true
  rm -rf -- "$FM_TASK_CLONE_DIR"
  [ ! -e "$FM_TASK_CLONE_DIR" ] || {
    echo "error: could not remove task clone directory $FM_TASK_CLONE_DIR" >&2
    return 1
  }
}

# CONTAINED CLONES. A contained worker (bin/fm-container-lib.sh) can rewrite
# anything under its clone's .git, even replace the directory past its
# read-only config and hooks binds, so a host tool never runs git in that
# repository: no config, gitattributes driver, hook, or fsmonitor of the clone's
# is ever honoured. It reads the clone's HEAD and refs as plain data, and runs
# git in a private snapshot (fm_task_clone_snapshot) whose config it writes.
# These helpers bound their reads with fm_run_timed, so their callers source
# bin/fm-timeout-lib.sh.

# Print the first <max-bytes> of a worker-written file, refusing anything but
# a regular file.
fm_task_clone_plain_file() {  # <path> <max-bytes>
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  fm_run_timed 10 head -c "$2" -- "$1"
}

# Print the full SHA <git-dir> holds for <ref> (refs/heads/<name>), read as
# data from its loose ref file or, failing that, its packed-refs.
fm_task_clone_ref_data() {  # <git-dir> <ref>
  local loose="$1/$2" sha LC_ALL=C
  if [ -e "$loose" ] || [ -L "$loose" ]; then
    sha=$(fm_task_clone_plain_file "$loose" 128) || return 1
  elif [ -f "$1/packed-refs" ] && [ ! -L "$1/packed-refs" ]; then
    # shellcheck disable=SC2016  # awk, not the shell, expands $1 and $2
    sha=$(fm_run_timed 30 awk -v ref="$2" '$2 == ref && NF == 2 { print $1; exit }' "$1/packed-refs") || return 1
  else
    return 1
  fi
  [[ "$sha" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$sha"
}

# Print what <git-dir>/HEAD names, read as data: refs/heads/<branch>, or the
# full SHA of a detached HEAD.
fm_task_clone_head_data() {  # <git-dir>
  local head LC_ALL=C
  head=$(fm_task_clone_plain_file "$1/HEAD" 1024) || return 1
  case "$head" in
    'ref: refs/heads/'?*) printf '%s\n' "${head#ref: }" ;;
    *)
      [[ "$head" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] || return 1
      printf '%s\n' "$head" ;;
  esac
}

# Print the full SHA <git-dir>'s HEAD resolves to, read as data.
fm_task_clone_head_sha() {  # <git-dir>
  local head
  head=$(fm_task_clone_head_data "$1") || return 1
  case "$head" in
    refs/heads/*) fm_task_clone_ref_data "$1" "$head" ;;
    *) printf '%s\n' "$head" ;;
  esac
}

# git in a host-owned project clone, with none of the caller's repository
# environment and no global or system config.
fm_task_clone_project_git() {  # <project-clone> <git-args...>
  local project=$1
  shift
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_OPTIONAL_LOCKS=0 \
    git -C "$project" -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"
}

# Print the resolved object store of <project-clone>.
fm_task_clone_project_objects() {  # <project-clone>
  local common
  common=$(fm_task_clone_project_git "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  (cd "$common/objects" 2>/dev/null && pwd -P)
}

# Build at <private-git-dir> the bare repository a host tool runs git in instead
# of <clone-git-dir>: a copy of the clone's own object store without
# objects/info, refused when it holds anything but regular files and
# directories, borrowing only <project-clone>'s object store, with config
# written here - hooks, fsmonitor, the untracked cache, commit-graphs,
# multi-pack-indexes, pack bitmaps, automatic maintenance, and submodule
# recursion off, and no filter, driver, or helper defined. Its HEAD is unborn
# and it has no refs; the caller writes what it read as data. Sets
# FM_TASK_CLONE_GIT_ENV, the env(1) prefix that runs a command in it with none
# of the caller's repository environment; a read adds GIT_CONFIG_GLOBAL=/dev/null
# GIT_CONFIG_NOSYSTEM=1, and only a fetch or push, for its credentials, reads
# the host's own config. 1 with FM_TASK_CLONE_ERROR naming why.
FM_TASK_CLONE_ERROR=
FM_TASK_CLONE_GIT_ENV=()
# shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
fm_task_clone_snapshot() {  # <clone-git-dir> <private-git-dir> <project-clone>
  local src=$1 priv=$2 project=$3 objects format odd
  FM_TASK_CLONE_ERROR=
  FM_TASK_CLONE_GIT_ENV=(env -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR
    GIT_DIR="$priv" GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0)
  if ! objects=$(fm_task_clone_project_objects "$project"); then
    FM_TASK_CLONE_ERROR="the project clone's object store is unreadable"
    return 1
  fi
  if ! format=$(fm_task_clone_project_git "$project" rev-parse --show-object-format 2>/dev/null); then
    FM_TASK_CLONE_ERROR="the project clone's object format is unreadable"
    return 1
  fi
  if [ ! -d "$src/objects" ] || [ -L "$src/objects" ]; then
    FM_TASK_CLONE_ERROR="the clone's object store is not a directory"
    return 1
  fi
  if ! mkdir -p "$priv/refs" "$priv/info"; then
    FM_TASK_CLONE_ERROR="could not create the private repository"
    return 1
  fi
  if ! fm_run_timed 300 cp -RP -- "$src/objects" "$priv/objects" 2>/dev/null ||
    ! chmod -R u+w -- "$priv/objects" || ! rm -rf -- "$priv/objects/info"; then
    FM_TASK_CLONE_ERROR="the clone's object store could not be copied"
    return 1
  fi
  odd=$(find "$priv/objects" ! -type f ! -type d -print 2>/dev/null | head -n 1)
  if [ -n "$odd" ]; then
    FM_TASK_CLONE_ERROR="the clone's object store holds ${odd#"$priv/"}, which is not a regular file or directory"
    return 1
  fi
  if ! mkdir -p "$priv/objects/info" || ! printf '%s\n' "$objects" >"$priv/objects/info/alternates" ||
    ! printf 'ref: refs/heads/fm-snapshot\n' >"$priv/HEAD" || ! {
      if [ "$format" = sha256 ]; then
        printf '[core]\n\trepositoryformatversion = 1\n[extensions]\n\tobjectFormat = sha256\n'
      else
        printf '[core]\n\trepositoryformatversion = 0\n'
      fi
      printf '[core]\n\tbare = true\n\tcommitGraph = false\n\tmultiPackIndex = false\n\tuntrackedCache = false\n\tfsmonitor = false\n\thooksPath = /dev/null\n'
      printf '[pack]\n\tuseBitmaps = false\n\treadReverseIndex = false\n'
      printf '[gc]\n\tauto = 0\n[maintenance]\n\tauto = false\n'
      printf '[fetch]\n\trecurseSubmodules = false\n[submodule]\n\trecurse = false\n'
    } >"$priv/config"; then
    FM_TASK_CLONE_ERROR="could not create the private repository"
    return 1
  fi
}
