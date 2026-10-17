# Worker image for Firstmate's container runtime level (docs/container-runtime.md):
# a pinned Rust toolchain, cargo-deny, Claude Code, and git, plus the small
# in-container contract bin/fm-container-lib.sh relies on (/usr/bin/tini as
# PID 1, /bin/sh, socat for the loopback proxy bridge, and a world-writable
# /cargo for the project's cargo cache volume).
#
# It is generic and parameterised rather than per project, and it lives in
# Firstmate rather than in the project, so the agent the container holds can
# never edit the image that holds it. Every version is a required build
# argument; docs/container-runtime.md "Build the image" has the command, which
# reads RUST_TOOLCHAIN from the project's own rust-toolchain.toml.

ARG BASE_IMAGE=docker.io/library/node:22-bookworm-slim
FROM ${BASE_IMAGE}

ARG RUST_TOOLCHAIN
ARG CLAUDE_CODE_VERSION
ARG CARGO_DENY_VERSION

RUN test -n "$RUST_TOOLCHAIN" && test -n "$CLAUDE_CODE_VERSION" && test -n "$CARGO_DENY_VERSION" \
  || { echo "RUST_TOOLCHAIN, CLAUDE_CODE_VERSION and CARGO_DENY_VERSION are required build arguments" >&2; exit 1; }

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git pkg-config socat tini \
  && rm -rf /var/lib/apt/lists/*

ENV RUSTUP_HOME=/opt/rustup \
    PATH=/opt/cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | env CARGO_HOME=/opt/cargo sh -s -- -y --no-modify-path --profile minimal \
      --default-toolchain "$RUST_TOOLCHAIN" --component clippy --component rustfmt \
  && CARGO_HOME=/opt/cargo cargo install --locked --root /usr/local "cargo-deny@$CARGO_DENY_VERSION" \
  && rm -rf /opt/cargo/registry /opt/cargo/git \
  && chmod -R a+rX /opt/rustup /opt/cargo

RUN npm install -g "@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION" \
  && npm cache clean --force

RUN mkdir -m 1777 /cargo
ENV CARGO_HOME=/cargo

LABEL io.firstmate.container-runtime="1"
ENTRYPOINT ["/usr/bin/tini", "--"]
