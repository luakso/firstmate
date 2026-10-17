#!/usr/bin/env bash
# Behavior tests for bin/fm-container-deliver.sh, the host-side delivery of a
# contained direct-PR ship. Each case builds a real task clone of a project
# whose origin is https://github.com/acme/widget.git, rewritten by a private
# git config to a local bare repository, so the push is real while the forge
# is a fake gh-axi that records every call. Fakes for cargo, rustc, make, npm,
# lefthook, podman, and no-mistakes, sentinel git hooks in both of the clone's
# hook directories, an fsmonitor and a clean filter in the host's git config,
# and a filter attribute in the branch record any attempt to run project code
# or a hook on the host; every delivery asserts that none ran.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

DELIVER="$ROOT/bin/fm-container-deliver.sh"
TMP_ROOT=$(fm_test_tmproot fm-container-deliver)
fm_git_identity 'Contained Builder' builder@example.invalid
URL=https://github.com/acme/widget.git

# A fake gh-axi: logs argv and cwd, keeps each --body-file it is handed, and
# answers from FM_FAKE_GH_* the way gh-axi's TOON output reads. The PR's head
# is the remote branch, except that the first FM_FAKE_GH_STALE_READS head and
# check reads model a forge that has not caught up with the push: the first
# head read fails, later ones name FM_FAKE_GH_STALE_HEAD, and the checks are
# that head's failed rollup.
make_fake_gh_axi() {  # <fakebin>
  cat > "$1/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_GH_LOG:?}
printf '%s\n' "$*" >> "$log"
printf '%s\n' "$PWD" >> "$log.cwd"
prev=
for a in "$@"; do
  [ "$prev" != --body-file ] || cp "$a" "$log.body"
  prev=$a
done
stale=no
case "${1:-} ${2:-}" in
  'pr checks'|api\ *)
    reads=$(( $(cat "$log.reads" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$reads" > "$log.reads"
    [ "$reads" -gt "${FM_FAKE_GH_STALE_READS:-0}" ] || stale=$reads ;;
esac
case "${1:-} ${2:-}" in
  api\ *)
    case "$stale" in
      no) git --git-dir="${FM_FAKE_GH_REMOTE:?}" rev-parse refs/heads/fm/t1 ;;
      1) printf 'error: "HTTP 502"\n'; exit 1 ;;
      *) printf '%s\n' "${FM_FAKE_GH_STALE_HEAD:?}" ;;
    esac ;;
  'pr list')
    if [ -n "${FM_FAKE_GH_OPEN_PR:-}" ]; then
      printf 'count: 1\npull_requests[1]{number,title,state,author,draft,review,url}:\n  %s,old,open,me,no,none,%s\n' "${FM_FAKE_GH_OPEN_PR##*/}" "$FM_FAKE_GH_OPEN_PR"
    else
      printf 'count: 0\npull_requests[0]:\n'
    fi ;;
  'pr create') printf 'created:\n  number: 7\n  url: "https://github.com/acme/widget/pull/7"\n  base: main\n  head: fm/t1\n' ;;
  'pr edit') printf 'edited:\n  number: %s\n' "$3" ;;
  'pr view') printf 'pull_request:\n  number: %s\n  draft: %s\n' "$3" "${FM_FAKE_GH_DRAFT:-no}" ;;
  'pr ready') printf 'ready:\n  number: %s\n' "$3" ;;
  'pr checks')
    checks=${FM_FAKE_GH_CHECKS:-green}
    [ "$stale" = no ] || checks=failed
    case "$checks" in
      green) printf 'summary: "2 passed, 0 failed, 2 total"\nchecks[2]{name,conclusion}:\n  build,pass\n  "cargo deny",pass\n'; exit 0 ;;
      failed) printf 'summary: "1 passed, 1 failed, 2 total"\nchecks[2]{name,conclusion}:\n  build,fail\n  lint,pass\n'; exit 1 ;;
      none) printf 'checks: "0 passed, 0 failed, no check results reported for the PR head commit"\n'; exit 1 ;;
      pending) printf 'summary: "0 passed, 0 failed, 1 pending, 1 total"\nchecks[1]{name,conclusion}:\n  build,pending\n'; exit 8 ;;
    esac ;;
  'run list') printf 'count: 1\nruns[1]{id,title,status,conclusion,workflow,branch,event,created}:\n  4242,CI,completed,failure,CI,fm/t1,pull_request,1m ago\n' ;;
  'run view') printf 'error[E0308]: mismatched types\n  --> src/lib.rs:3:5\n' ;;
