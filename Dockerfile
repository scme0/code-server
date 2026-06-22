# ---- builder ----
FROM node:22-bookworm-slim AS builder

RUN apt-get update -qq && \
    apt-get upgrade -y -qq && \
    apt-get install -y -qq --no-install-recommends curl ca-certificates gnupg xz-utils && \
    rm -rf /var/lib/apt/lists/*

# git — build current from source. Bookworm apt ships 2.39; build deps stay in the
# builder, only the compiled tree (+ a few runtime libs) lands in prod.
RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
      build-essential perl libssl-dev libcurl4-openssl-dev libexpat1-dev gettext zlib1g-dev && \
    GIT_VER=2.54.0 && \
    curl -fsSL "https://www.kernel.org/pub/software/scm/git/git-${GIT_VER}.tar.xz" -o /tmp/git.tar.xz && \
    mkdir -p /tmp/git && tar -xJf /tmp/git.tar.xz -C /tmp/git --strip-components=1 && \
    make -C /tmp/git prefix=/usr/local NO_TCLTK=1 -j"$(nproc)" all && \
    make -C /tmp/git prefix=/usr/local NO_TCLTK=1 DESTDIR=/tmp/gitroot install && \
    rm -rf /tmp/git /tmp/git.tar.xz /var/lib/apt/lists/*

# fzf + zoxide + jq — current upstream binaries. Bookworm apt ships fzf 0.38 (no `--zsh`),
# zoxide 0.4.3 (whose `cd` wrapper recurses; see dotfiles _z_cd note), and jq 1.6.
RUN ARCH=$(dpkg --print-architecture) && \
    FZF_VER=$(curl -s https://api.github.com/repos/junegunn/fzf/releases/latest \
      | grep '"tag_name"' | head -1 | cut -d'"' -f4 | sed 's/^v//') && \
    curl -sL "https://github.com/junegunn/fzf/releases/download/v${FZF_VER}/fzf-${FZF_VER}-linux_${ARCH}.tar.gz" \
      | tar xz -C /usr/local/bin fzf && \
    JQ_VER=$(curl -s https://api.github.com/repos/jqlang/jq/releases/latest \
      | grep '"tag_name"' | head -1 | cut -d'"' -f4 | sed 's/^jq-//') && \
    curl -sL "https://github.com/jqlang/jq/releases/download/jq-${JQ_VER}/jq-linux-${ARCH}" \
      -o /usr/local/bin/jq && chmod +x /usr/local/bin/jq && \
    curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh \
      | sh -s -- --bin-dir /usr/local/bin

# code-server
RUN curl -fsSL https://code-server.dev/install.sh | sh

# ttyd (arch-aware)
RUN TTYD_VER=$(curl -s https://api.github.com/repos/tsl0922/ttyd/releases/latest \
      | grep '"tag_name"' | head -1 | cut -d'"' -f4) && \
    ARCH=$(uname -m) && \
    curl -sLo /usr/local/bin/ttyd \
      "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VER}/ttyd.${ARCH}" && \
    chmod +x /usr/local/bin/ttyd

# kubectl (arch-aware)
RUN KUBECTL_VER=$(curl -sL https://dl.k8s.io/release/stable.txt) && \
    ARCH=$(dpkg --print-architecture) && \
    curl -sLo /usr/local/bin/kubectl \
      "https://dl.k8s.io/release/${KUBECTL_VER}/bin/linux/${ARCH}/kubectl" && \
    chmod +x /usr/local/bin/kubectl

# claude-code CLI — native installer (self-updating standalone binary; needs no
# node at runtime). Installed under HOME=/data/home so the launcher's ABSOLUTE
# symlink (~/.local/bin/claude -> ~/.local/share/claude/versions/<v>) resolves at
# runtime, where HOME=/data/home too. The tree is staged at /opt/claude-bootstrap;
# common-init.sh copies it into the persisted ~/.local on first boot. (It is NOT
# fetched at runtime: the init container has no egress, and we must not put a
# second claude on PATH or `claude update` trips its multi-install warning.)
#
# CLAUDE_VERSION pins the installed version. BUMP IT to ship a new claude: an
# explicit version makes the build reproducible AND busts Docker's layer cache for
# this RUN (a bare `stable` would be evaluated once then cached forever, freezing
# the version across rebuilds). On locked deploys (CLAUDE_PIN_TO_IMAGE=1) this baked
# version is the ONLY update path, since runtime `claude update` has no GCS egress.
ARG CLAUDE_VERSION=2.1.185
RUN export HOME=/data/home && mkdir -p "$HOME" && \
    curl -fsSL https://claude.ai/install.sh | bash -s -- "$CLAUDE_VERSION" && \
    mkdir -p /opt/claude-bootstrap && \
    mv "$HOME/.local" /opt/claude-bootstrap/.local && \
    rm -rf "$HOME"

# chezmoi
RUN sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /usr/local/bin

# gh CLI (via official apt repo)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
    gpg --dearmor -o /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    ARCH=$(dpkg --print-architecture) && \
    echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# 1Password CLI (via official apt repo)
RUN curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
    gpg --dearmor -o /usr/share/keyrings/1password-archive-keyring.gpg && \
    ARCH=$(dpkg --print-architecture) && \
    echo "deb [arch=${ARCH} signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/${ARCH} stable main" \
      > /etc/apt/sources.list.d/1password.list && \
    apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends 1password-cli && \
    rm -rf /var/lib/apt/lists/*

# ---- prod ----
FROM debian:bookworm-slim

RUN apt-get update -qq && \
    apt-get upgrade -y -qq && \
    apt-get install -y -qq --no-install-recommends \
      curl ca-certificates openssh-client zsh tmux python3 python3-pip \
      libcurl4 libexpat1 zlib1g gettext-base perl && \
    rm -rf /var/lib/apt/lists/*

# claude-code native install, staged for common-init.sh to seed into the persisted
# ~/.local on first boot. Deliberately NOT placed on PATH here: a /usr/local/bin
# copy would collide with the user's self-updating ~/.local/bin/claude and trip the
# "multiple installations found" warning. /data is masked by the PVC at runtime, so
# the install can't be baked there directly — init copies it out of /opt instead.
COPY --from=builder /opt/claude-bootstrap /opt/claude-bootstrap

# code-server
COPY --from=builder /usr/lib/code-server /usr/lib/code-server
COPY --from=builder /usr/bin/code-server /usr/bin/code-server

# binaries
COPY --from=builder /usr/local/bin/ttyd /usr/local/bin/ttyd
COPY --from=builder /usr/local/bin/kubectl /usr/local/bin/kubectl
COPY --from=builder /usr/local/bin/chezmoi /usr/local/bin/chezmoi
COPY --from=builder /usr/bin/op /usr/local/bin/op
COPY --from=builder /usr/bin/gh /usr/local/bin/gh
COPY --from=builder /usr/local/bin/fzf /usr/local/bin/fzf
COPY --from=builder /usr/local/bin/zoxide /usr/local/bin/zoxide
COPY --from=builder /usr/local/bin/jq /usr/local/bin/jq
# git (built from source in builder; whole install tree → /usr/local)
COPY --from=builder /tmp/gitroot/usr/local/ /usr/local/

# scripts
COPY mobile-controller.js /usr/local/lib/mobile-controller.js
COPY start-ttyd.sh /usr/local/bin/start-ttyd.sh
COPY k8s-run /usr/local/bin/k8s-run
COPY tmux.conf /etc/tmux.conf
COPY zshrc /etc/zsh/zshrc
# sandbox-specific Claude skills (common-init.sh copies these into ~/.claude*/skills)
COPY skills/ /etc/claude-skills/
# Managed Claude settings, baked into the image: read fresh on every launch and
# deep-merged UNDER the user's persisted ~/.claude/settings.json (Claude's own
# settings precedence). Replaces the old per-boot config seeding — image/policy
# updates flow through without a reset, and user config is never overwritten.
# Per-deploy drop-ins go in /etc/claude-code/managed-settings.d/ (mounted by the
# deployment); home gets only this generic baseline.
COPY claude-managed-settings.json /etc/claude-code/managed-settings.json
RUN chmod +x /usr/local/bin/start-ttyd.sh /usr/local/bin/k8s-run

# Real Node.js from builder (includes npm/npx) — code-server's bundled node is not a full install
COPY --from=builder /usr/local/bin/node /usr/local/bin/node
COPY --from=builder /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm && \
    ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

# workspace dir + non-root user
RUN groupadd -g 1000 node && useradd -u 1000 -g node -m node && \
    mkdir -p /data/workspace && chown node:node /data/workspace

USER node

ENV SHELL=/bin/zsh
