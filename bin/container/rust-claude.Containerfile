# Worker image for Firstmate's container runtime level (docs/container-runtime.md):
# a pinned Rust toolchain, the cargo-deny, cargo-nextest, and cargo-machete
# cargo tools, the lefthook and gitleaks guardrail tools, Claude Code, and git,
# plus the small in-container contract bin/fm-container-lib.sh relies on
# (/usr/bin/tini as PID 1, /bin/sh, socat for the loopback proxy bridge, tzdata
# for the host zone the launch passes as TZ, and a world-writable /cargo for
# the project's cargo cache volume).
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
ARG CARGO_NEXTEST_VERSION
ARG CARGO_MACHETE_VERSION
ARG LEFTHOOK_VERSION
ARG GITLEAKS_VERSION

RUN test -n "$RUST_TOOLCHAIN" && test -n "$CLAUDE_CODE_VERSION" && test -n "$CARGO_DENY_VERSION" \
  && test -n "$CARGO_NEXTEST_VERSION" && test -n "$CARGO_MACHETE_VERSION" \
  && test -n "$LEFTHOOK_VERSION" && test -n "$GITLEAKS_VERSION" \
  || { echo "RUST_TOOLCHAIN, CLAUDE_CODE_VERSION, CARGO_DENY_VERSION, CARGO_NEXTEST_VERSION, CARGO_MACHETE_VERSION, LEFTHOOK_VERSION and GITLEAKS_VERSION are required build arguments" >&2; exit 1; }

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl git pkg-config socat tini tzdata \
  && rm -rf /var/lib/apt/lists/*

ENV RUSTUP_HOME=/opt/rustup \
    PATH=/opt/cargo/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | env CARGO_HOME=/opt/cargo sh -s -- -y --no-modify-path --profile minimal \
      --default-toolchain "$RUST_TOOLCHAIN" --component clippy --component rustfmt \
  && CARGO_HOME=/opt/cargo cargo install --locked --root /usr/local "cargo-deny@$CARGO_DENY_VERSION" \
    "cargo-nextest@$CARGO_NEXTEST_VERSION" "cargo-machete@$CARGO_MACHETE_VERSION" \
  && rm -rf /opt/cargo/registry /opt/cargo/git \
  && chmod -R a+rX /opt/rustup /opt/cargo

RUN npm install -g "@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION" "lefthook@$LEFTHOOK_VERSION" \
  && npm cache clean --force

# gitleaks ships as a release binary, checked against its release's checksums.
RUN case "$(dpkg --print-architecture)" in \
    amd64) gitleaks_arch=x64 ;; \
    arm64) gitleaks_arch=arm64 ;; \
    *) echo "gitleaks publishes no Linux build for $(dpkg --print-architecture)" >&2; exit 1 ;; \
  esac \
  && cd /tmp \
  && gitleaks_url="https://github.com/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSION" \
  && gitleaks_tar="gitleaks_${GITLEAKS_VERSION}_linux_${gitleaks_arch}.tar.gz" \
  && curl --proto '=https' --tlsv1.2 -fsSLO "$gitleaks_url/$gitleaks_tar" \
  && curl --proto '=https' --tlsv1.2 -fsSL -o gitleaks-checksums.txt "$gitleaks_url/gitleaks_${GITLEAKS_VERSION}_checksums.txt" \
  && grep -F "  $gitleaks_tar" gitleaks-checksums.txt | sha256sum -c - \
  && tar -xzf "$gitleaks_tar" -C /usr/local/bin gitleaks \
  && rm -f "$gitleaks_tar" gitleaks-checksums.txt \
  && gitleaks version

RUN mkdir -m 1777 /cargo
ENV CARGO_HOME=/cargo

LABEL io.firstmate.container-runtime="1"
ENTRYPOINT ["/usr/bin/tini", "--"]
