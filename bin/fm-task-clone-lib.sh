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
# FM_TASK_CLONE_DIR is left naming the task directory.
FM_TASK_CLONE_DIR=
fm_task_clone_shaped() {  # <worktree>
  local wt_real dir marker git_dir common
  FM_TASK_CLONE_DIR=
  wt_real=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  fm_dirname_to dir "$wt_real"
  marker="$dir/$FM_TASK_CLONE_MARKER"
  [ -f "$marker" ] && [ ! -L "$marker" ] && [ -O "$marker" ] || return 1
  [ -d "$wt_real/.git" ] && [ ! -L "$wt_real/.git" ] || return 1
  git_dir=$(git -C "$wt_real" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  common=$(git -C "$wt_real" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  git_dir=$(cd "$git_dir" 2>/dev/null && pwd -P) || return 1
  common=$(cd "$common" 2>/dev/null && pwd -P) || return 1
  [ "$git_dir" = "$wt_real/.git" ] && [ "$common" = "$git_dir" ] || return 1
  FM_TASK_CLONE_DIR=$dir
}

# True when <worktree> is the clone fm_task_clone_create made for <task-id> in
# <home>: task-clone shaped, with a marker naming exactly that task and home.
fm_task_clone_owned() {  # <worktree> <task-id> <home>
  local home_real want
  home_real=$(cd "$3" 2>/dev/null && pwd -P) || return 1
  fm_task_clone_shaped "$1" || return 1
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
