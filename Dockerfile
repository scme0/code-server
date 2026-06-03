# ---- builder ----
FROM node:22-bookworm-slim AS builder

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends curl ca-certificates gnupg && \
    rm -rf /var/lib/apt/lists/*

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

# claude-code CLI — isolated prefix so we don't copy npm/corepack into prod
RUN npm install -g @anthropic-ai/claude-code --prefix /opt/claude --silent && \
    npm cache clean --force

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
    apt-get install -y -qq --no-install-recommends \
      curl ca-certificates openssh-client git zsh tmux fzf zoxide jq && \
    rm -rf /var/lib/apt/lists/*

# claude-code modules (uses code-server's bundled node — no second node binary needed)
COPY --from=builder /opt/claude/lib/node_modules /usr/local/lib/node_modules
COPY --from=builder /opt/claude/bin/claude /usr/local/bin/claude

# code-server
COPY --from=builder /usr/lib/code-server /usr/lib/code-server
COPY --from=builder /usr/bin/code-server /usr/bin/code-server

# binaries
COPY --from=builder /usr/local/bin/ttyd /usr/local/bin/ttyd
COPY --from=builder /usr/local/bin/kubectl /usr/local/bin/kubectl
COPY --from=builder /usr/local/bin/chezmoi /usr/local/bin/chezmoi
COPY --from=builder /usr/bin/op /usr/local/bin/op
COPY --from=builder /usr/bin/gh /usr/local/bin/gh

# scripts
COPY mobile-controller.js /usr/local/lib/mobile-controller.js
COPY start-ttyd.sh /usr/local/bin/start-ttyd.sh
COPY k8s-run /usr/local/bin/k8s-run
COPY tmux.conf /etc/tmux.conf
COPY zshrc /etc/zsh/zshrc
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
