# claude-box

Run the Claude Code CLI isolated in a Docker container, as a lighter alternative to a desktop VM.
No Claude install is needed on the host. Arguments pass straight through, so `claude-box --resume`,
`claude-box -c` and `claude-box -p "..."` behave like `claude`.

## Setup

Needs Docker (Linux) or Docker Desktop (macOS, Windows). Then:

```sh
git clone <repo> ~/claude-box && ~/claude-box/install.sh            # Linux / macOS
```
```bat
git clone <repo> %USERPROFILE%\claude-box
%USERPROFILE%\claude-box\install.cmd                                 :: Windows
```

Then run `claude-box` in a project dir. The first run builds the image (a few minutes).
Log in once inside the box with `/login`, or pass `ANTHROPIC_API_KEY`. The box keeps its own credentials.

## Make it a global command

The installers already put `claude-box` on your PATH, for your user only:

- **Linux / macOS**: `install.sh` symlinks it into `~/.local/bin`. If that dir isn't on your PATH yet:
  `echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc` (or `~/.zshrc` on macOS), then open a new shell.
- **Windows**: `install.cmd` adds the repo folder to your user PATH. Open a new terminal afterwards.
  `claude-box` then works in cmd, PowerShell and Windows Terminal.

For **all users** on a machine (needs admin rights):

```sh
sudo git clone <repo> /opt/claude-box && sudo ln -s /opt/claude-box/claude-box /usr/local/bin/claude-box
```
```bat
:: elevated cmd
git clone <repo> "C:\Program Files\claude-box"
powershell -c "[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','Machine') + ';C:\Program Files\claude-box', 'Machine')"
```

Each user still gets their own image, config copy and login. Update with `git pull` in the repo dir.

To make plain `claude` always run boxed, add an alias:
`alias claude=claude-box` in `~/.bashrc` / `~/.zshrc`, or `Set-Alias claude claude-box` in your PowerShell `$PROFILE`.

## What the box can and cannot touch

| | access |
|---|---|
| current directory | read-write, except `.claude/`, `.git/hooks`, `.git/config`, `.mcp.json`, `.envrc` (read-only) |
| sessions, auto-memory (`projects/`), `history.jsonl`, `file-history/`, `todos/` | read-write, shared with host `claude` |
| global `CLAUDE.md`, settings, skills, agents, commands, rules, plugins | **copied** in fresh every launch; box edits are discarded |
| files `@imported` by the global `CLAUDE.md` | read-only |
| everything else on the host | not mounted |
| internet | full access |

Principle: nothing the box writes is executed by the host afterwards, e.g. no planted hooks,
MCP servers or git hooks. The container runs as your uid, with all capabilities dropped,
`no-new-privileges`, no sudo, no docker socket, and pid and memory limits.

### What it does NOT protect against

**claude-box does not stop the agent from writing malicious or broken code into your repo.**
The project folder is writable on purpose, since that's the agent's job. Anything it changes there,
such as source files, build scripts, Makefiles, `package.json` scripts, test files, CI configs or
dependencies, runs on your machine the moment you build, test or run the project outside the box.
The same goes for anyone who pulls your pushed commits.

The box keeps the agent from touching your *machine* directly. It does not make its *output* trustworthy.
Review diffs (`git diff`) before you build, run or push, as you would a PR from an unknown contributor.

## Packages / build tools

- `~/.config/claude-box/packages` (Windows: `%APPDATA%\claude-box\packages`): Debian apt packages, one list for every box.
- `setup.sh` in the same dir: runs as root at image build, for anything apt lacks.
  See `setup.sh.example` (.NET 8 + 10 SDKs, plus `libicu76` in packages).

Editing either file triggers a rebuild on the next run. `claude-box --box-rebuild` forces one.

## Notes

- The box's Claude version matches the host `claude` if one is installed, else `latest`.
  Pin it with `CLAUDE_BOX_VERSION`.
- Concurrent boxes in the same or different projects are fine.
- Windows: `C:\Users\me\proj` appears as `/c/Users/me/proj` inside. Sessions still share the
  native `projects\C--Users-me-proj` dir.
- Hooks, MCP servers and status lines in your settings that call host-only programs won't work in the box.
- Run from the repo root, since only the CWD is mounted.
- Env knobs: `CLAUDE_BOX_ENV` (extra env var names), `CLAUDE_BOX_MOUNTS` (extra read-only paths),
  `CLAUDE_BOX_DOCKER_ARGS`, `CLAUDE_BOX_MEMORY` (default 8g).