esac
exit 0
SH
  chmod +x "$1/gh-axi"
}

# A tool that must never run on the host during delivery.
make_sentinel() {  # <path> <exec-log>
  # shellcheck disable=SC2016  # $0 and $* belong to the sentinel script
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "$0" "$*" >> %s\nexit 0\n' "'$2'" > "$1"
  chmod +x "$1"
}

# One delivery world: an FM home, the project clone, the bare remote behind
# the github.com URL, the task clone on fm/t1 with one commit, its evidence,
# and its task record. Sets D_* globals.
make_world() {  # <name>
  local w=$TMP_ROOT/$1 hook tool
  D=$w
  D_HOME=$w/home
  D_LOG=$w/gh
  D_EXEC=$w/host-exec.log
  mkdir -p "$D_HOME/state" "$D_HOME/data/t1" "$D_HOME/config" "$D_HOME/projects" "$w/seed" "$w/projhooks"
  D_FAKEBIN=$(fm_fakebin "$w/fake")
  make_fake_gh_axi "$D_FAKEBIN"
  for tool in cargo rustc make npm lefthook podman no-mistakes; do
    make_sentinel "$D_FAKEBIN/$tool" "$D_EXEC"
  done
  make_sentinel "$w/filter-or-fsmonitor" "$D_EXEC"
  cat > "$w/gitconfig" <<EOF
[url "file://$w/remote.git"]
	insteadOf = $URL
[filter "evil"]
	clean = $w/filter-or-fsmonitor clean
	smudge = $w/filter-or-fsmonitor smudge
[core]
	fsmonitor = $w/filter-or-fsmonitor
EOF
  git init -q --bare -b main "$w/remote.git"
  git -C "$w/seed" init -q -b main
  printf 'pub fn add() {}\n' > "$w/seed/lib.rs"
  git -C "$w/seed" add lib.rs
  git -C "$w/seed" commit -q -m 'initial'
  git -C "$w/seed" push -q "file://$w/remote.git" main
  GIT_CONFIG_GLOBAL="$w/gitconfig" git clone -q "$URL" "$D_HOME/projects/widget"
  D_PROJ=$D_HOME/projects/widget
  D_CLONE=$(FM_HOME="$D_HOME" FM_ROOT="$ROOT" FM_TASK_CLONE_ROOT="$w/clones" \
    bash -c '. "$1/bin/fm-task-clone-lib.sh" && fm_task_clone_create "$2" t1 "$3"' _ \
    "$ROOT" "$D_PROJ" "$D_HOME") || fail "$1: could not create the task clone"
  mkdir -p "${D_CLONE%/*}/container"
  D_BASE=$(git -C "$D_CLONE" rev-parse HEAD)
  for hook in pre-push reference-transaction post-checkout pre-commit; do
    make_sentinel "$D_CLONE/.git/hooks/$hook" "$D_EXEC"
    make_sentinel "$w/projhooks/$hook" "$D_EXEC"
  done
  git -C "$D_CLONE" config core.hooksPath "$w/projhooks"
  git -C "$D_CLONE" -c core.hooksPath=/dev/null checkout -q -b fm/t1
  printf '*.rs filter=evil\n' > "$D_CLONE/.gitattributes"
  printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' > "$D_CLONE/lib.rs"
  git -C "$D_CLONE" add .gitattributes lib.rs
  git -C "$D_CLONE" -c core.hooksPath=/dev/null commit -q -m 'Add the add function'
  # A future mtime makes git re-read the file, so a status that honoured the
  # host's filter would run it.
  touch -t 203001010000 "$D_CLONE/lib.rs"
  : > "$D_EXEC"
  write_evidence
  write_meta
  : > "$D_HOME/state/t1.status"
}

