# claude-box

Run [Claude Code](https://claude.com/claude-code) in a Docker container instead of a VM.
It sees your project folder and Claude's sessions and memory, and nothing else on the host.
No Claude install is needed on the host. All arguments pass through (`claude-box -c`, `--resume`, `-p "..."`).

## Install

Requires Docker: [Docker Desktop for Windows](https://docs.docker.com/desktop/setup/install/windows-install/),
[Docker Desktop for macOS](https://docs.docker.com/desktop/setup/install/mac-install/),
or [Docker Engine on Linux](https://docs.docker.com/engine/install/).

```sh
git clone https://github.com/krauthaufen/claude-box ~/claude-box && ~/claude-box/install.sh   # Linux / macOS
```
```bat
git clone https://github.com/krauthaufen/claude-box %USERPROFILE%\claude-box
%USERPROFILE%\claude-box\install.cmd                                                              :: Windows
```

Run `claude-box` in a project folder. The first run builds the image (a few minutes), then log in once with `/login`.

### Global command

- Linux/macOS: the installer links `claude-box` into `~/.local/bin`. Make sure that folder is on your PATH.
- Windows: the installer adds the repo folder to your user PATH. Open a new terminal afterwards.
- All users (admin): clone to `/opt/claude-box` and `ln -s /opt/claude-box/claude-box /usr/local/bin/`,
  or on Windows clone to `C:\Program Files\claude-box` and add that folder to the machine PATH.
- Optional: `alias claude=claude-box` (PowerShell: `Set-Alias claude claude-box`).

Update with `git pull`.

## Isolation

| | access |
|---|---|
| project folder | read-write; `.claude/`, `.git/hooks`, `.git/config`, `.mcp.json`, `.envrc` read-only |
| sessions, memory, history | read-write, shared with host `claude` |
| global `CLAUDE.md`, settings, skills, agents, plugins | copied in on each launch, box changes are discarded |
| files `@imported` by global `CLAUDE.md` | read-only |
| rest of the host | not visible |
| internet | full access |

The rule: nothing the box writes is later executed by the host (no planted hooks, MCP servers or git hooks).
The container runs as your user, without sudo or capabilities, with pid and memory limits.

**What it does not protect against:** the agent can still write malicious or broken code into your repo.
Anything it changes there runs when you build, test or run the project, and so does anything anyone pulls from you.
Review `git diff` before building or pushing, as you would a PR from a stranger.

## Packages

- `~/.config/claude-box/packages` (Windows: `%APPDATA%\claude-box\packages`): apt packages for every box.
- `setup.sh` in the same folder runs as root at build time, for anything else. See `setup.sh.example` (.NET SDKs).

Changing either rebuilds the image on the next run. `claude-box --box-rebuild` forces a rebuild.

## Notes

- The box uses the same Claude version as the host `claude` if one is installed, else the latest. Pin with `CLAUDE_BOX_VERSION`.
- Multiple concurrent sessions are fine.
- Windows paths appear as `/c/Users/...` inside the box. Sessions are still shared with native Windows `claude`.
- Run it from the repo root, because only the current folder is mounted.
- Hooks and MCP servers in your settings that call host-only programs won't work inside the box.
- Env: `CLAUDE_BOX_ENV` (extra env var names), `CLAUDE_BOX_MOUNTS` (extra read-only paths),
  `CLAUDE_BOX_DOCKER_ARGS`, `CLAUDE_BOX_MEMORY` (default `8g`).
