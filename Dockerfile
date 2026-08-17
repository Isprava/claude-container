FROM node:22-bookworm

# The container user mirrors the host user: same name, same uid, same absolute
# home path, so every absolute path in ~/.claude.json, settings.json, and MCP
# env vars resolves identically inside and out. run.sh passes these as
# --build-arg from `id -un` / `id -u` / $HOME; the defaults below only exist so
# a bare `docker build` still works.
ARG SANDBOX_USER=sandbox
ARG SANDBOX_UID=501
ARG SANDBOX_HOME=/home/sandbox
ENV SANDBOX_USER=${SANDBOX_USER}
ENV SANDBOX_HOME=${SANDBOX_HOME}

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

# Shared libraries Chromium needs to launch, for Playwright browser tests
# (`playwright install` downloads the browser but not these). Without them
# headless_shell dies with "error while loading shared libraries: libnspr4.so".
# Equivalent to `playwright install-deps chromium`, pinned here so it doesn't
# depend on a project's Playwright version or need root at test time.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libnspr4 libnss3 libatk1.0-0 libatk-bridge2.0-0 libatspi2.0-0 \
      libcups2 libdbus-1-3 libdrm2 libgbm1 libxkbcommon0 libxcomposite1 \
      libxdamage1 libxfixes3 libxrandr2 libpango-1.0-0 libcairo2 libasound2 \
      fonts-liberation fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

# Chromium itself, baked into the image so browser tests work with no download
# — including under --block-net, where a runtime `playwright install` can't
# reach the CDN. Browsers live in /opt/ms-playwright-base; entrypoint.sh seeds
# them into PLAYWRIGHT_BROWSERS_PATH (a host-persisted mount) on first run, so
# a project needing a different Playwright version can install alongside them
# and have that persist too. Bump PLAYWRIGHT_VERSION to refresh the baked set.
ARG PLAYWRIGHT_VERSION=1.62.1
RUN PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright-base PLAYWRIGHT_SKIP_BROWSER_GC=1 \
      npx --yes playwright@${PLAYWRIGHT_VERSION} install chromium ffmpeg \
    && chmod -R a+rX /opt/ms-playwright-base \
    && rm -rf /root/.npm
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright

# Playwright globally: the npm package so ad-hoc scripts can `require("playwright")`
# from any directory without a local node_modules (NODE_PATH makes the global
# install resolvable), and @playwright/mcp so Claude has browser tools in every
# project. Both are baked rather than npx'd because npx can't reach the registry
# under --block-net. Note the ecc plugin's own "playwright" MCP runs with
# --extension, which drives host Chrome over the browser extension bridge and so
# cannot work in here — this one drives the container's headless Chromium.
ARG PLAYWRIGHT_MCP_VERSION=0.0.79
RUN npm install -g playwright@${PLAYWRIGHT_VERSION} @playwright/mcp@${PLAYWRIGHT_MCP_VERSION} \
    && rm -rf /root/.npm
ENV NODE_PATH=/usr/local/lib/node_modules
ENV PLAYWRIGHT_SKIP_BROWSER_GC=1

# @playwright/mcp bundles its OWN nested Playwright, pinned to a different
# version than the one above, and Playwright ties each release to an exact
# browser revision — so the MCP server would otherwise start up, find only the
# other revision, and try to download chromium-1237 at runtime (which fails
# outright under --block-net). Install whatever revision the nested copy asks
# for, driven by its own CLI so the two stay in lockstep when either version is
# bumped. Both revisions coexist in the base dir; the stamp covers both, so
# bumping either version re-seeds the persisted cache.
#
# PLAYWRIGHT_SKIP_BROWSER_GC is essential here and at runtime: `playwright
# install` garbage-collects revisions its own version doesn't reference, so
# without it this step deletes the browsers the layer above just installed —
# and at runtime any project running `playwright install` would wipe revisions
# the MCP server and other projects still depend on from the shared cache.
RUN PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright-base PLAYWRIGHT_SKIP_BROWSER_GC=1 \
      node /usr/local/lib/node_modules/@playwright/mcp/node_modules/playwright/cli.js \
      install chromium ffmpeg \
    && echo "${PLAYWRIGHT_VERSION}+mcp${PLAYWRIGHT_MCP_VERSION}" \
         > /opt/ms-playwright-base/.pw-version \
    && chmod -R a+rX /opt/ms-playwright-base \
    && rm -rf /root/.npm /root/.cache

