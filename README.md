# claude-box

Run [Claude Code](https://claude.com/claude-code) in a container (Docker or Podman) instead of a VM.
It sees your project folder and Claude's sessions and memory, and nothing else on the host.
No Claude install is needed on the host. All arguments pass through (`claude-box -c`, `--resume`, `-p "..."`).

## Install

Requires a container engine, any of:

- [Podman](https://podman.io/docs/installation) (free, Apache 2.0). On Windows the installer needs no admin rights;
  afterwards run `podman machine init` and `podman machine start` once. Rootless Podman is fine.
- [Rancher Desktop](https://rancherdesktop.io) (free, Apache 2.0) with the dockerd (moby) engine.
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (needs a paid subscription in larger companies)
  or [Docker Engine on Linux](https://docs.docker.com/engine/install/).

claude-box uses `docker` if it's installed, else `podman`. If both are installed, it uses the one that's running.
`CLAUDE_BOX_ENGINE=podman` forces one.

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
- Windows: the installer adds the repo folder to your user PATH and an **Open with Claude Box** entry to
  the Explorer right-click menu. Use [Windows Terminal](https://aka.ms/terminal): the old `cmd` console
  garbles Claude's UI. If you install Windows Terminal later, re-run `install.cmd`. Remove everything with `install.cmd -Uninstall`.
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
| network | everything allowed except `10.42.x.x`; there only `10.42.0.1` (gateway) and `10.42.0.3` (DNS) |

The rule: nothing the box writes is later executed by the host (no planted hooks, MCP servers or git hooks).
The container runs as your user, without sudo or capabilities, with pid and memory limits.

**What it does not protect against:** the agent can still write malicious or broken code into your repo.
Anything it changes there runs when you build, test or run the project, and so does anything anyone pulls from you.
Review `git diff` before building or pushing, as you would a PR from a stranger.

## Network

`~/.config/claude-box/network` (Windows: `%APPDATA%\claude-box\network`) holds `allow CIDR` / `block CIDR` lines.
The first match wins and anything unmatched is allowed. The defaults are in `network.default`.
The rules are applied inside the container before Claude starts, and the session then runs without capabilities, so it can't change them.
If they can't be applied, the box refuses to start.

## Packages

- `~/.config/claude-box/packages` (Windows: `%APPDATA%\claude-box\packages`): apt packages for every box.
- `setup.sh` in the same folder runs as root at build time, for anything apt doesn't have.

Changing either rebuilds the image on the next run. `claude-box --box-rebuild` forces a rebuild.

### .NET 8 / 10

Install the official SDKs from Microsoft's apt repository:

```sh
cp ~/claude-box/setup.sh.example ~/.config/claude-box/setup.sh                    # Linux / macOS
copy %USERPROFILE%\claude-box\setup.sh.example %APPDATA%\claude-box\setup.sh    :: Windows
```

The example installs both SDKs side by side. Delete the one you don't need. Run `claude-box --box-rebuild` from time to time to pick up .NET patch releases.

## Fast mode (Windows, experimental)

Containers on Windows run in a VM, and every file access from the box to `C:\` crosses into Windows and back.
That makes file-heavy work slow: on a 1,000-file repo `git status` takes 2 s instead of 0.02 s, and searching 0.9 s instead of 0.02 s.
(Compiling is barely affected: Aardvark.Rendering builds in 169 s through the share, 152 s in fast mode, 154 s natively.)
`claude-box --box-sync` copies the project into the VM instead. It's off unless you pass the flag:

- The copy lives in a container volume and is kept in two-way sync with your folder by [Mutagen](https://mutagen.io)
  (downloaded once, checksum-pinned). Edits on either side arrive within about a second.
- `.claude/`, `.git/hooks`, `.git/config`, `.mcp.json`, `.envrc` and `CLAUDE.local.md` are never synced back.
- `bin/` and `obj/` stay in the VM, so build output isn't visible on Windows and is gone after the session.
  Folders with that name that contain tracked files are synced normally. `CLAUDE_BOX_SYNC_BUILD=yes` syncs them all.
- Boxes in the same folder share one copy. When the last one exits, everything is synced back and removed.
  If anything can't be synced back (a conflict, an error), the copy is kept and the launcher says why.
- After a crash or a closed window, the next start in that folder picks the copy up again, and starts elsewhere list it.
  `claude-box --cleanup` syncs leftovers back and removes them.
- Not needed on Linux, where the box reads files directly.

## Notes

- The box uses the same Claude version as the host `claude` if one is installed, else the latest. Pin with `CLAUDE_BOX_VERSION`.
- Multiple concurrent sessions are fine.
- Windows paths appear as `/c/Users/...` inside the box. Sessions are still shared with native Windows `claude`.
- Git: the box uses the host's `user.name`, `user.email`, `core.autocrlf` and `core.eol` for the folder, so commits carry your identity and CRLF checkouts (Git for Windows default `autocrlf=true`) stay clean.
- Run it from the repo root, because only the current folder is mounted.
- Hooks and MCP servers in your settings that call host-only programs won't work inside the box.
- Env: `CLAUDE_BOX_ENV` (extra env var names), `CLAUDE_BOX_MOUNTS` (extra read-only paths),
  `CLAUDE_BOX_DOCKER_ARGS`, `CLAUDE_BOX_MEMORY` (default `8g`), `CLAUDE_BOX_ENGINE` (`docker` or `podman`).
