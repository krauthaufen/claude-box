# claude-box — run Claude Code inside a container (Windows: Docker Desktop, Rancher Desktop or Podman).
# Same isolation model as ./claude-box (see there). Windows paths appear as /c/Users/... in the
# container; the per-project session dir is cross-mounted so --resume / --continue share
# sessions and memory with the native Windows CLI.
$ErrorActionPreference = 'Continue'   # 'Stop' turns native stderr into exceptions on PS 5.1; we check $LASTEXITCODE
$Repo = $PSScriptRoot

function To-Linux([string]$p) {          # C:\Users\x\proj -> /c/Users/x/proj
  $p = [IO.Path]::GetFullPath($p).TrimEnd('\')
  if ($p -match '^([A-Za-z]):(.*)$') { return '/' + $Matches[1].ToLower() + ($Matches[2] -replace '\\','/') }
  return ($p -replace '\\','/')
}
function Escape-Project([string]$p) { return ($p -replace '[^a-zA-Z0-9]','-') }  # Claude's projects/<dir> naming
function Sha([string]$s) {
  $h = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($s))
  return (($h | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0,10)
}

# --- Container engine: docker (Docker Desktop, Rancher Desktop with dockerd) or podman ------
$Docker = $env:CLAUDE_BOX_ENGINE
if (-not $Docker) {
  $found = @('docker','podman' | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue })
  $Docker = $found | Select-Object -First 1
  if ($found.Count -gt 1) {   # both installed: take the one that is running, else podman (we can start it)
    $Docker = 'podman'
    foreach ($e in $found) { & $e version --format '{{.Server.Version}}' 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $Docker = $e; break } }
  }
}
if (-not $Docker) { [Console]::Error.WriteLine('claude-box: neither docker nor podman found'); exit 1 }
# Rootless podman: map the box user (1000) to your own user, so files it writes are yours.
$UserNs = @()
if ((Split-Path -Leaf $Docker) -match '^podman') {
  $rootless = & $Docker info --format '{{.Host.Security.Rootless}}' 2>$null
  if ($LASTEXITCODE -ne 0) {   # the Podman VM doesn't start on its own after a reboot
    [Console]::Error.WriteLine('claude-box: starting the Podman machine...')
    # its helper processes keep running: start them outside the project, or they lock the folder
    $log = Join-Path $env:TEMP 'claude-box-podman-start.log'
    $p = Start-Process -FilePath (Get-Command $Docker).Source -ArgumentList 'machine','start' -WorkingDirectory $env:SystemRoot `
      -NoNewWindow -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    $null = $p.Handle; $p.WaitForExit()
    $out = @(Get-Content $log, "$log.err" -ErrorAction SilentlyContinue)
    $rootless = & $Docker info --format '{{.Host.Security.Rootless}}' 2>$null
    if ($LASTEXITCODE -ne 0) { $out | ForEach-Object { [Console]::Error.WriteLine("$_") }; [Console]::Error.WriteLine('claude-box: Podman is not running (see above)'); exit 1 }
  }
  if ($rootless -eq 'true') { $UserNs = @('--userns=keep-id:uid=1000,gid=1000') }
}

# --- Config: global package list + optional root setup script ----------------
$ConfDir = if ($env:CLAUDE_BOX_CONFIG) { $env:CLAUDE_BOX_CONFIG } else { Join-Path $env:APPDATA 'claude-box' }
$PkgFile = Join-Path $ConfDir 'packages'; $SetupFile = Join-Path $ConfDir 'setup.sh'
if (-not (Test-Path $PkgFile)) { New-Item -ItemType Directory -Force $ConfDir | Out-Null; Copy-Item (Join-Path $Repo 'packages.default') $PkgFile }
$Packages = ((Get-Content $PkgFile | ForEach-Object { ($_ -replace '#.*','').Trim() }) -join ' ') -replace '\s+',' '
$Packages = $Packages.Trim()
$NetFile = Join-Path $ConfDir 'network'
if (-not (Test-Path $NetFile)) { Copy-Item (Join-Path $Repo 'network.default') $NetFile }
$NetRules = ((Get-Content $NetFile | ForEach-Object { ($_ -replace '#.*','').Trim() } | Where-Object { $_ }) -join "`n")
$SetupB64 = ''
if (Test-Path $SetupFile) { $SetupB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($SetupFile)) }

# --- Claude version: match the host CLI if installed, else latest ------------
$Version = $env:CLAUDE_BOX_VERSION
if (-not $Version -and (Get-Command claude -ErrorAction SilentlyContinue)) {
  try { $Version = ((& claude --version 2>$null) -split '\s+')[0] } catch {}
}
if (-not $Version) { $Version = 'latest' }

# --- Image ---------------------------------------------------------------------
$UName = (($env:USERNAME.ToLower()) -replace '[^a-z0-9_-]','')
if (-not $UName -or $UName -notmatch '^[a-z_]') { $UName = 'claude' }
$CHome = "/home/$UName"
$Hash = Sha ((Get-Content -Raw (Join-Path $Repo 'Dockerfile')) + (Get-Content -Raw (Join-Path $Repo 'entry.sh')) + "|$Packages|$SetupB64|$CHome")
$Image = if ($env:CLAUDE_BOX_IMAGE) { $env:CLAUDE_BOX_IMAGE } else { 'claude-box' }
$Tag = "${Image}:$Version-1000-$Hash"
$Rest = @($args)
$BoxSync = $Rest -contains '--box-sync'; $Rest = @($Rest | Where-Object { $_ -ne '--box-sync' })   # opt-in fast mode
$StateRoot = if ($env:CLAUDE_BOX_STATE) { $env:CLAUDE_BOX_STATE } else { Join-Path $env:LOCALAPPDATA 'claude-box' }
if ($Rest.Count -gt 0 -and $Rest[0] -eq '--cleanup') {   # sync back + remove leftover fast-mode copies
  . (Join-Path $Repo 'claude-box-sync.ps1'); Invoke-BoxSyncCleanup ''; exit 0
}
if ($Rest.Count -gt 0 -and $Rest[0] -eq '--box-rebuild') { $Rest = $Rest[1..($Rest.Count)] | Where-Object { $_ -ne $null }; & $Docker image rm -f $Tag 2>$null | Out-Null }
& $Docker image inspect $Tag 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  [Console]::Error.WriteLine("claude-box: building image $Tag (one-time, a few minutes)...")
  for ($attempt = 1; $attempt -le 3; $attempt++) {   # finished layers are cached, so a retry only redoes the failed step
    & $Docker build -t $Tag -f (Join-Path $Repo 'Dockerfile') `
      --build-arg UID=1000 --build-arg GID=1000 --build-arg UNAME=$UName --build-arg HOMEDIR=$CHome `
      --build-arg VERSION=$Version --build-arg "PACKAGES=$Packages" --build-arg "SETUP_B64=$SetupB64" $Repo
    if ($LASTEXITCODE -eq 0) { break }
    if ($attempt -eq 3) { [Console]::Error.WriteLine('claude-box: image build failed'); exit 1 }
    [Console]::Error.WriteLine("claude-box: build failed (attempt $attempt), retrying..."); Start-Sleep 5
  }
}

