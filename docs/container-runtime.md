# Container runtime

The container runtime level runs every Claude ship and scout of a selected project inside its own rootless Podman container, where only that task's files exist.
It exists for projects whose workers must not be able to read the rest of the captain's machine: the [Claude sandbox](configuration.md#claude-sandbox-configclaude-sandbox) fences writes and network but not reads, and it leaves hooks, MCP servers, and language servers running outside its fence.
A container starts from nothing, so a missing mount fails closed, and hooks, MCP servers, and language servers run inside it too.
Every other project keeps its ordinary launch.

[`docs/configuration.md`](configuration.md#container-runtime-configcontainer) owns the opt-in file and the token file; [`bin/fm-container-lib.sh`](../bin/fm-container-lib.sh) owns the exact flags, mounts, and environment, and its header the design.

## Setup

The captain does these once on the host, outside any agent.

1. Install Podman and passt (Arch: `pacman -S podman passt`) and keep the user's `/etc/subuid` and `/etc/subgid` ranges.
   Rootless Podman needs the memory and pids cgroup controllers delegated to the user session, which systemd does by default.
2. Build the worker image (below).
3. Create the Claude login for container workers: run `claude setup-token`, then store the printed token alone in `config/container-claude-token` and run `chmod 600` on it.
4. Select the project: write `config/container/<project>` with at least an `image=` line, such as `image=localhost/tokenbook-dev:latest`.
5. Make sure `config/claude-permission-mode` holds `auto`, and that the project's ships are dispatched as `direct-PR`, which Firstmate [delivers from the host](#host-side-delivery), or `local-only`; `no-mistakes` is refused (see [Supported limits](#supported-limits)).
   A `direct-PR` project's origin must be a github.com repository the host's own `git` and `gh-axi` logins can push to and open pull requests on.

Then run the live verification below before the first real task.

## Build the image

The image definition is [`bin/container/rust-claude.Containerfile`](../bin/container/rust-claude.Containerfile): a pinned Rust toolchain with clippy and rustfmt, cargo-deny, cargo-nextest, cargo-machete, cargo-mutants, lefthook, gitleaks, Claude Code, git, and the small in-container contract the runtime relies on (`/usr/bin/tini` as PID 1, `/bin/sh`, `socat`, `tzdata`, and a writable `/cargo`).
It is generic and lives in Firstmate rather than in the project, so the agent a container holds can never edit the image that holds it, and one definition serves every Rust project.
Every version is a required build argument, and the toolchain comes from the project's own `rust-toolchain.toml`, so the image and the project agree on it:

```sh
cd ~/Projects/firstmate
podman build \
  --build-arg RUST_TOOLCHAIN="$(sed -n 's/^channel *= *"\(.*\)"$/\1/p' projects/tokenbook/rust-toolchain.toml)" \
  --build-arg CLAUDE_CODE_VERSION=2.1.296 \
  --build-arg CARGO_DENY_VERSION=0.18.4 \
  --build-arg CARGO_NEXTEST_VERSION=0.9.148 \
  --build-arg CARGO_MACHETE_VERSION=0.9.2 \
  --build-arg CARGO_MUTANTS_VERSION=27.1.0 \
  --build-arg LEFTHOOK_VERSION=2.1.16 \
  --build-arg GITLEAKS_VERSION=8.30.1 \
  -t localhost/tokenbook-dev:latest \
  -f bin/container/rust-claude.Containerfile bin/container
```

Rebuild it to change any of those versions; a toolchain the project pins but the image lacks fails inside the container, because the read-only image cannot install one.
`BASE_IMAGE` defaults to `docker.io/library/node:22-bookworm-slim`; pin it by digest with `--build-arg BASE_IMAGE=docker.io/library/node@sha256:<digest>` to make rebuilds reproducible.

## What the container holds

A contained worker's pane runs [`bin/fm-container-run.sh`](../bin/fm-container-run.sh), which stays on the host for the container's life and runs `podman run --rm -it` with:

- `--userns=keep-id`, `--read-only` with a private `--tmpfs /tmp`, `--cap-drop all`, `--security-opt no-new-privileges`, and the project file's `--pids-limit` and `--memory`;
- `--network none`, so nothing but loopback exists;
- `tini` as PID 1 and a `socat` bridge from `127.0.0.1:3128` to the egress proxy's socket, with `HTTPS_PROXY` and `HTTP_PROXY` pointing at it;
- `TZ` set to the host's zone name, taken from the runner's own `TZ` or from the zoneinfo file the host's `/etc/localtime` links to, so the container's clock reads like the host's; no host file is mounted for it, and a host whose zone cannot be named leaves the container on UTC.

Nothing from the host is mounted except this list, each entry at the same path it has on the host:

| Path | Access | Why |
| --- | --- | --- |
| The task's own clone | read-write | The worker's copy, as for a sandboxed task. |
| The clone's `.git/config` and `.git/hooks` | read-only | Firstmate's own git commands read the clone on the host, so a planted `core.fsmonitor` or hook would run outside the container; the Claude sandbox denies writes to both for the same reason. |
| The project clone's `.git/objects` | read-only | The clone borrows the project's history through `objects/info/alternates`. |
| `<task-dir>/container/home` | read-write | `HOME`, with `CLAUDE_CONFIG_DIR` at its `.claude`, so transcripts and Claude state stay in the task area, never in the captain's `~/.claude`. |
| `<task-dir>/container/events` | read-write | The hook event file the host relays (below). |
| `state/<id>.status`, `state/<id>.inbox`, `data/<id>` | read-write | The worker's status log, steering inbox, and brief and report directory. |
| The one `state/operational-inbox` record carrying this launch's brief | read-only | The launch doorbell names it. |
| The code root's `.agents/skills` | read-only | The launch brief names skills there. |
| The proxy socket, at `/run/fm-proxy.sock` | connect | The only way out. |
| The named volume `fm-cargo-<project>`, at `/cargo` | read-write | `CARGO_HOME`, shared by the project's tasks so builds stay warm. |

`<task-dir>` is the task clone's parent, `~/.firstmate/clones/<home-tag>/<id>`.
No Docker or Podman socket is ever mounted, and Claude's own login, `~/.claude`, `~/Projects` beyond the channel paths above, `~/Work`, and every credential file are simply absent.
Git identity comes from the clone's effective `user.name` and `user.email` at spawn, passed as `GIT_AUTHOR_*` and `GIT_COMMITTER_*`, because the captain's global git config is not mounted.

## Network

The egress allow-list is exactly `api.anthropic.com`, `index.crates.io`, and `static.crates.io`, on port 443.
Claude Code needs nothing else to authenticate: with `CLAUDE_CODE_OAUTH_TOKEN` it sends the token straight to `api.anthropic.com`, and the launch sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, `DISABLE_AUTOUPDATER=1`, and `ENABLE_CLAUDEAI_MCP_SERVERS=false` so it does not try telemetry, updates, or claude.ai connectors.

[`bin/fm-container-proxy.mjs`](../bin/fm-container-proxy.mjs) enforces the list from the host: the runner starts one per launch on a Unix socket in a private directory, it tunnels an HTTP `CONNECT` only when the requested `host:port` is on the list, resolving the name on the host, and it answers every other `CONNECT` with 403 and every plain request with 405.
It never inspects TLS, and it logs each decision, without content, to `<task-dir>/container/proxy.log`.

A host-side proxy was chosen over an in-namespace firewall such as the one in Anthropic's reference devcontainer, because that firewall needs `NET_ADMIN` inside the container, contradicting `--cap-drop all`, and filters IP addresses, which CDN-fronted hosts such as `static.crates.io` rotate.
With `--network none` and no mounted socket but the proxy's, a container whose proxy is not running has no network at all, and the runner refuses to start one in that state.

## Lifecycle

- Brief delivery, steering, and status reporting work unchanged: the launch doorbell names the mounted brief record, steering doorbells name `state/<id>.inbox` messages the worker reads and moves into `handled/`, and the status command appends to the mounted log; its optional fleet-ledger step finds no `config/` inside and is skipped.
- Claude's lifecycle hooks run inside the container, where this home's `state/` does not exist, so each one appends a fixed line to the event file, and the runner applies it on the host to the busy-state contract and the turn-ended notification with the incarnation's own gen; after the container exits it records a session end, so a crash never leaves a stale busy record.
- The contained Claude runs under Podman's `conmon`, not under the pane's shell, so no pane process tree holds it and the backends' pane probes cannot attribute it.
  Every liveness decision Firstmate makes for a task whose record carries `runtime=container` - the steering doorbell, `fm-control`, the watcher's dead and stale checks, crew state, relaunch, and teardown - therefore reads its recorded container: the agent is alive only while `podman container inspect` reports the container running and `podman top` lists a Claude process inside it, and dead once the container is gone or exited.
  The pane's own read still decides whether the endpoint exists, so a gone pane over a container that still runs Claude is never treated as absent.
  [`bin/fm-container-lib.sh`](../bin/fm-container-lib.sh) "LIVENESS" owns the verdicts.
- `fm-control` interrupt and exit reach Claude through the pane's terminal as before; Claude's exit ends the container, `--rm` removes it, and the pane returns to its shell, so a relaunch finds an agent-free endpoint and starts a new container under the same name.
- A relaunch keeps a task in the runtime it was spawned in ([`docs/configuration.md`](configuration.md#refusals-and-relaunch) has the refusals).
- Teardown removes the task's container with `podman rm --force` before it reaps the task's processes, and refuses to remove the clone while that fails; the clone's task directory, with the container home, event file, spec, and proxy log, is removed with the clone, and the shared `fm-cargo-<project>` volume is kept.
  Before that removal it copies the worker's session transcripts out of the container home into the host-only [session archive](configuration.md#session-archive), and a copy that cannot complete refuses the removal and keeps the task directory, transcripts included.
- A container scout cannot run `fm-captain-hold.sh`, so its launch brief has it list its captain questions in its report, exactly as a sandboxed scout does, and Firstmate runs `hold` and `complete` for it.

## Host-side delivery

A contained worker holds no forge credentials and has no route to GitHub, so a poisoned dependency running in its build or tests can push nothing anywhere.
A `direct-PR` ship is therefore split in two: the worker builds, checks, and commits inside its container, and Firstmate does only the outward steps from the host.

1. At spawn, the task record gains `clone_base=`, the commit the task clone started from, and the launch brief replaces the push-and-PR steps of the Definition of done.
2. The worker runs the project's own checks inside the container on its final commit, writes `data/<id>/delivery-evidence.md` whose first line is `head: <that commit's full SHA>` followed by the commands it ran and their results, leaves its tree clean, and reports `done: ready in branch <branch> for host delivery`.
   That `done:` is accepted when the clone's HEAD is the tip of the task's recorded branch.
3. Firstmate runs `bin/fm-container-deliver.sh <id>` in the background.
   It refuses a branch it cannot verify - a HEAD off the recorded branch, uncommitted or untracked changes, history that does not descend from `clone_base`, any commit touching `.github/`, a `commondir` file in the clone's `.git`, an object store other than the project's or one holding anything but regular files and directories, an origin other than the project clone's, or evidence for a different commit - and the script's header owns the exact checks.
   It then pushes the verified commit with the host's git credentials to the project clone's origin URL, never with `--force`, records it as `delivered_head=` in the task record, opens or refreshes the PR with `gh-axi`, from the commit list plus the evidence file, and watches the PR's checks, trusting them only once `gh-axi` reports the pushed commit as the PR's head, so a redelivery never reports the previous head's checks.
4. It appends one line to the task's status: `done: PR <url> checks green`, `done: PR <url> (no CI checks reported)`, or `done: PR <url> (CI checks not settled)`, which are the ordinary direct-PR ready signal, accepted only while the clone's HEAD is the recorded `delivered_head`, or `blocked: PR <url> checks failed: ...`.
   On a failure it saves the failed-job logs in the host-only `<task-dir>/container/ci-failures.md`; Firstmate steers the worker with them, the worker fixes and reports ready again, and the next delivery pushes to the same PR.

No build, test, lint, formatter, git hook, or agent runs on the host at any step.
The container can rewrite anything under the clone's `.git`, even replace the directory, so no git command the delivery runs takes the clone's `.git` as its repository.
The clone's ownership is checked from its files: the task-clone marker beside it, a real `.git` directory with a regular `HEAD`, and no `commondir` file.
Every git command runs either in the host-owned project clone, to read its origin, objects, and default branch, or in a private bare repository with config the delivery writes itself, which holds a copy of the clone's `.git/objects` without `objects/info`, borrows only the project clone's object store, ignores commit-graphs, multi-pack-indexes, and pack bitmaps, and defines no hook, filter, driver, or helper.
The clone's `HEAD`, branch ref, `objects/info/alternates`, index, `info/exclude`, and config, the last only for its origin URL, are read as plain data, and the clone's directory is git's work tree only for the clean-tree status, which reads a private copy of the index, without the host's global config and without running git inside a submodule.
Only the push reads the host's git config, for its credentials, and it pushes to the project clone's origin URL, never recursing into submodules.
These host tools read a contained task's clone the same way once a worker may have run in it, through the shared helpers [`bin/fm-task-clone-lib.sh`](../bin/fm-task-clone-lib.sh) "CONTAINED CLONES" owns, so none of them runs git with the clone's `.git` as its repository, and none runs a forge CLI in the clone; the clone's directory is git's work tree only for a status read against a private snapshot.
Only a fresh spawn runs git in the clone, while creating it and before any worker has run there; from then on a relaunch, the removal of a clone after an aborted launch, teardown, and `bin/fm-merge-local.sh` check the clone's shape and ownership from its files, the Definition-of-done gate reads its HEAD and refs as data, and `bin/fm-crew-state.sh` attributes no no-mistakes run to it.
A relaunch's checkpoint (`bin/fm-control.sh relaunch`) reads the clone's HEAD as data and its status from a snapshot; `bin/fm-spawn.sh` writes its hook excludes straight into the clone's `.git/info/exclude`, only through a real directory and a regular file, and takes the container's git identity from the project clone.
`bin/fm-review-diff.sh` diffs in a private snapshot and fetches the pull request and default branch there from the project clone's origin URL, `bin/fm-pr-check.sh` runs `gh` from a private empty directory, and `bin/fm-bearings-snapshot.sh` lists pull requests for the project clone's origin.
`bin/fm-merge-local.sh` checks and imports a contained local-only branch from a snapshot.
Teardown judges uncommitted and landed work in a fresh snapshot whose remotes are the project clone's remote-tracking refs plus the recorded `delivered_head`, fetches a pull request's head into that snapshot from the project clone's origin URL, asks the forge about the PR naming the project clone's repository, and still refuses uncommitted work and work it cannot prove landed.
A landing then fast-forwards the host's own project clone, where the host's own git config applies as it does to every landed change.

## Supported limits

- Only Claude workers run in a container, only on `tmux`, `herdr`, `zellij`, and `cmux`, and a ship only in `direct-PR` mode, delivered from the host as above, or in `local-only` mode.
- A contained ship cannot use `no-mistakes`: the no-mistakes daemon runs every pipeline agent - review, the test evidence agent that builds and runs the product, documentation and lint, PR drafting, and rebase and CI fixes - and every configured command on the host, as the captain and with no sandbox, so it would run the project's code outside the container and give agents with full host read access the worker's untrusted branch.
  Running that validation inside the container, with only the push, PR, and CI watch on the host, is open follow-up work.
- Host delivery opens pull requests on github.com only, so a contained ship of a Gerrit-forge project is refused.
- GitHub CI still runs the branch's code with whatever the repository's existing workflows grant a pull request; host delivery refuses any change under `.github/` so a contained worker cannot change those grants, but keep pull-request workflows free of secrets and write permissions.
- The PR body is the worker's commit messages and evidence file, which are untrusted text like the diff itself.
- The kernel is shared; a kernel exploit is out of scope, as are microVM and gVisor runtimes.
- Anything mounted can leave through an allowed host, and the token is readable inside the container, so the token is scoped to this use and rotated.
- The cargo cache volume is shared by every task of the project, so one task can leave modified extracted sources for the next; cargo verifies a `.crate` checksum when it downloads, not the extracted tree on later builds.
- Firstmate's AI-trailer `commit-msg` strip runs from the host and does not reach inside; Claude's attribution-off settings still ride the launch.
- The task clone's remotes are the project clone's, but the container cannot reach them, and git commands that rewrite the clone's `.git/config`, such as `git config`, `git remote add`, or setting an upstream, fail inside the container.
- After a container's first launch its home belongs to the worker, so a relaunch reuses it untouched rather than reading or rewriting anything in it; a worker that removes its own trust or onboarding record meets that dialog on its next relaunch.
- Each container launch rewrites the clone's `.claude/settings.local.json` hooks from the host, which the worker could redirect with a symlink, so a launch refuses, writing nothing, when `.claude` is a symlink or not a directory you own, or when `settings.local.json` exists and is a symlink or not a regular file you own.
- Firstmate and the captain still read what a contained worker writes into `data/<id>` and `state/<id>.inbox`, so those stay untrusted input, as they are for every worker.

## Live verification

Firstmate runs this after the captain has installed Podman and passt, built the image, and created the token file.
It spends no model tokens except in steps 3 and 5.

1. Run the automated probe, which starts a real container through the runner with a probe script in place of Claude:

   ```sh
   FM_LIVE_CONTAINER=1 bin/fm-test-run.sh tests/fm-container-runtime-live-e2e.test.sh
   ```

   It proves from inside the container that `~/.claude`, `~/Projects`, `~/Work`, `~/.ssh`, and `~/.config` are absent, that the rootfs is read-only, every capability is dropped, and the user is the host user, that no runtime socket exists, that `https://example.com` is refused (and recorded as `refused example.com:443` in the proxy log) while a direct connection has no route, that `index.crates.io` answers, and that `cargo build` of a crate with a crates.io dependency succeeds.
   `FM_CONTAINER_LIVE_IMAGE` names an image other than `localhost/tokenbook-dev:latest`.
2. Spawn a real tokenbook scout and, while it works, inspect its container from the host, where `<name>` is the `container=` value in `state/<id>.meta`; the double quotes let the host's own `$HOME` expand:

   ```sh
   podman exec <name> sh -c "ls -A $HOME; ls -A $HOME/Projects; ls -A $HOME/Projects/firstmate; ls -A $HOME/Projects/firstmate/state; ls -A $HOME/Projects/firstmate/projects/tokenbook; test ! -e $HOME/.claude && test ! -e $HOME/Work && echo absent"
   podman inspect <name> --format '{{.HostConfig.NetworkMode}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{json .Mounts}}'
   ```

   The home must hold only `.firstmate` and `Projects`, `Projects` only `firstmate`, `firstmate` only `.agents`, `data`, `projects`, and `state`, `state` only `operational-inbox`, `<id>.inbox`, and `<id>.status`, the tokenbook directory only `.git` (its object store), and the command must print `absent`; `podman inspect` must show `none`, `true`, every capability dropped, and exactly the mounts in the table above.
3. In that scout, confirm Claude reached its composer without a login, onboarding, trust, or permission dialog, that a turn completed (the task's `state/<id>.busy-state` went busy and back to idle, and `state/<id>.turn-ended` was touched), and that the proxy log lists only allowed hosts.
   Ask it to run `curl https://example.com` and confirm the proxy refuses it.
4. Check the lifecycle on that scout: steer it with `bin/fm-send.sh` and watch the message move to `handled/`, interrupt it and exit it with `bin/fm-control.sh`, relaunch it, and tear it down; afterwards `podman ps -a --filter label=io.firstmate.task=<id>` must list nothing and `podman volume ls` must still list `fm-cargo-tokenbook`.
   While `podman top <name> comm args` lists `claude`, the steer must ring the doorbell rather than report that the agent has exited, and the interrupt must report `verified=agent-alive`; the exit must report `stopped`, and the relaunch must confirm its new agent.
   Before the exit, `podman exec <name> date` must print the host's local time and zone.
   After the teardown, `~/.firstmate/session-archive/<home-tag>/<id>/projects/` must hold the scout's `<session-id>.jsonl` transcript, mode `600` in directories mode `700`.
5. Check [host-side delivery](#host-side-delivery) with a real tokenbook ship on `luakso/tokenbook`: spawn a small `direct-PR` ship, such as a one-line README change, and let it report its ready branch.
   While its container runs, `podman exec <name> sh -c 'git ls-remote origin; curl -sS https://github.com'` must fail, and the proxy log must record `refused github.com:443`.
   Then run the delivery with canaries for the project's tools ahead of the real ones on `PATH`:

   ```sh
   canary=$(mktemp -d); for t in cargo rustc rustup lefthook podman no-mistakes; do printf '#!/bin/sh\necho "$0 $*" >> %s/ran\n' "$canary" > "$canary/$t"; chmod +x "$canary/$t"; done
   PATH="$canary:$PATH" bin/fm-container-deliver.sh <id>
   ```

   It must exit 0 and append one `done: PR <url> ...` line, `$canary/ran` must not exist, and `gh-axi pr view <number> --repo luakso/tokenbook` must print `draft: no` with the worker's evidence and commit list in the body.
   `bin/fm-crew-state.sh <id>` must then read `done` on that line, and `bin/fm-pr-check.sh <id> <url>` must register it.
   If the repository has CI, also check a failing round: have the worker commit a deliberately failing test, deliver again, and confirm the `blocked: ... checks failed` line, the failed-job log in `<task-dir>/container/ci-failures.md`, and that a fixed redelivery updates the same PR.
   Finally, deliver once more with a commit that adds `.github/workflows/x.yml` and confirm the refusal names that path and pushes nothing.

Steps 1 to 4 and the portable suites (`tests/fm-container-runtime.test.sh`, `tests/fm-container-deliver.test.sh`) cover everything else; step 5 is the only proof of these, because the suites use a local remote and a fake `gh-axi`:

- the push reaching the private repository with the host's own git credentials;
- the real `gh-axi` output the script reads: the PR URL from `pr create` and `pr list`, the `draft:` field, and the `pr checks` exit codes and summary line;
- a real contained worker following the delivery brief: running its checks, writing evidence for its final commit, and reporting a ready branch the named-head gate accepts;
- that no project tool or hook runs on the host against a real tokenbook clone.

Record the dated results, with the Podman, passt, and Claude Code versions, in [`docs/verification/runtime-backends.md`](verification/runtime-backends.md) once they have run.