write_evidence() {  # [head]
  printf 'head: %s\n\n- cargo fmt --check: ok\n- cargo test --locked: 3 passed\n' \
    "${1:-$(git -C "$D_CLONE" rev-parse HEAD)}" > "$D_HOME/data/t1/delivery-evidence.md"
}

write_meta() {  # [key=value overrides...]
  local -a lines=(window=ses:fm-t1 endpoint_task_id=t1 "worktree=$D_CLONE" "project=$D_PROJ" harness=claude
    kind=ship mode=direct-PR yolo=off branch=fm/t1 spawn_gen=g1 worktree_layout=clone runtime=container
    container=fm-t1-abcdef012345 "clone_base=$D_BASE")
  local kv
  for kv in "$@"; do
    lines=("${lines[@]/#${kv%%=*}=*/}")
    lines+=("$kv")
  done
  printf '%s\n' "${lines[@]}" | sed '/^$/d' > "$D_HOME/state/t1.meta"
}

deliver() {  # [args...]
  FM_ROOT_OVERRIDE='' FM_HOME="$D_HOME" FM_STATE_OVERRIDE="$D_HOME/state" FM_DATA_OVERRIDE="$D_HOME/data" \
    FM_CONFIG_OVERRIDE="$D_HOME/config" FM_PROJECTS_OVERRIDE="$D_HOME/projects" \
    GIT_CONFIG_GLOBAL="$D/gitconfig" FM_FAKE_GH_LOG="$D_LOG" FM_FAKE_GH_REMOTE="$D/remote.git" \
    FM_CONTAINER_DELIVER_CI_INTERVAL=1 FM_CONTAINER_DELIVER_CI_GRACE="${GRACE:-0}" \
    PATH="$D_FAKEBIN:$PATH" "$DELIVER" t1 "$@" 2>&1
}

remote_branch() {
  git -C "$D/remote.git" rev-parse --verify --quiet refs/heads/fm/t1 || true
}

assert_nothing_ran_on_the_host() {  # <label>
  [ ! -s "$D_EXEC" ] || fail "$1: project code or a hook ran on the host:"$'\n'"$(cat "$D_EXEC")"
}

# The last status line must match <glob>.
assert_last_status() {  # <glob> <msg>
  local line
  line=$(tail -n 1 "$D_HOME/state/t1.status")
  # shellcheck disable=SC2254  # the glob is the assertion
  case "$line" in
    $1) ;;
    *) fail "$2: $line" ;;
  esac
}

expect_refusal() {  # <label> <expected-text> [args...]
  local label=$1 want=$2 out status
  shift 2
  : > "$D_EXEC"
  out=$(deliver "$@")
  status=$?
  expect_code 1 "$status" "$label: the delivery did not refuse"$'\n'"$out"
  assert_contains "$out" "$want" "$label: the refusal does not say why"
  assert_equals '' "$(remote_branch)" "$label: the branch reached the remote"
  assert_absent "$D_LOG" "$label: gh-axi ran although the branch was refused"
  [ ! -s "$D_HOME/state/t1.status" ] || fail "$label: the refusal wrote a status line"
  assert_nothing_ran_on_the_host "$label"
}

