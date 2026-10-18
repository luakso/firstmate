#!/usr/bin/env bash
# Drives the real bin/fm-container-deliver.sh (and, for comparison, the base
# commit's version) through PR title/commit-list scenarios in disposable git
# worlds built by the repo's own delivery-world helpers. The forge is the
# suite's recording gh-axi stand-in; push goes to a real local bare remote.
# Usage: drive-own-commit-range.sh <worktree> <old-bin-dir>
set -u
WT=$1 OLD_BIN=$2
. "$WT/tests/fixtures.sh"
# Pull in the delivery-world helpers (fake gh-axi, make_world, deliver, ...).
eval "$(sed -n '/^URL=/,/^test_a_clean_branch_is_pushed/{/^test_a_clean_branch_is_pushed/d;p}' "$WT/tests/fm-container-deliver.test.sh")"
TMP_ROOT=$(fm_test_tmproot fm-deliver-drive)
fm_git_identity 'Contained Builder' builder@example.invalid
NEW=$WT/bin/fm-container-deliver.sh OLD=$OLD_BIN/fm-container-deliver.sh

report() {  # <label> <script>
  local out status title
  DELIVER=$2
  : > "$D_LOG"; rm -f "$D_LOG.body"
  out=$(deliver --ci-wait 0); status=$?
  title=$(grep -oE -- '--title=.* --body-file' "$D_LOG" | sed 's/^--title=//; s/ --body-file$//')
  edit=$(grep -E '^pr edit' "$D_LOG" | head -1)
  echo "--- [$1] exit=$status"
  echo "PR title  : ${title:-<no pr create; ${edit:+refreshed open PR via: ${edit%% --body-file*}}>}"
  echo "PR body commits:"; sed -n '/^## Commits/,/^## Evidence/{/^- /p}' "$D_LOG.body" 2>/dev/null | sed 's/^/    /'
  [ "$status" = 0 ] || printf '%s\n' "$out" | tail -5
}
reset_remote_branch() { git -C "$D/remote.git" update-ref -d refs/heads/fm/t1 2>/dev/null || true; }
upstream_merges() {  # <msg>
  git -C "$D/seed" pull -q --no-rebase "file://$D/remote.git" main 2>/dev/null
  printf '%s\n' "$1" >> "$D/seed/earlier.txt"; git -C "$D/seed" add earlier.txt
  git -C "$D/seed" commit -q -m "$1"; git -C "$D/seed" push -q "file://$D/remote.git" main
  GIT_CONFIG_GLOBAL="$D/gitconfig" git -C "$D_PROJ" fetch -q origin
}
both() {  # <label>
  report "$1 :: BASE c77f6d9^ (old)" "$OLD"; reset_remote_branch
  report "$1 :: TARGET c77f6d9 (new)" "$NEW"
}
wcommit() { git -C "$D_CLONE" -c core.hooksPath=/dev/null commit -q --allow-empty -m "$1"; : > "$D_EXEC"; write_evidence; }

echo "===== S1: clone started, an earlier PR merged on main, worker REBASED onto main (tokenbook #25/#26 shape)"
make_world s1
upstream_merges 'Check protected-path coverage, name gate checks, skip the Stop gate on a passed tree'
git -C "$D_CLONE" fetch -q "$D_PROJ" refs/remotes/origin/main
git -C "$D_CLONE" -c core.hooksPath=/dev/null rebase -q FETCH_HEAD
wcommit 'Test the add function'
both S1

echo; echo "===== S2: worker MERGED main into the branch (merge commit) instead of rebasing"
make_world s2
upstream_merges 'Earlier PR A already on main'
upstream_merges 'Earlier PR B already on main'
git -C "$D_CLONE" fetch -q "$D_PROJ" refs/remotes/origin/main
git -C "$D_CLONE" -c core.hooksPath=/dev/null merge -q --no-edit -m 'Merge main into fm/t1' FETCH_HEAD
wcommit 'Test the add function'
both S2

echo; echo "===== S3: plain branch, main never moved (regression: title = first own commit, all own commits listed)"
make_world s3
wcommit 'Test the add function'
wcommit 'Document the add function'
both S3

echo; echo "===== S4: main moved AGAIN after the worker took it in (project fetched the newer main)"
make_world s4
upstream_merges 'Earlier PR A already on main'
git -C "$D_CLONE" fetch -q "$D_PROJ" refs/remotes/origin/main
git -C "$D_CLONE" -c core.hooksPath=/dev/null rebase -q FETCH_HEAD
wcommit 'Test the add function'
upstream_merges 'Later PR C merged after the worker rebased'
both S4

echo; echo "===== S5: redelivery to the branch's OPEN PR after taking in main (body refresh path)"
make_world s5
upstream_merges 'Earlier PR A already on main'
git -C "$D_CLONE" fetch -q "$D_PROJ" refs/remotes/origin/main
git -C "$D_CLONE" -c core.hooksPath=/dev/null rebase -q FETCH_HEAD
wcommit 'Test the add function'
export FM_FAKE_GH_OPEN_PR=https://github.com/acme/widget/pull/26
both S5
unset FM_FAKE_GH_OPEN_PR

echo; echo "===== S6 (adversarial): project clone has no fetched origin/<default> ref -> falls back to clone_base range, still delivers"
make_world s6
upstream_merges 'Earlier PR A already on main'
git -C "$D_CLONE" fetch -q "$D_PROJ" refs/remotes/origin/main
git -C "$D_CLONE" -c core.hooksPath=/dev/null rebase -q FETCH_HEAD
wcommit 'Test the add function'
git -C "$D_PROJ" symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null
git -C "$D_PROJ" update-ref -d refs/remotes/origin/main
report "S6 :: TARGET (new), origin/main ref removed" "$NEW"

echo; echo "===== S7 (adversarial): project's origin/main is STALE (fetched before the earlier PR merged) -> no crash, clone_base still excludes nothing extra"
make_world s7
git -C "$D/seed" pull -q --no-rebase "file://$D/remote.git" main 2>/dev/null
printf x >> "$D/seed/earlier.txt"; git -C "$D/seed" add earlier.txt; git -C "$D/seed" commit -q -m 'Earlier PR A (project clone never fetched it)'
git -C "$D/seed" push -q "file://$D/remote.git" main
# worker obtains it out of band; project clone's origin/main stays at clone_base
git -C "$D_CLONE" fetch -q "$D/seed" main
git -C "$D_CLONE" -c core.hooksPath=/dev/null rebase -q FETCH_HEAD
wcommit 'Test the add function'
report "S7 :: TARGET (new), project origin/main stale" "$NEW"

echo; echo "===== S8 (adversarial): the worker's first commit already landed on main via a merge; worker adds one more and redelivers"
make_world s8
git -C "$D_CLONE" -c core.hooksPath=/dev/null push -q "$D/remote.git" HEAD:refs/heads/landed 2>/dev/null
git -C "$D/seed" pull -q --no-rebase "file://$D/remote.git" main
git -C "$D/seed" fetch -q "file://$D/remote.git" landed
git -C "$D/seed" merge -q --no-ff --no-edit -m 'Merge PR #25 (Add the add function)' FETCH_HEAD
git -C "$D/seed" push -q "file://$D/remote.git" main
GIT_CONFIG_GLOBAL="$D/gitconfig" git -C "$D_PROJ" fetch -q origin
wcommit 'Follow-up: handle overflow in add'
both S8
