# claude-box — run Claude Code inside a Docker container (Windows, Docker Desktop / Linux containers).
# Mounts only the current directory and the Claude config dirs. Windows paths are mapped to
# /c/Users/... in the container; the per-project session dir is cross-mounted so that
# --resume / --continue see the same sessions as the native Windows CLI.
$ErrorActionPreference = 'Stop'
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

# --- Config: global package list + optional root setup script ----------------
$ConfDir = if ($env:CLAUDE_BOX_CONFIG) { $env:CLAUDE_BOX_CONFIG } else { Join-Path $env:APPDATA 'claude-box' }
$PkgFile = Join-Path $ConfDir 'packages'; $SetupFile = Join-Path $ConfDir 'setup.sh'
if (-not (Test-Path $PkgFile)) { New-Item -ItemType Directory -Force $ConfDir | Out-Null; Copy-Item (Join-Path $Repo 'packages.default') $PkgFile }
$Packages = ((Get-Content $PkgFile | ForEach-Object { ($_ -replace '#.*','').Trim() }) -join ' ') -replace '\s+',' '
$Packages = $Packages.Trim()
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
$Hash = Sha ((Get-Content -Raw (Join-Path $Repo 'Dockerfile')) + "|$Packages|$SetupB64|$CHome")
$Image = if ($env:CLAUDE_BOX_IMAGE) { $env:CLAUDE_BOX_IMAGE } else { 'claude-box' }
$Tag = "${Image}:$Version-1000-$Hash"
$Rest = @($args)
if ($Rest.Count -gt 0 -and $Rest[0] -eq '--box-rebuild') { $Rest = $Rest[1..($Rest.Count)] | Where-Object { $_ -ne $null }; & docker image rm -f $Tag 2>$null | Out-Null }
& docker image inspect $Tag 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  [Console]::Error.WriteLine("claude-box: building image $Tag (one-time, a few minutes)...")
  & docker build -t $Tag -f (Join-Path $Repo 'Dockerfile') `
    --build-arg UID=1000 --build-arg GID=1000 --build-arg UNAME=$UName --build-arg HOMEDIR=$CHome `
    --build-arg VERSION=$Version --build-arg "PACKAGES=$Packages" --build-arg "SETUP_B64=$SetupB64" $Repo
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# --- Mounts --------------------------------------------------------------------
$Cwd = (Get-Location).ProviderPath
$CCwd = To-Linux $Cwd
$DArgs = @('-v', "${Cwd}:$CCwd", '-w', $CCwd)
if ($env:CLAUDE_CONFIG_DIR) {
  $Cfg = $env:CLAUDE_CONFIG_DIR; $CCfg = To-Linux $Cfg
  $DArgs += @('-e', "CLAUDE_CONFIG_DIR=$CCfg")
} else {
  $Cfg = Join-Path $env:USERPROFILE '.claude'; $CCfg = "$CHome/.claude"
  $Json = Join-Path $env:USERPROFILE '.claude.json'
  if (-not (Test-Path $Json)) { [IO.File]::WriteAllText($Json, '{}') }
  $DArgs += @('-v', "${Json}:$CHome/.claude.json")
}
New-Item -ItemType Directory -Force $Cfg | Out-Null
$DArgs += @('-v', "${Cfg}:$CCfg")
# Share this project's session/memory dir with the native CLI (names differ: C--x vs -c-x).
$HostProj = Join-Path (Join-Path $Cfg 'projects') (Escape-Project $Cwd)
New-Item -ItemType Directory -Force $HostProj | Out-Null
$DArgs += @('-v', "${HostProj}:$CCfg/projects/$(Escape-Project $CCwd)")
if ($env:CLAUDE_BOX_MOUNTS) {
  foreach ($m in ($env:CLAUDE_BOX_MOUNTS -split ';')) { if ($m -and (Test-Path $m)) { $DArgs += @('-v', "${m}:$(To-Linux $m)") } }
}

# --- Env passthrough -------------------------------------------------------------
$Vars = @('COLORTERM','TZ','ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_BASE_URL','ANTHROPIC_MODEL',
  'CLAUDE_CODE_USE_BEDROCK','CLAUDE_CODE_USE_VERTEX','AWS_REGION','AWS_PROFILE','CLOUD_ML_REGION',
  'ANTHROPIC_VERTEX_PROJECT_ID','HTTP_PROXY','HTTPS_PROXY','NO_PROXY')
if ($env:CLAUDE_BOX_ENV) { $Vars += ($env:CLAUDE_BOX_ENV -split '[ ;]') }
foreach ($v in $Vars) { $val = [Environment]::GetEnvironmentVariable($v); if ($v -and $val) { $DArgs += @('-e', "$v=$val") } }
$DArgs += @('-e', 'TERM=xterm-256color')

$Tty = if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { '-i' } else { '-it' }
$Extra = @(); if ($env:CLAUDE_BOX_DOCKER_ARGS) { $Extra = $env:CLAUDE_BOX_DOCKER_ARGS -split '\s+' }
& docker run --rm $Tty --hostname $env:COMPUTERNAME @Extra @DArgs $Tag @Rest
exit $LASTEXITCODE