test_a_clean_branch_is_pushed_published_and_reported() {
  local out status tip line
  make_world clean
  tip=$(git -C "$D_CLONE" rev-parse HEAD)
  out=$(deliver --ci-wait 30)
  status=$?
  expect_code 0 "$status" "a clean branch should deliver"$'\n'"$out"
  assert_equals "$tip" "$(remote_branch)" "the remote branch is not the verified tip"
  assert_equals "delivered_head=$tip" "$(grep '^delivered_head=' "$D_HOME/state/t1.meta")" "the task record does not name the pushed head"
  assert_grep "pr create --repo acme/widget --title Add the add function --body-file " "$D_LOG" "the PR was not opened on the project's repository with the commit subject"
  assert_grep "--base main --head fm/t1" "$D_LOG" "the PR does not target the default branch from the ship branch"
  assert_no_grep "pr ready" "$D_LOG" "a non-draft PR was marked ready"
  assert_no_grep "$D_CLONE" "$D_LOG.cwd" "gh-axi ran inside the worker's clone"
  assert_grep "cargo test --locked: 3 passed" "$D_LOG.body" "the PR body lost the worker's evidence"
  assert_grep "Add the add function" "$D_LOG.body" "the PR body does not list the commits"
  ! grep -q '^head: ' "$D_LOG.body" || fail "the PR body carries the evidence's head line"
  assert_last_status "done \[at=[0-9]*\]: PR https://github.com/acme/widget/pull/7 checks green" "the status line is not the direct-PR ready signal"
  line=$(tail -n 1 "$D_HOME/state/t1.status")
  assert_nothing_ran_on_the_host "clean delivery"
  # The ready signal it wrote passes the same named-head gate every direct-PR
  # done: does.
  # shellcheck disable=SC2016  # expanded by the inner bash
  bash -c '. "$1/bin/fm-dod-lib.sh" && fm_dod_accept_ship_done ship direct-PR "$2" "$3" "$4" "$5" t1 "$5/t1.meta"' _ \
    "$ROOT" "$D_CLONE" "$D_PROJ" "$line" "$D_HOME/state" >/dev/null ||
    fail "the done: line host delivery wrote is refused by the named-head gate"
  pass "a clean contained branch is pushed with host credentials, published, watched, and reported with no project code on the host"
}

