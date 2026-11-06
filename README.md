# claude-box

Run the Claude Code CLI inside a Docker container. The container sees **only** the current
directory and your Claude config (global `CLAUDE.md`, settings, skills, agents, auto-memory,
sessions, credentials). Everything else on the host is invisible. All CLI arguments pass
straight through, so `claude-box --resume`, `claude-box -c`, `claude-box -p "..."` behave like `claude`.

## Setup

Needs Docker (Linux), Docker Desktop (macOS / Windows, Linux containers).

```sh
git clone <this repo> ~/claude-box && ~/claude-box/install.sh          # Linux / macOS
```
```powershell
git clone <this repo> $HOME\claude-box; & $HOME\claude-box\install.ps1  # Windows
```

The first run builds the image (a few minutes). After that it starts instantly.

## How it works

- **Same CLI version**: the image installs the version `claude --version` reports on the host
  (or `latest` if there's no host CLI). Auto-update is off inside the container. When the host CLI
  updates, the next run builds a matching image.
- **Same paths** (Linux/macOS): CWD and config are mounted at their real host paths, and the
  container user has your uid/gid/home, so session files and memory are shared 1:1 with the host CLI.
- **Windows**: `C:\Users\me\proj` shows up as `/c/Users/me/proj`. The project's session/memory dir
  (`projects\C--Users-me-proj`) is mounted over the container's name for it, so `--resume`/`--continue`
  still share sessions with native Windows `claude`.
- Config: `~/.claude` + `~/.claude.json`, or `$CLAUDE_CONFIG_DIR` if set. Top-level symlinks in the
  config dir, `@/abs` / `@~/` imports in the global `CLAUDE.md`, and a custom `autoMemoryDirectory`
  are followed and mounted too (Linux/macOS).
- The user has passwordless `sudo` inside the container. Changes vanish when it exits (`--rm`).

## Global package list

`~/.config/claude-box/packages` (Windows: `%APPDATA%\claude-box\packages`) lists the Debian apt
packages in every container. Edit it and the next run rebuilds automatically.
For anything apt can't do, put a script at `setup.sh` next to it. It runs as root at build time.

## Knobs (env vars)

| var | effect |
|---|---|
| `CLAUDE_BOX_MOUNTS` | extra host paths to mount (space-separated; `;` on Windows) |
| `CLAUDE_BOX_ENV` | extra env var names to pass through |
| `CLAUDE_BOX_DOCKER_ARGS` | extra `docker run` args, e.g. `--network none` or `--gpus all` |
| `CLAUDE_BOX_VERSION` | pin a Claude Code version |
| `CLAUDE_BOX_CONFIG` | alternative dir for `packages` / `setup.sh` |

`claude-box --box-rebuild ...` forces an image rebuild. Old images: `docker image prune` / `docker rmi claude-box:<tag>`.

## Caveats

- Hooks, MCP servers and status lines in your settings that point at host-only programs or paths
  will fail inside the container. Mount them or add the tools via `packages`/`setup.sh`.
- Only CWD is mounted. Running from a repo subdirectory hides the repo's `.git`, so run from the repo root.
- Claude's own Bash sandbox (bubblewrap) doesn't work inside Docker. The container is the sandbox.