# MCP config for the headless browser server, kept in /etc rather than in
# ~/.claude.json: that file is a live bind mount of the host's, so writing to it
# would push a container-only server into every session on the Mac too.
# entrypoint.sh passes this to claude with --mcp-config, which is additive.
#
# --headless is load-bearing, not cosmetic: with it Playwright resolves the
# bundled chromium to the headless_shell binary, and headed Chrome's crashpad
# handler dies with SIGTRAP on aarch64 in here. --browser only accepts
# chrome/chromium/firefox/webkit/msedge, so the shell cannot be named directly
# (naming it falls through to system Chrome at /opt/google/chrome). Prefer
# headless in scripts too — plain chromium.launch() already picks the shell.
RUN mkdir -p /etc/claude && printf '%s\n' \
      '{' \
      '  "mcpServers": {' \
      '    "playwright-headless": {' \
      '      "command": "playwright-mcp",' \
      '      "args": ["--headless", "--isolated", "--browser", "chromium"]' \
      '    }' \
      '  }' \
      '}' \
      > /etc/claude/mcp-playwright.json

# uv/uvx for python-based MCP servers (jira / mcp-atlassian, eks)
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# bun — required by claude-mem plugin hooks
RUN curl -fsSL https://bun.sh/install | env BUN_INSTALL=/usr/local bash

RUN npm install -g @anthropic-ai/claude-code

# ccstatusline: the host runs it via `npx -y ccstatusline@latest`, which in here
# would re-download on every fresh container and fail outright under
# --block-net (the npx cache lives in ~/.npm, which is not a host mount). Bake
# it in so the statusline renders instantly and offline; ~/.claude/settings.json
# prefers this binary and falls back to npx on the Mac, where it is not global.
ARG CCSTATUSLINE_VERSION=2.2.27
RUN npm install -g ccstatusline@${CCSTATUSLINE_VERSION} && rm -rf /root/.npm

# See the SANDBOX_* args at the top: same name/uid/home as the host user.
RUN useradd -m -u ${SANDBOX_UID} -d ${SANDBOX_HOME} -s /bin/zsh ${SANDBOX_USER}

# Container-local rbenv + Ruby (host ~/.rbenv is macOS binaries — unusable
# here). Installed as the sandbox user so gem installs work without sudo. Gems
# land in BUNDLE_PATH, which run.sh persists on the host across containers.
USER ${SANDBOX_USER}
RUN git clone --depth 1 https://github.com/rbenv/rbenv.git ${SANDBOX_HOME}/.rbenv \
    && git clone --depth 1 https://github.com/rbenv/ruby-build.git ${SANDBOX_HOME}/.rbenv/plugins/ruby-build \
    && ${SANDBOX_HOME}/.rbenv/bin/rbenv install 3.4.1 \
    && ${SANDBOX_HOME}/.rbenv/bin/rbenv global 3.4.1 \
    && RBENV_VERSION=3.4.1 ${SANDBOX_HOME}/.rbenv/shims/gem install bundler -v 2.6.7 \
    && ${SANDBOX_HOME}/.rbenv/bin/rbenv rehash
USER root
ENV PATH=${SANDBOX_HOME}/.rbenv/shims:${SANDBOX_HOME}/.rbenv/bin:$PATH
ENV BUNDLE_PATH=${SANDBOX_HOME}/.cache/bundle

# Go toolchain (scrum-updates et al). Version matches the project's go.mod;
# GOTOOLCHAIN=auto (the default) fetches a newer patch release into GOPATH if
# a go.mod ever requires one. GOPATH ($SANDBOX_HOME/go) is a host-persisted
# mount at runtime — see run.sh — so module downloads survive across runs.
ARG GO_VERSION=1.25.7
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz" \
    | tar -C /usr/local -xz
ENV PATH=/usr/local/go/bin:${SANDBOX_HOME}/go/bin:$PATH

# Login shells (run.sh --shell, and anything spawning `bash -l`) source
# /etc/profile, which overwrites PATH with a bare default and drops rbenv, Go,
# and the global npm bin. Re-add them here so interactive shells see the same
# toolchain the ENV PATH above gives the claude process.
RUN printf '%s\n' \
      "export PATH=\"/usr/local/go/bin:${SANDBOX_HOME}/go/bin:${SANDBOX_HOME}/.rbenv/shims:${SANDBOX_HOME}/.rbenv/bin:\$PATH\"" \
      > /etc/profile.d/10-sandbox-path.sh

# air — live-reload runner used by scrum-updates' `make run`. Installed to
# /usr/local/bin so the runtime GOPATH mount can't shadow it.
RUN GOFLAGS=-modcacherw GOPATH=/tmp/gopath GOBIN=/usr/local/bin \
      /usr/local/go/bin/go install github.com/air-verse/air@latest \
    && rm -rf /tmp/gopath

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
# drops to the sandbox user via setpriv before exec'ing claude.
ENV HOME=${SANDBOX_HOME}
ENV DISABLE_AUTOUPDATER=1
ENV IS_SANDBOX=1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