test_a_redelivery_reuses_the_open_pr_and_a_draft_is_marked_ready() {
  local out status
  make_world reuse
  out=$(FM_FAKE_GH_OPEN_PR=https://github.com/acme/widget/pull/5 FM_FAKE_GH_DRAFT=yes deliver --ci-wait 30)
  status=$?
  expect_code 0 "$status" "a redelivery should succeed"$'\n'"$out"
  assert_no_grep "pr create" "$D_LOG" "a second PR was opened for a branch that has one"
  assert_grep "pr edit 5 --repo acme/widget --body-file " "$D_LOG" "the open PR's body was not refreshed"
  assert_grep "pr ready 5 --repo acme/widget" "$D_LOG" "a draft PR was not marked ready"
  assert_grep "PR https://github.com/acme/widget/pull/5 checks green" "$D_HOME/state/t1.status" "the ready signal does not name the reused PR"
  pass "a redelivery refreshes the branch's open PR and never leaves it a draft"
}

test_a_redelivery_waits_for_the_pr_head_to_reach_the_pushed_commit() {
  local out status tip
  make_world stale-head
  tip=$(git -C "$D_CLONE" rev-parse HEAD)
  out=$(FM_FAKE_GH_OPEN_PR=https://github.com/acme/widget/pull/5 FM_FAKE_GH_STALE_READS=3 \
    FM_FAKE_GH_STALE_HEAD="$D_BASE" deliver --ci-wait 30)
  status=$?
  expect_code 0 "$status" "a redelivery whose PR head lags the push should still end green"$'\n'"$out"
  assert_equals "$tip" "$(remote_branch)" "the remote branch is not the verified tip"
  assert_last_status "done \[at=[0-9]*\]: PR https://github.com/acme/widget/pull/5 checks green" \
    "the previous head's failed checks were reported for the pushed commit"
  assert_no_grep "blocked" "$D_HOME/state/t1.status" "a stale head's failed rollup was reported as blocked"
  assert_absent "${D_CLONE%/*}/container/ci-failures.md" "failed-job logs were saved for a head that was not pushed"
  assert_grep "api repos/acme/widget/pulls/5 --jq .head.sha" "$D_LOG" "the PR head was not read through gh-axi"
  assert_nothing_ran_on_the_host "stale PR head"
  pass "a redelivery trusts no checks until the PR head is the pushed commit, so an old head's failed rollup is never reported"
}

# Worker-written git config naming sentinels and another bare repository.
hostile_git_config() {
  cat <<EOF
[credential]
	helper = !$D/credential-helper
[filter "evil"]
	clean = $D/clone-filter clean
	smudge = $D/clone-filter smudge
[core]
	sshCommand = $D/ssh-command
	fsmonitor = $D/clone-fsmonitor
[remote "origin"]
	pushurl = file://$D/attacker.git
[url "file://$D/attacker.git"]
	pushInsteadOf = https://github.com/
EOF
}

assert_worker_git_config_was_ignored() {  # <tip> <label>
  local out status tip=$1 label=$2
  out=$(deliver --ci-wait 0)
  status=$?
  expect_code 0 "$status" "$label: the delivery should succeed"$'\n'"$out"
  assert_equals "$tip" "$(remote_branch)" "$label: the push did not reach the project's origin"
  assert_equals '' "$(git -C "$D/attacker.git" rev-parse --verify --quiet refs/heads/fm/t1 || true)" "$label: the push reached the worker-named repository"
  assert_nothing_ran_on_the_host "$label"
}

plant_sentinels() {
  local tool
  for tool in credential-helper clone-filter ssh-command clone-fsmonitor; do
    make_sentinel "$D/$tool" "$D_EXEC"
  done
  git init -q --bare "$D/attacker.git"
}

test_worker_written_git_config_never_runs_or_redirects_on_the_host() {
  local tip
  make_world local-config
  plant_sentinels
  tip=$(git -C "$D_CLONE" rev-parse HEAD)
  hostile_git_config >> "$D_CLONE/.git/config"
  : > "$D_EXEC"
  assert_worker_git_config_was_ignored "$tip" "the clone's own config"

  make_world swapped-gitdir
  plant_sentinels
  tip=$(git -C "$D_CLONE" rev-parse HEAD)
  mv "$D_CLONE/.git" "$D/gitdir-before-swap"
  cp -R "$D/gitdir-before-swap" "$D_CLONE/.git"
  {
    printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n\thooksPath = %s\n' "$D/projhooks"
    printf '[remote "origin"]\n\turl = %s\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n' "$URL"
    hostile_git_config
  } > "$D_CLONE/.git/config"
  : > "$D_EXEC"
  assert_worker_git_config_was_ignored "$tip" "a swapped .git directory"
  pass "a credential helper, filter, ssh command, fsmonitor, pushurl, or pushInsteadOf the worker writes never runs on the host or redirects the push"
}

test_ci_outcomes_are_reported_without_an_agent() {
  local out status log
  make_world ci-failed
  out=$(FM_FAKE_GH_CHECKS=failed deliver --ci-wait 30)
  status=$?
  expect_code 3 "$status" "a failed check should end in the blocked report"$'\n'"$out"
  log="${D_CLONE%/*}/container/ci-failures.md"
  assert_last_status "blocked \[at=[0-9]*\]: PR https://github.com/acme/widget/pull/7 checks failed: build; failed-job logs for the contained worker are in $log" \
    "the failure report does not name the failing check and its log file"
  assert_grep "error[E0308]: mismatched types" "$log" "the failed-job log was not saved for the worker"
  assert_grep "run view 4242 --repo acme/widget --log-failed" "$D_LOG" "the failed run's log was not read"
  assert_nothing_ran_on_the_host "failed CI"

  make_world ci-none
  out=$(FM_FAKE_GH_CHECKS=none deliver --ci-wait 30)
  expect_code 0 "$?" "a PR with no CI should still be reported"$'\n'"$out"
  assert_last_status "done \[at=[0-9]*\]: PR https://github.com/acme/widget/pull/7 (no CI checks reported)" \
    "a PR with no checks was not reported as such"

  make_world ci-unwatched
  out=$(deliver --ci-wait 0)
  expect_code 0 "$?" "an unwatched delivery should still be reported"$'\n'"$out"
  assert_no_grep "pr checks" "$D_LOG" "--ci-wait 0 still read the checks"
  assert_last_status "done \[at=[0-9]*\]: PR https://github.com/acme/widget/pull/7 (CI checks not settled)" \
    "an unwatched PR was not reported as unsettled"

  make_world ci-pending
  out=$(FM_FAKE_GH_CHECKS=pending deliver --ci-wait 2)
  expect_code 0 "$?" "a PR whose checks outlast the wait should still be reported"$'\n'"$out"
  assert_last_status "*(CI checks not settled)" "checks still pending at the end of the wait were not reported as unsettled"
  pass "green, failed, absent, and unsettled CI each end in one status line, with failed-job logs saved for the worker"
}

test_each_unverifiable_branch_is_refused() {
  local other victim

  make_world wrong-branch
  git -C "$D_CLONE" -c core.hooksPath=/dev/null checkout -q -b other
  expect_refusal "wrong branch" "HEAD is not its recorded branch fm/t1"

  make_world dirty-tracked
  printf '// unsaved\n' >> "$D_CLONE/lib.rs"
  expect_refusal "uncommitted change" "uncommitted or untracked changes"

  make_world dirty-untracked
  printf 'scratch\n' > "$D_CLONE/notes.txt"
  expect_refusal "untracked file" "notes.txt"

  make_world not-descending
  git -C "$D_CLONE" update-ref refs/heads/fm/t1 "$(git -C "$D_CLONE" commit-tree -m 'unrelated root' "$(git -C "$D_CLONE" rev-parse 'HEAD^{tree}')")"
  write_evidence
  expect_refusal "unrelated history" "does not descend from the commit its clone started from"

  make_world graft
  other=$(git -C "$D_CLONE" commit-tree -m 'orphan' "$(git -C "$D_CLONE" rev-parse 'HEAD^{tree}')")
  git -C "$D_CLONE" update-ref refs/heads/fm/t1 "$other"
  printf '%s %s\n' "$other" "$D_BASE" > "$D_CLONE/.git/info/grafts"
  write_evidence
  expect_refusal "a graft faking ancestry" "does not descend from the commit its clone started from"

  make_world replace
  other=$(git -C "$D_CLONE" commit-tree -m 'orphan' "$(git -C "$D_CLONE" rev-parse 'HEAD^{tree}')")
  git -C "$D_CLONE" replace "$other" "$(git -C "$D_CLONE" rev-parse HEAD)"
  git -C "$D_CLONE" update-ref refs/heads/fm/t1 "$other"
  write_evidence "$other"
  expect_refusal "a replace ref faking ancestry" "does not descend from the commit its clone started from"

  make_world no-commit
  git -C "$D_CLONE" update-ref refs/heads/fm/t1 "$D_BASE"
  git -C "$D_CLONE" -c core.hooksPath=/dev/null reset -q --hard
  write_evidence
  expect_refusal "nothing to deliver" "adds no commit"

  make_world workflow
  mkdir -p "$D_CLONE/.github/workflows"
  printf 'on: pull_request_target\n' > "$D_CLONE/.github/workflows/ci.yml"
  git -C "$D_CLONE" add .github
  git -C "$D_CLONE" -c core.hooksPath=/dev/null commit -q -m 'ci'
  write_evidence
  expect_refusal "a workflow change" ".github/workflows/ci.yml"

  make_world workflow-reverted
  mkdir -p "$D_CLONE/.GitHub"
  printf '* @someone\n' > "$D_CLONE/.GitHub/CODEOWNERS"
  git -C "$D_CLONE" add .GitHub
  git -C "$D_CLONE" -c core.hooksPath=/dev/null commit -q -m 'owners'
  git -C "$D_CLONE" rm -q -r .GitHub
  git -C "$D_CLONE" -c core.hooksPath=/dev/null commit -q -m 'drop owners'
  write_evidence
  expect_refusal "a .github change any commit made" ".GitHub/CODEOWNERS"

  make_world alternates
  mkdir -p "$D/elsewhere/objects"
  printf '%s\n' "$D/elsewhere/objects" >> "$D_CLONE/.git/objects/info/alternates"
  expect_refusal "a foreign object store" "not only from its project clone's object store"

  make_world commondir
  mkdir -p "$D/foreign"
  make_sentinel "$D/credential-helper" "$D_EXEC"
  make_sentinel "$D/foreign-fsmonitor" "$D_EXEC"
  git init -q --bare "$D/foreign/repo.git"
  git --git-dir="$D/foreign/repo.git" config credential.helper "!$D/credential-helper"
  git --git-dir="$D/foreign/repo.git" config core.fsmonitor "$D/foreign-fsmonitor"
  printf '%s\n' "$D/foreign/repo.git" > "$D_CLONE/.git/commondir"
  expect_refusal "a commondir pointing at another repository" "holds a commondir file"

  make_world object-symlink
  printf 'secret\n' > "$D/host-secret"
  ln -s "$D/host-secret" "$D_CLONE/.git/objects/zz"
  expect_refusal "a symlink in the clone's object store" "objects/zz, which is not a regular file or directory"

  make_world origin
  git -C "$D_CLONE" remote set-url origin https://github.com/attacker/widget.git
  expect_refusal "a different origin" "is not its project clone's origin"

  make_world evidence-missing
  rm -f "$D_HOME/data/t1/delivery-evidence.md"
  expect_refusal "missing evidence" "delivery-evidence.md is missing"

  make_world evidence-stale
  write_evidence "$D_BASE"
  expect_refusal "evidence for another commit" "its checks did not run on this commit"

  make_world evidence-symlink
  victim="$D/host-secret"
  printf 'head: %s\nsecret host content\n' "$(git -C "$D_CLONE" rev-parse HEAD)" > "$victim"
  rm -f "$D_HOME/data/t1/delivery-evidence.md"
  ln -s "$victim" "$D_HOME/data/t1/delivery-evidence.md"
  expect_refusal "evidence symlinked to a host file" "not a regular file"

  make_world not-container
  write_meta runtime=
  expect_refusal "an ordinary ship" "does not run in the container runtime"

  make_world no-mistakes-mode
  write_meta mode=no-mistakes
  expect_refusal "a no-mistakes ship" "publishes only mode=direct-PR"

  make_world no-base
  write_meta clone_base=
  expect_refusal "no recorded base" "no clone_base= commit"
  pass "every branch host delivery cannot verify is refused before anything is pushed or published"
}

test_a_diverged_remote_branch_is_never_overwritten() {
  local out status before
  make_world diverged
  git -C "$D/seed" checkout -q -b fm/t1
  git -C "$D/seed" commit -q --allow-empty -m 'someone else'
  git -C "$D/seed" push -q "file://$D/remote.git" fm/t1
  before=$(remote_branch)
  out=$(deliver --ci-wait 0)
  status=$?
  expect_code 1 "$status" "a push onto a diverged branch should fail"$'\n'"$out"
  assert_contains "$out" "nothing was force-pushed" "the failure does not say the branch was left alone"
  assert_equals "$before" "$(remote_branch)" "the diverged remote branch was overwritten"
  assert_absent "$D_LOG" "a PR was touched after the push failed"
  assert_nothing_ran_on_the_host "diverged push"
  pass "a remote branch that diverged is refused, never force-pushed"
}

test_a_clean_branch_is_pushed_published_and_reported
test_a_redelivery_reuses_the_open_pr_and_a_draft_is_marked_ready
test_a_redelivery_waits_for_the_pr_head_to_reach_the_pushed_commit
test_worker_written_git_config_never_runs_or_redirects_on_the_host
test_ci_outcomes_are_reported_without_an_agent
test_each_unverifiable_branch_is_refused
test_a_diverged_remote_branch_is_never_overwritten

echo "# all fm-container-deliver tests passed"
