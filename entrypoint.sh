#!/usr/bin/env bash
# Runs as root: sets up host port forwards (and optionally the egress
# firewall), then drops privileges to the normal user and starts Claude.
# SANDBOX_USER/SANDBOX_HOME come from the image (see the Dockerfile ARGs) and
# mirror the host user, so nothing here hardcodes a username.
SANDBOX_USER="${SANDBOX_USER:-sandbox}"

# Forward localhost service ports to the Mac host so the container reaches the
# host's local Postgres/Redis/Rails — nothing is installed in the container.
# Override with e.g. -e FORWARD_PORTS="5432 6379 3000 8080" on docker run.
for port in ${FORWARD_PORTS:-5432 6379 3000 6400 8500}; do
  socat "TCP-LISTEN:${port},fork,reuseaddr,bind=127.0.0.1" "TCP:host.docker.internal:${port}" >/dev/null 2>&1 &
done

# GitHub CLI: run.sh bind-mounts the host's ~/.config/gh read-only at
# .config/gh-host. Copy it to a writable container-local ~/.config/gh so gh can
# update its own config without touching (or corrupting) the host's, and force
# git_protocol=https — there is no ssh in this image.
if [ -d "$HOME/.config/gh-host" ]; then
  mkdir -p "$HOME/.config/gh"
  cp -f "$HOME/.config/gh-host"/*.yml "$HOME/.config/gh/" 2>/dev/null || true
  sed -i 's/^\( *\)git_protocol: *ssh *$/\1git_protocol: https/' \
    "$HOME/.config/gh/hosts.yml" "$HOME/.config/gh/config.yml" 2>/dev/null || true
  chmod 700 "$HOME/.config/gh"; chmod 600 "$HOME/.config/gh"/*.yml 2>/dev/null || true
  chown -R "$SANDBOX_USER:$SANDBOX_USER" "$HOME/.config/gh"
fi

# Playwright: the image bakes Chromium into /opt/ms-playwright-base, while
# PLAYWRIGHT_BROWSERS_PATH is a host-persisted mount (run.sh: playwright-cache)
# so browsers a project installs for a different Playwright version survive
# across runs. Seed the baked browsers in once — cp -n never clobbers what's
# already there, and the stamp keeps restarts from re-walking ~10k files.
PW_BASE=/opt/ms-playwright-base
PW_DIR="${PLAYWRIGHT_BROWSERS_PATH:-/opt/ms-playwright}"
if [ -d "$PW_BASE" ]; then
  mkdir -p "$PW_DIR"
  PW_STAMP="$PW_DIR/.seeded-$(cat "$PW_BASE/.pw-version" 2>/dev/null || echo unknown)"
  if [ ! -f "$PW_STAMP" ]; then
    cp -an "$PW_BASE"/. "$PW_DIR"/ 2>/dev/null || true
    touch "$PW_STAMP"
    chown -R "$SANDBOX_USER:$SANDBOX_USER" "$PW_DIR" 2>/dev/null || true
  else
    chown "$SANDBOX_USER:$SANDBOX_USER" "$PW_DIR" 2>/dev/null || true
  fi
fi

if [ "${BLOCK_EGRESS:-0}" = "1" ]; then
  /usr/local/bin/init-firewall.sh
fi

# SANDBOX_SHELL=1 (run.sh --shell) drops into a shell instead of Claude, but
# still as the sandbox user and still after the setup above — so the port forwards
# and gh login are in place there too.
if [ "${SANDBOX_SHELL:-0}" = "1" ]; then
  if [ "$#" -gt 0 ]; then
    exec setpriv "--reuid=$SANDBOX_USER" "--regid=$SANDBOX_USER" --init-groups bash -lc "$*"
  fi
  exec setpriv "--reuid=$SANDBOX_USER" "--regid=$SANDBOX_USER" --init-groups bash -l
fi

# --mcp-config is additive (not --strict-mcp-config), so this adds the headless
# browser server on top of whatever ~/.claude.json and plugins already define.
MCP_OPTS=()
[ -f /etc/claude/mcp-playwright.json ] && \
  MCP_OPTS=(--mcp-config /etc/claude/mcp-playwright.json)

exec setpriv "--reuid=$SANDBOX_USER" "--regid=$SANDBOX_USER" --init-groups \
  claude --dangerously-skip-permissions \
  ${MCP_OPTS[@]+"${MCP_OPTS[@]}"} "$@"