# --- Config: host config + box-private state -------------------------------------
# Same isolation model as the bash script: host instructions/settings/extensions are COPIED into
# a box-private config dir each launch; only data (sessions, memory, history) is shared writable.
if ($env:CLAUDE_CONFIG_DIR) { $Cfg = $env:CLAUDE_CONFIG_DIR; $CCfg = To-Linux $Cfg; $HJson = Join-Path $Cfg '.claude.json' }
else { $Cfg = Join-Path $env:USERPROFILE '.claude'; $CCfg = "$CHome/.claude"; $HJson = Join-Path $env:USERPROFILE '.claude.json' }
New-Item -ItemType Directory -Force $Cfg | Out-Null
$State = Join-Path $StateRoot (Sha $Cfg)
$BoxCfg = Join-Path $State 'config'; $BoxJson = Join-Path $BoxCfg '.claude.json'
New-Item -ItemType Directory -Force $BoxCfg | Out-Null
# Serialize seeding/refresh between concurrently starting launchers (exclusive file lock).
$LockPath = Join-Path $BoxCfg '.launch.lock'; $Lock = $null
for ($i = 0; $i -lt 600 -and -not $Lock; $i++) {
  try { $Lock = [IO.File]::Open($LockPath, 'OpenOrCreate', 'ReadWrite', 'None') } catch { Start-Sleep -Milliseconds 100 }
}
try {
  # box-private .claude.json inside the config dir (CLAUDE_CONFIG_DIR always set) => Claude's lock is shared by boxes
  if (-not (Test-Path $BoxJson) -or (Get-Item $BoxJson).Length -eq 0) {
    $seed = "$BoxJson.seed"
    if (Test-Path $HJson) { Copy-Item -Force $HJson $seed } else { [IO.File]::WriteAllText($seed, '{}') }
    Move-Item -Force $seed $BoxJson
  }
  foreach ($item in 'CLAUDE.md','settings.json','settings.local.json','keybindings.json','skills','agents','commands','rules','output-styles','plugins') {
    # copy-then-swap so already running boxes never see a half-copied tree
    $dst = Join-Path $BoxCfg $item; $tmp = Join-Path $BoxCfg ".incoming-$item"; $old = Join-Path $BoxCfg ".old-$item"
    foreach ($x in $tmp, $old) { if (Test-Path $x) { Remove-Item -Recurse -Force $x } }
    $src = Join-Path $Cfg $item
    if (Test-Path $src) { Copy-Item -Recurse -Force $src $tmp -ErrorAction SilentlyContinue }
    if (Test-Path $dst) { Move-Item $dst $old }
    if (Test-Path $tmp) { Move-Item $tmp $dst }
    if (Test-Path $old) { Remove-Item -Recurse -Force $old }
  }
} finally { if ($Lock) { $Lock.Dispose() } }
$DArgs = @('-v', "${BoxCfg}:$CCfg", '-e', "CLAUDE_CONFIG_DIR=$CCfg")
foreach ($d in 'projects','file-history','todos') {
  $hd = Join-Path $Cfg $d; New-Item -ItemType Directory -Force $hd | Out-Null
  $DArgs += @('-v', "${hd}:$CCfg/$d")
}
$Hist = Join-Path $Cfg 'history.jsonl'; if (-not (Test-Path $Hist)) { [IO.File]::WriteAllText($Hist, '') }
$DArgs += @('-v', "${Hist}:$CCfg/history.jsonl")

