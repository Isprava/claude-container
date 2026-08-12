FROM node:22-bookworm

# Dev tooling for Claude Code + npx/uvx-based MCP servers. No SSH: openssh is
# explicitly purged so the container cannot ssh anywhere.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git ripgrep jq curl less procps ca-certificates fd-find vim nano zsh \
      python3 python3-pip socat iptables dnsutils unzip \
      build-essential autoconf bison patch \
      libssl-dev libyaml-dev libreadline-dev zlib1g-dev libgmp-dev \
      libffi-dev libgdbm-dev libncurses-dev uuid-dev \
      libpq-dev postgresql-client imagemagick shared-mime-info tzdata \
    && apt-get purge -y openssh-client openssh-server 2>/dev/null; \
    apt-get autoremove -y && rm -rf /var/lib/apt/lists/*

# uv/uvx for python-based MCP servers (jira / mcp-atlassian, eks)
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# bun — required by claude-mem plugin hooks
RUN curl -fsSL https://bun.sh/install | env BUN_INSTALL=/usr/local bash

RUN npm install -g @anthropic-ai/claude-code

# Same home path as the Mac host so all absolute paths in ~/.claude.json,
# settings.json, and MCP env vars resolve identically inside the container.
RUN useradd -m -u 501 -d /Users/manthan -s /bin/zsh manthan

# Container-local rbenv + Ruby (host ~/.rbenv is macOS binaries — unusable
# here). Installed as user manthan so gem installs work without sudo. Gems
# land in BUNDLE_PATH, which run.sh persists on the host across containers.
USER manthan
RUN git clone --depth 1 https://github.com/rbenv/rbenv.git /Users/manthan/.rbenv \
    && git clone --depth 1 https://github.com/rbenv/ruby-build.git /Users/manthan/.rbenv/plugins/ruby-build \
    && /Users/manthan/.rbenv/bin/rbenv install 3.4.1 \
    && /Users/manthan/.rbenv/bin/rbenv global 3.4.1 \
    && RBENV_VERSION=3.4.1 /Users/manthan/.rbenv/shims/gem install bundler -v 2.6.7 \
    && /Users/manthan/.rbenv/bin/rbenv rehash
USER root
ENV PATH=/Users/manthan/.rbenv/shims:/Users/manthan/.rbenv/bin:$PATH
ENV BUNDLE_PATH=/Users/manthan/.cache/bundle

# GitHub CLI from the official apt repo (Debian's gh is years old)
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# System-level git config so github.com HTTPS operations (clone/fetch/push)
# authenticate with gh's token, and any ssh:// or git@ GitHub remote is
# rewritten to HTTPS — the container has no ssh at all. Lives in /etc/gitconfig
# so the read-only host ~/.gitconfig mount (which sets neither key) still wins
# for user.name/email etc.
RUN printf '%b\n' \
      '[credential "https://github.com"]' \
      '\thelper = !gh auth git-credential' \
      '[credential "https://gist.github.com"]' \
      '\thelper = !gh auth git-credential' \
      '[url "https://github.com/"]' \
      '\tinsteadOf = git@github.com:' \
      '\tinsteadOf = ssh://git@github.com/' \
      > /etc/gitconfig

# No-op stubs for host-only tools that project hooks invoke (they'd
# otherwise spam "not found" hook errors inside the sandbox).
RUN printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/code-review-graph \
    && chmod +x /usr/local/bin/code-review-graph

COPY entrypoint.sh init-firewall.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/init-firewall.sh

# Entrypoint starts as root (needed for iptables in --block-net mode) and
# drops to user manthan via setpriv before exec'ing claude.
ENV HOME=/Users/manthan
ENV DISABLE_AUTOUPDATER=1
ENV IS_SANDBOX=1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
