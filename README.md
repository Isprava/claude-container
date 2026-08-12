# claude-container

Run Claude Code with `--dangerously-skip-permissions` safely, inside a Docker sandbox with no SSH and an optional egress firewall. The current project directory is bind-mounted at the same path inside the container, so all absolute paths (settings, MCP config, memory) resolve identically to the host.

## Files

| File | Purpose |
|---|---|
| `run.sh` | Launcher — builds the image if needed and starts the container from your project dir |
| `Dockerfile` | Image: Node 22 + Claude Code, Ruby 3.4.1 (rbenv), gh CLI, uv/uvx, bun, no openssh |
| `entrypoint.sh` | Runs as root inside the container: host port forwards (socat), gh config copy, optional firewall, then drops to the normal user and execs `claude` |
| `init-firewall.sh` | `--block-net` iptables rules: drop all egress except Anthropic/Claude hosts, GitHub, DNS, and the host port forwards |
| `shared/` | Read-write drop-box mounted into the container (screenshots, CSVs, dumps). Also holds two optional config files: `env-passthrough` (env vars to forward, one per line) and `extra-mounts` (extra host paths to bind-mount, one absolute path per line, `:ro` for read-only). Contents are git-ignored |
| `bundle-cache/` | Persists gems installed inside the container (`BUNDLE_PATH`) across runs. Git-ignored |
| `container-credentials.json` | The sandbox's own Claude OAuth login — created on first run, **never committed** |

## Prerequisites

- Docker (OrbStack preferred — `run.sh` pins the `orbstack` context if present; Docker Desktop works too)
- Host `gh` CLI logged in (`gh auth login`) if you want git/GitHub access inside the sandbox
- A Claude subscription/account for the sandbox's own login

## Setup

```sh
git clone <this-repo> ~/claude-container
cd ~/claude-container && chmod +x run.sh
```

Note: the scripts hardcode the home path `/Users/manthan` (host and container homes must match so absolute paths in `~/.claude.json` resolve). On another machine, replace it in `Dockerfile` and `run.sh` with your own home, including the uid on the `useradd` line (`id -u`).

First run builds the image (~10 min: it compiles Ruby):

```sh
cd ~/your-project
~/claude-container/run.sh
```

The sandbox keeps its **own** Claude login, deliberately separate from the host's macOS-Keychain session (a shared identity would log one side out whenever the other refreshes its token). On first run it starts logged out — run `/login` once inside the sandbox; it persists in `container-credentials.json` thereafter. Delete that file to reset.

## Usage

Run from the **root of any project**; that directory is mounted read-write and Claude starts there with permissions bypassed:

```sh
~/claude-container/run.sh                      # plain start
~/claude-container/run.sh -c                   # continue last session
~/claude-container/run.sh "fix failing specs"  # start with a prompt
~/claude-container/run.sh --block-net          # with egress firewall
~/claude-container/run.sh --shell              # bash shell instead of Claude
~/claude-container/run.sh --rebuild            # force docker image rebuild
```

Everything after `--` is passed straight to `claude`. Tip: alias it, e.g. `alias dangerous_claude=~/claude-container/run.sh`.

### Environment variables

```sh
FORWARD_PORTS="5432 6379 3000 8080" ~/claude-container/run.sh   # host ports reachable as localhost inside
ALLOWED_DOMAINS="api.anthropic.com claude.ai platform.claude.com registry.npmjs.org" \
  ~/claude-container/run.sh --block-net                          # replace the firewall allowlist
```

Default forwarded ports: `5432 6379 3000 6400 8500` (Postgres, Redis, Rails, etc.) — the container reaches the host's services at `localhost:<port>` via socat.

## What's shared with the host

- Current project dir (read-write, live bind mount)
- `~/.claude` (settings, plugins, skills, memory) and `~/.claude.json` (MCP servers)
- `~/.gitconfig` and `~/.config/gh` (both read-only; gh login is copied to a writable container-local config at startup, `git_protocol` forced to https, `git@github.com:`/ssh remotes auto-rewritten to HTTPS)
- Host Postgres/Redis/Rails via the port forwards
- `shared/` drop-box, `bundle-cache/` gems, and any paths listed in `shared/extra-mounts`
- Env vars listed in `shared/env-passthrough` — nothing else leaks in

`~/.claude-mem` is deliberately **not** shared (a container-spawned worker once corrupted the host's SQLite state); the sandbox gets its own ephemeral copy.

## What's blocked / missing

- **No SSH**: openssh is purged from the image and `~/.ssh` is never mounted — all git goes over HTTPS with gh's token
- With `--block-net`: all egress except Anthropic/Claude hosts, GitHub, DNS, and the host forwards (IPv6 egress dropped entirely). npx/uvx MCP servers and WebFetch to other sites won't work unless you extend `ALLOWED_DOMAINS`; claude.ai connectors (Jira/Notion/Slack via Anthropic's proxy) keep working
- Mac-binary MCP servers fail inside; Chrome browser tools need host Chrome