# --- CWD, with host-executed bits read-only ------------------------------------------
$Cwd = (Get-Location).ProviderPath.TrimEnd('\')
if ($Cwd -eq $env:USERPROFILE.TrimEnd('\') -or $Cwd -match '^[A-Za-z]:$') { [Console]::Error.WriteLine("claude-box: refusing to mount $Cwd as the project dir"); exit 1 }
$CCwd = To-Linux $Cwd
# Fast mode: project copied into a VM volume and synced back live (see claude-box-sync.ps1).
. (Join-Path $Repo 'claude-box-sync.ps1')
$Sync = Enter-BoxSync $Cwd $Tag $BoxSync
if ($Sync) { $DArgs += @('-v', "$($Sync.Volume):$CCwd", '-w', $CCwd, '--label', "claude-box.box=$($Sync.Key)") }
else { $DArgs += @('-v', "${Cwd}:$CCwd", '-w', $CCwd) }
# Windows CLI names the project dir C--x, the container -c-x: share the same one.
$HostProj = Join-Path (Join-Path $Cfg 'projects') (Escape-Project $Cwd)
New-Item -ItemType Directory -Force $HostProj | Out-Null
$DArgs += @('-v', "${HostProj}:$CCfg/projects/$(Escape-Project $CCwd)")
New-Item -ItemType Directory -Force (Join-Path $Cwd '.claude') | Out-Null
$DArgs += @('-v', "$(Join-Path $Cwd '.claude'):$CCwd/.claude:ro")
if (Test-Path (Join-Path $Cwd '.git') -PathType Container) {
  New-Item -ItemType Directory -Force (Join-Path $Cwd '.git\hooks') | Out-Null
  $DArgs += @('-v', "$(Join-Path $Cwd '.git\hooks'):$CCwd/.git/hooks:ro")
  if (Test-Path (Join-Path $Cwd '.git\config')) { $DArgs += @('-v', "$(Join-Path $Cwd '.git\config'):$CCwd/.git/config:ro") }
}
foreach ($f in '.mcp.json','CLAUDE.local.md','.envrc') {
  if (Test-Path (Join-Path $Cwd $f) -PathType Leaf) { $DArgs += @('-v', "$(Join-Path $Cwd $f):$CCwd/${f}:ro") }
}
# files imported by the global CLAUDE.md as @~/...: read-only
$GMd = Join-Path $Cfg 'CLAUDE.md'
if (Test-Path $GMd) {
  foreach ($m in [regex]::Matches((Get-Content -Raw $GMd), '(?m)(?:^|\s)@~/(\S+)')) {
    $rel = $m.Groups[1].Value; $hp = Join-Path $env:USERPROFILE ($rel -replace '/','\')
    if (Test-Path $hp -PathType Leaf) { $DArgs += @('-v', "${hp}:$CHome/${rel}:ro") }
  }
}
if ($env:CLAUDE_BOX_MOUNTS) {   # explicit opt-in, always read-only
  foreach ($m in ($env:CLAUDE_BOX_MOUNTS -split ';')) { if ($m -and (Test-Path $m)) { $DArgs += @('-v', "${m}:$(To-Linux $m):ro") } }
}

# --- Env passthrough -------------------------------------------------------------
$Vars = @('COLORTERM','TZ','ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_BASE_URL','ANTHROPIC_MODEL',
  'CLAUDE_CODE_USE_BEDROCK','CLAUDE_CODE_USE_VERTEX','AWS_REGION','CLOUD_ML_REGION',
  'ANTHROPIC_VERTEX_PROJECT_ID','HTTP_PROXY','HTTPS_PROXY','NO_PROXY')
if ($env:CLAUDE_BOX_ENV) { $Vars += ($env:CLAUDE_BOX_ENV -split '[ ;]') }
foreach ($v in $Vars) { $val = [Environment]::GetEnvironmentVariable($v); if ($v -and $val) { $DArgs += @('-e', "$v=$val") } }
$DArgs += @('-e', 'TERM=xterm-256color')

# Git identity + line endings. Git for Windows usually has core.autocrlf=true (CRLF on disk, LF in the repo).
# Give git in the box the host's effective setting for this folder, or it sees every file as modified.
$GitCfg = @{}
if (Get-Command git -ErrorAction SilentlyContinue) {
  foreach ($k in 'user.name','user.email','core.autocrlf','core.eol') { $v = (& git -C $Cwd config --get $k 2>$null); if ($v) { $GitCfg[$k] = "$v".Trim() } }
} else { $GitCfg['core.autocrlf'] = 'true' }
$i = 0
foreach ($k in $GitCfg.Keys) { $DArgs += @('-e', "GIT_CONFIG_KEY_$i=$k", '-e', "GIT_CONFIG_VALUE_$i=$($GitCfg[$k])"); $i++ }
if ($i -gt 0) { $DArgs += @('-e', "GIT_CONFIG_COUNT=$i") }

$Tty = if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { '-i' } else { '-it' }
$Extra = @(); if ($env:CLAUDE_BOX_DOCKER_ARGS) { $Extra = $env:CLAUDE_BOX_DOCKER_ARGS -split '\s+' }
$Mem = if ($env:CLAUDE_BOX_MEMORY) { $env:CLAUDE_BOX_MEMORY } else { '8g' }
& $Docker run --rm $Tty @UserNs --user 0:0 --hostname $env:COMPUTERNAME --cap-drop ALL --cap-add NET_ADMIN --cap-add SETUID --cap-add SETGID --cap-add SETPCAP --security-opt no-new-privileges --pids-limit 4096 --memory $Mem @Extra @DArgs -e "CLAUDE_BOX_NET=$NetRules" $Tag @Rest
$Rc = $LASTEXITCODE
if ($Sync) { Exit-BoxSync $Sync }
exit $Rc
