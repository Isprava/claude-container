#!/usr/bin/env bash
# Launch Claude Code in a sandboxed container with --dangerously-skip-permissions.
# Run from the root of any project directory. See --help for all options.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE=claude-sandbox
PROJECT="$PWD"

# Pin to OrbStack regardless of the current docker context (Docker Desktop
# resets the default context to itself whenever it runs).
if [ -z "${DOCKER_CONTEXT:-}" ] && docker context inspect orbstack >/dev/null 2>&1; then
  export DOCKER_CONTEXT=orbstack
fi

usage() {
  cat <<'EOF'
claude-sandbox — Claude Code in a container (bypass permissions, no SSH)

USAGE
  ~/claude-container/run.sh [OPTIONS] [-- extra claude args]
  Run from the ROOT of a project; that directory is mounted into the
  container at the same path and Claude starts there.

OPTIONS
  --help, -h     Show this help and exit.
  --block-net    Egress firewall: drop ALL outgoing traffic except
                   - required Claude hosts (api.anthropic.com, claude.ai,
                     platform.claude.com, claude.com, mcp-proxy.anthropic.com)
                   - GitHub (github.com, api.github.com, codeload and
                     objects.githubusercontent.com) so `gh` and git work
                   - DNS and the host port forwards below
                 Blocks npx/uvx MCP servers, npm, WebFetch to other sites.
                 claude.ai connectors (Jira/Notion/Slack via Anthropic proxy)
                 keep working.
  --rebuild      Force rebuild of the docker image before starting.
  --shell        Open a bash shell in the container instead of Claude.

  Anything else is passed straight to claude, e.g.:
    run.sh -c                      # continue last session
    run.sh "fix the failing specs" # start with a prompt

ENVIRONMENT VARIABLES
  FORWARD_PORTS    Host ports reachable as localhost inside the container.
                   Default: "5432 6379 3000 6400"  (Postgres, Redis, Rails, 6400)
                   e.g. FORWARD_PORTS="5432 6379 3000 8080" run.sh
  ALLOWED_DOMAINS  With --block-net: replace the allowed-domain list.
                   e.g. ALLOWED_DOMAINS="api.anthropic.com claude.ai \
                        platform.claude.com registry.npmjs.org" run.sh --block-net

  ~/claude-container/shared/env-passthrough
                   Env vars given to the container — exactly what is
                   written in the file, nothing more. One per line:
                     KEY=value   passed as written
                     NAME        copies that one var from your Mac shell

  ~/claude-container/shared/extra-mounts
                   Extra host folders bind-mounted into the container at
                   the same path (live, no copying). One absolute path per
                   line; append :ro for read-only. # comments allowed:
                     /Users/manthan/Downloads/emails/email_dump
                     /Users/manthan/some/reference:ro

WHAT'S SHARED WITH THE HOST
  - Current project dir (read-write, live bind mount)
  - ~/claude-container/shared (read-write drop-box: put arbitrary files —
    screenshots, CSVs, dumps — here; visible at the same path inside)
  - ~/.claude (settings, plugins, skills, memory) and ~/.claude.json (MCP)
  - ~/.claude-mem is deliberately NOT shared: a container-spawned claude-mem
    worker once corrupted the host worker state/DB (locked SQLite, stale
    pid/port), blocking prompts on the host. The sandbox gets its own
    ephemeral claude-mem dir instead.
  - Folders listed in ~/claude-container/shared/extra-mounts (see above)
  - ~/.gitconfig (read-only)
  - ~/.config/gh (read-only) — the host's GitHub CLI login. It is copied to a
    writable container-local ~/.config/gh at startup, so `gh` inside never
    writes back to the host config. git_protocol is forced to https (no ssh
    in the image) and git is configured to authenticate GitHub HTTPS remotes
    with gh's token, so clone/fetch/push and `gh pr/issue/...` all work.
    git@github.com: and ssh:// GitHub remotes are auto-rewritten to HTTPS.
    If the host is not logged in, run `gh auth login` on the Mac.
  - The container's OWN Claude login (separate from the host; persists in
    container-credentials.json and self-maintains). The macOS Keychain is
    never read, so the host and sandbox never clobber each other's token.
    First run: `claude /login` once inside the sandbox to authenticate it.
  - Host Postgres/Redis/Rails via the FORWARD_PORTS socat forwards
  - ~/claude-container/bundle-cache: gems installed in the container
    (BUNDLE_PATH) persist here across runs
  - Env vars listed in shared/env-passthrough (see above)

RUBY
  - Image has its own Linux rbenv + Ruby 3.4.1 (host ~/.rbenv is macOS
    binaries and is never mounted). First "bundle install" in a project
    fills bundle-cache; later runs reuse it.

WHAT'S BLOCKED / MISSING
  - No SSH: openssh purged from image, ~/.ssh never mounted
  - Mac-binary MCP servers fail inside (postgres wrapper, pencil, signoz,
    pixelbyte-figma); Chrome browser tools need host Chrome

FILES
  ~/claude-container/Dockerfile              image definition
  ~/claude-container/entrypoint.sh           port forwards + starts claude
  ~/claude-container/init-firewall.sh        --block-net iptables rules
  ~/claude-container/container-credentials.json  sandbox's own Claude login
                                             (git-ignore this; delete to reset)
  ~/claude-container/shared/env-passthrough  env var names to forward
EOF
}

NET_OPTS=()
SHELL_OPTS=()
FORCE_BUILD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --block-net) NET_OPTS=(--cap-add NET_ADMIN -e BLOCK_EGRESS=1); shift ;;
    --rebuild) FORCE_BUILD=1; shift ;;
    --shell) SHELL_OPTS=(-e SANDBOX_SHELL=1); shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if [ "$FORCE_BUILD" = 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker build -t "$IMAGE" "$DIR"
fi

# The container keeps its OWN Claude login, fully separate from the host's
# (macOS Keychain) session. It lives in this file and self-maintains across
# runs — access-token refreshes and rotating refresh tokens persist here. We
# deliberately do NOT seed it from the Keychain: one shared identity means
# whichever env refreshes first rotates the other's refresh token into a dead
# state, logging that env out. Kept separate, neither env can clobber the other.
#
# First run: this file is empty, so the sandbox starts logged out — run
#   claude /login
# once INSIDE the sandbox (dangerous_claude) and it stays logged in thereafter.
# Re-auth later: /login inside again. Reset from scratch: delete this file.
CRED="$DIR/container-credentials.json"
[ -f "$CRED" ] || { echo '{}' > "$CRED"; chmod 600 "$CRED"; }
if ! python3 -c "import json,sys; sys.exit(0 if json.load(open('$CRED')).get('claudeAiOauth',{}).get('accessToken') else 1)" 2>/dev/null; then
  echo "claude-sandbox: container not logged in — run 'claude /login' once inside the sandbox." >&2
  echo "  (this login is separate from your host and persists in container-credentials.json)" >&2
fi

GITCONFIG_MOUNT=()
[ -f "$HOME/.gitconfig" ] && GITCONFIG_MOUNT=(-v "$HOME/.gitconfig:/Users/manthan/.gitconfig:ro")

# GitHub CLI: share the host's gh login read-only. entrypoint.sh copies it to a
# writable container-local ~/.config/gh (so gh never writes back to the host)
# and switches git_protocol to https, since the image has no ssh.
GH_MOUNT=()
if [ -d "$HOME/.config/gh" ]; then
  GH_MOUNT=(-v "$HOME/.config/gh:/Users/manthan/.config/gh-host:ro")
  if ! gh auth status >/dev/null 2>&1; then
    echo "claude-sandbox: host 'gh' is not logged in — run 'gh auth login' on the Mac to enable gh in the sandbox." >&2
  fi
fi

ENV_OPTS=()
[ -n "${FORWARD_PORTS:-}" ] && ENV_OPTS+=(-e "FORWARD_PORTS=$FORWARD_PORTS")
[ -n "${ALLOWED_DOMAINS:-}" ] && ENV_OPTS+=(-e "ALLOWED_DOMAINS=$ALLOWED_DOMAINS")

# Env vars for the container: shared/env-passthrough is a standard docker
# env file — KEY=value lines are passed as written (a bare NAME line copies
# that var from the invoking shell). Nothing else leaks in.
[ -f "$DIR/shared/env-passthrough" ] && ENV_OPTS+=(--env-file "$DIR/shared/env-passthrough")

# Extra bind mounts: shared/extra-mounts lists one absolute path per line,
# mounted read-write at the same path inside the container (append :ro for
# read-only). Blank lines and # comments are ignored; missing paths warn.
EXTRA_MOUNTS=()
if [ -f "$DIR/shared/extra-mounts" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"   # trim whitespace
    [ -z "$line" ] && continue
    mode=""
    case "$line" in *:ro) mode=":ro"; line="${line%:ro}" ;; esac
    if [ -e "$line" ]; then
      EXTRA_MOUNTS+=(-v "$line:$line$mode")
    else
      echo "warning: extra-mounts path not found, skipping: $line" >&2
    fi
  done < "$DIR/shared/extra-mounts"
fi

# NOTE: ~/.ssh is deliberately NOT mounted and openssh is not installed in the
# image — the container has no ssh capability.
exec docker run -it --rm \
  --name "claude-sandbox-$(basename "$PROJECT")-$$" \
  --add-host=host.docker.internal:host-gateway \
  ${NET_OPTS[@]+"${NET_OPTS[@]}"} \
  ${ENV_OPTS[@]+"${ENV_OPTS[@]}"} \
  ${SHELL_OPTS[@]+"${SHELL_OPTS[@]}"} \
  -v "$PROJECT:$PROJECT" \
  -v "$HOME/.claude:/Users/manthan/.claude" \
  -v "$HOME/.claude.json:/Users/manthan/.claude.json" \
  -v "$HOME/.config/ccstatusline:/Users/manthan/.config/ccstatusline:ro" \
  -v "$CRED:/Users/manthan/.claude/.credentials.json" \
  -v "$DIR/shared:/Users/manthan/claude-container/shared" \
  -v "$DIR/bundle-cache:/Users/manthan/.cache/bundle" \
  ${GITCONFIG_MOUNT[@]+"${GITCONFIG_MOUNT[@]}"} \
  ${GH_MOUNT[@]+"${GH_MOUNT[@]}"} \
  ${EXTRA_MOUNTS[@]+"${EXTRA_MOUNTS[@]}"} \
  -w "$PROJECT" \
  "$IMAGE" "$@"
