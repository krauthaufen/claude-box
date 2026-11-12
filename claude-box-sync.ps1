# claude-box fast mode (Windows): copy the project into a Docker volume inside the VM and keep it in
# two-way sync with the Windows folder (Mutagen), so file-heavy work runs at Linux speed instead of
# going through the slow Windows<->VM file share. Dot-sourced by claude-box-win.ps1.
#
# Per project folder there is one volume, one sidecar container (no network, holds the volume for
# Mutagen) and one Mutagen session; every box started in that folder shares them. Each launcher
# leaves a marker (PID + start time); the last one out syncs back and removes everything. If a
# launcher dies, the next start in that folder simply rejoins, and `claude-box --cleanup` syncs back
# and removes leftovers. Opt-in per start with --box-sync.

$MutagenVersion = '0.18.1'
$MutagenSha = @{   # SHA256SUMS of the official release
  'amd64' = '76f8223d5e6b607efdd9516473669ae5492e4f142887352d59bc6934d1f07a2d'
  'arm64' = 'd0dd95b60f6077f0c02baee3128f754c1507bc4abfa63ae0bcae12e01a3d45f1'
}
$SyncRoot = Join-Path $StateRoot 'sync'
$IsPodman = (Split-Path -Leaf $Docker) -match '^podman'
# own daemon (one per engine), never touches a user's Mutagen
$env:MUTAGEN_DATA_DIRECTORY = Join-Path $StateRoot $(if ($IsPodman) { 'mutagen-data-podman' } else { 'mutagen-data' })
$MutagenArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
$MutagenExe = Join-Path $StateRoot "mutagen-$MutagenVersion-$MutagenArch\mutagen.exe"
$Interactive = -not ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected)

function Sync-Log([string]$m) { [Console]::Error.WriteLine("claude-box: $m") }

function Lock-Sync {
  New-Item -ItemType Directory -Force $SyncRoot | Out-Null
  for ($i = 0; $i -lt 6000; $i++) {
    try { return [IO.File]::Open((Join-Path $SyncRoot '.lock'), 'OpenOrCreate', 'ReadWrite', 'None') } catch { Start-Sleep -Milliseconds 100 }
  }
  throw 'claude-box: could not get the sync lock'
}

function Install-Mutagen {
  if (Test-Path $MutagenExe) { return $true }
  $name = "mutagen_windows_${MutagenArch}_v$MutagenVersion.zip"
  $zip = Join-Path $StateRoot $name; $dir = Split-Path $MutagenExe; $tmp = "$dir.tmp"
  Sync-Log "downloading Mutagen $MutagenVersion (one-time)..."
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -UseBasicParsing -OutFile $zip "https://github.com/mutagen-io/mutagen/releases/download/v$MutagenVersion/$name"
  } catch { Sync-Log "Mutagen download failed: $_"; return $false }
  if ((Get-FileHash -Algorithm SHA256 $zip).Hash -ne $MutagenSha[$MutagenArch]) {
    Remove-Item -Force $zip; Sync-Log 'Mutagen download has the wrong checksum, not using it'; return $false
  }
  foreach ($x in $tmp, $dir) { if (Test-Path $x) { Remove-Item -Recurse -Force $x } }
  Expand-Archive -Force $zip $tmp; Remove-Item -Force $zip
  Move-Item $tmp $dir
  return (Test-Path $MutagenExe)
}

# Mutagen runs 'docker'; for podman, point it at a link named docker.exe (podman takes the same commands).
if ($IsPodman) {
  $shimDir = Join-Path $StateRoot 'podman-as-docker'; $shim = Join-Path $shimDir 'docker.exe'
  $real = (Get-Command $Docker -ErrorAction SilentlyContinue).Source
  if ($real) {
    $ri = Get-Item $real; $si = Get-Item $shim -ErrorAction SilentlyContinue
    if (-not $si -or $si.Length -ne $ri.Length -or $si.LastWriteTimeUtc -ne $ri.LastWriteTimeUtc) {   # podman was updated
      New-Item -ItemType Directory -Force $shimDir | Out-Null; Remove-Item -Force $shim -ErrorAction SilentlyContinue
      try { New-Item -ItemType HardLink -Path $shim -Target $real -ErrorAction Stop | Out-Null } catch { Copy-Item -Force $real $shim }
    }
    $env:MUTAGEN_DOCKER_PATH = $shimDir
  }
}

function Get-SyncSessions([string]$selector) {
  if (-not (Test-Path $MutagenExe)) { return }
  $out = & $MutagenExe sync list --label-selector $selector --template '{{ json . }}' 2>$null
  $line = $out | Where-Object { $_ -match '^\s*\[' } | Select-Object -First 1
  if ($line) { (ConvertFrom-Json $line) | ForEach-Object { $_ } }
}

function New-SyncInfo([string]$key) {
  @{ Key = $key; Name = "cb-$key"; Volume = "claude-box-src-$key"; Sidecar = "claude-box-sync-$key"; Dir = (Join-Path $SyncRoot $key) }
}

function Get-LiveMarkers($s) {   # markers of launchers that are still running; stale ones are removed
  if (-not (Test-Path $s.Dir)) { return }
  foreach ($f in Get-ChildItem -File $s.Dir) {
    $p = "$(Get-Content $f.FullName -ErrorAction SilentlyContinue)" -split ' '
    $alive = $false
    try { $alive = ((Get-Process -Id ([int]$p[0]) -ErrorAction Stop).StartTime.Ticks -eq [long]$p[1]) } catch {}
    if ($alive) { $f.FullName } else { Remove-Item -Force $f.FullName -ErrorAction SilentlyContinue }
  }
}

function Test-InUse($s) {   # a launcher still running, or a box container still alive (e.g. its window was closed)
  if (@(Get-LiveMarkers $s).Count) { return $true }
  return [bool](& $Docker ps -q --filter "label=claude-box.box=$($s.Key)" 2>$null)
}

function Invoke-Mutagen([string[]]$a, [int]$timeoutSec) {   # $true on success within the timeout (0 = no timeout)
  $p = Start-Process -FilePath $MutagenExe -ArgumentList $a -NoNewWindow -PassThru
  $null = $p.Handle   # without this, PowerShell 5.1 loses the exit code
  if ($timeoutSec -gt 0) { if (-not $p.WaitForExit($timeoutSec * 1000)) { $p.Kill(); return $false } } else { $p.WaitForExit() }
  return ($p.ExitCode -eq 0)
}

# Force a full sync cycle. After a (re)start of the Mutagen daemon or the sidecar the session first has
# to reconnect, so wait for both sides and retry a few times.
function Sync-Flush($s, [int]$timeoutSec) {
  for ($try = 1; $try -le 5; $try++) {
    for ($i = 0; $i -lt 60; $i++) {
      $x = @(Get-SyncSessions "claude-box-key=$($s.Key)")[0]
      if (-not $x) { return $false }
      if ($x.alpha.connected -and $x.beta.connected) { break }
      Start-Sleep -Milliseconds 500
    }
    if (Invoke-Mutagen @('sync', 'flush', $s.Name) $timeoutSec) { return $true }
    Start-Sleep 2
  }
  return $false
}

# Sync back and remove one project's volume, sidecar and session. Keeps everything if anything is
# unresolved, so nothing the box wrote can get lost. Caller holds the lock.
function Close-BoxSync($s) {
  $sess = @(Get-SyncSessions "claude-box-key=$($s.Key)")
  if (-not $sess.Count) {   # Mutagen not answering, or the session vanished: never delete what may hold unsynced work
    Sync-Log "no sync found for $($s.Path); the copy in the VM is kept. Run 'claude-box --cleanup' later."
    return $false
  }
  if ($sess.Count -gt 0) {
    & $Docker start $s.Sidecar 2>$null | Out-Null
    Sync-Log 'syncing back to the Windows folder...'
    $ok = Sync-Flush $s 300
    $sess = @(Get-SyncSessions "claude-box-key=$($s.Key)")
    $issues = @()
    foreach ($x in $sess) {
      foreach ($c in @($x.conflicts)) { if ($c) { $issues += "conflict: $($c.root)" } }
      foreach ($side in 'alpha', 'beta') {
        foreach ($pr in @($x.$side.scanProblems) + @($x.$side.transitionProblems)) { if ($pr) { $issues += "$($pr.path): $($pr.error)" } }
      }
    }
    if (-not $ok -or $issues.Count -gt 0) {
      Sync-Log "could not fully sync back $($s.Path); the copy in the VM is kept."
      if (-not $ok) { Sync-Log '  final sync did not finish' }
      $issues | Select-Object -First 20 | ForEach-Object { Sync-Log "  $_" }
      Sync-Log "  Fix these in the Windows folder (or inside the box), then run: claude-box --cleanup"
      return $false
    }
    & $MutagenExe sync terminate $s.Name 2>$null | Out-Null
  }
  & $Docker rm -f $s.Sidecar 2>$null | Out-Null
  & $Docker volume rm $s.Volume 2>$null | Out-Null
  if (Test-Path $s.Dir) { Remove-Item -Recurse -Force $s.Dir }
  if (-not @(Get-SyncSessions 'claude-box=1').Count -and (Test-Path $MutagenExe)) { & $MutagenExe daemon stop 2>$null | Out-Null }
  return $true
}

# Leftovers: sessions nobody uses any more (launcher window closed, crash, reboot).
function Get-Orphans {
  foreach ($x in @(Get-SyncSessions 'claude-box=1')) {
    if (-not $x) { continue }
    $s = New-SyncInfo $x.labels.'claude-box-key'; $s.Path = $x.alpha.path
    if (-not (Test-InUse $s)) { $s } elseif ($ReportInUse) { Sync-Log "$($s.Path) is in use by a running box, skipped" }
  }
}

function Invoke-BoxSyncCleanup([string]$skipKey) {
  $ReportInUse = $true
  $lock = Lock-Sync
  try {
    foreach ($s in @(Get-Orphans)) {
      if (-not $s -or $s.Key -eq $skipKey) { continue }
      Sync-Log "cleaning up the fast-mode copy of $($s.Path)"
      if (Close-BoxSync $s) { Sync-Log '  done' }
    }
    # volumes without a session: their changes can no longer be synced back
    foreach ($v in @(& $Docker volume ls -q --filter label=claude-box.sync 2>$null)) {
      if (-not $v) { continue }
      $labels = (& $Docker volume inspect -f '{{ json .Labels }}' $v 2>$null) | ConvertFrom-Json
      $key = $labels.'claude-box.sync'; $path = $labels.'claude-box.path'
      if ($key -eq $skipKey -or @(Get-SyncSessions "claude-box-key=$key").Count) { continue }
      $s = New-SyncInfo $key
      if (Test-InUse $s) { continue }
      $ans = 'n'
      if ($Interactive) { $ans = Read-Host "claude-box: stale copy of $path in the VM, no longer synced (unsynced changes would be lost). Delete it? [y/N]" }
      if ($ans -match '^(y|yes)$') { & $Docker rm -f $s.Sidecar 2>$null | Out-Null; & $Docker volume rm $v 2>$null | Out-Null; if (Test-Path $s.Dir) { Remove-Item -Recurse -Force $s.Dir } }
      else { Sync-Log "kept volume $v ($path)" }
    }
  } finally { $lock.Dispose() }
}

# Returns the sync info if the project should be mounted from the VM volume, else $null.
function Enter-BoxSync([string]$Cwd, [string]$Tag, [bool]$Want) {
  $s = New-SyncInfo (Sha $Cwd.ToLower()); $s.Path = $Cwd

  # leftovers from earlier sessions in other folders
  if ((Test-Path $SyncRoot) -and @(Get-ChildItem -Directory $SyncRoot | Where-Object { $_.Name -ne $s.Key }).Count) {
    $orph = @(Get-Orphans | Where-Object { $_ -and $_.Key -ne $s.Key })
    if ($orph.Count) {
      Sync-Log "fast-mode copies left over from earlier sessions (run 'claude-box --cleanup' to sync back and remove them):"
      $orph | ForEach-Object { Sync-Log "  $($_.Path)" }
    }
  }

  # (the marker dir exists exactly while a session exists, so folders never synced don't even start Mutagen)
  $join = (Test-Path $s.Dir) -and @(Get-SyncSessions "claude-box-key=$($s.Key)").Count -gt 0   # another box (or a crashed one) already syncs this folder
  if (-not $join) {
    if (-not $Want) { return $null }
    & $Docker volume inspect $s.Volume 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Sync-Log "an unsynced copy of this folder is still in the VM; run 'claude-box --cleanup'. Starting without fast mode."; return $null }
  }

  $lock = Lock-Sync
  try {
    if (-not (Install-Mutagen)) { Sync-Log 'starting without fast mode'; return $null }
    if (-not @(Get-SyncSessions "claude-box-key=$($s.Key)").Count) {
      # Never synced back: the box's own protected paths, and (by default) build output.
      $ign = @('/.git/hooks', '/.git/config', '/.claude', '/.mcp.json', '/CLAUDE.local.md', '/.envrc')
      if ($env:CLAUDE_BOX_SYNC_BUILD -ne 'yes') {
        $ign += @('bin/', 'obj/')
        if (Get-Command git -ErrorAction SilentlyContinue) {   # bin/obj folders with tracked files are sources: keep them
          $neg = @{}
          foreach ($f in @(& git -C $Cwd -c core.quotepath=off ls-files 2>$null)) {
            if ($f -notmatch '(^|/)(bin|obj)/') { continue }
            $parts = $f -split '/'
            for ($i = 0; $i -lt $parts.Count - 1; $i++) { if ($parts[$i] -eq 'bin' -or $parts[$i] -eq 'obj') { $neg['!/' + (($parts[0..$i]) -join '/') + '/'] = 1 } }
          }
          $ign += @($neg.Keys)
        }
      }
      $ignArgs = @(); foreach ($p in $ign) { $ignArgs += @('--ignore', $p) }
      & $Docker volume create --label "claude-box.sync=$($s.Key)" --label "claude-box.path=$Cwd" $s.Volume | Out-Null
      & $Docker run --rm @UserNs --network none -v "$($s.Volume):/w" --entrypoint chown $Tag 1000:1000 /w
      # the sidecar only holds the volume for Mutagen: no network, minimal rights, invisible to the box
      & $Docker run -d @UserNs --name $s.Sidecar --label "claude-box.sync=$($s.Key)" --network none --cap-drop ALL `
        --cap-add CHOWN --cap-add FOWNER --cap-add DAC_OVERRIDE --security-opt no-new-privileges --pids-limit 256 `
        --user 1000:1000 -v "$($s.Volume):/w" --entrypoint sleep $Tag infinity | Out-Null
      $ok = ($LASTEXITCODE -eq 0)
      if ($ok) {
        & $MutagenExe sync create --name $s.Name --label claude-box=1 --label "claude-box-key=$($s.Key)" `
          --sync-mode two-way-safe --default-file-mode 0644 --default-directory-mode 0755 --watch-polling-interval-beta 2 `
          @ignArgs $Cwd "docker://$($s.Sidecar)/w" 2>&1 | Out-Null
        $ok = ($LASTEXITCODE -eq 0)
      }
      if (-not $ok) {
        Sync-Log 'could not set up fast mode; starting without it'
        & $MutagenExe sync terminate $s.Name 2>$null | Out-Null
        & $Docker rm -f $s.Sidecar 2>$null | Out-Null; & $Docker volume rm $s.Volume 2>$null | Out-Null
        return $null
      }
      Sync-Log 'copying the project into the VM...'
    } else {
      & $Docker start $s.Sidecar 2>$null | Out-Null   # e.g. after a reboot
    }
    New-Item -ItemType Directory -Force $s.Dir | Out-Null
    $me = Get-Process -Id $PID
    $s.Marker = Join-Path $s.Dir "$PID"
    Set-Content -Path $s.Marker -Value "$PID $($me.StartTime.Ticks)"
  } finally { $lock.Dispose() }

  if (-not (Sync-Flush $s 0)) {
    Sync-Log 'initial copy failed; starting without fast mode'
    Exit-BoxSync $s
    return $null
  }
  return $s
}

function Exit-BoxSync($s) {
  $lock = Lock-Sync
  try {
    if ($s.Marker -and (Test-Path $s.Marker)) { Remove-Item -Force $s.Marker }
    if (-not (Test-InUse $s)) { [void](Close-BoxSync $s) }
  } finally { $lock.Dispose() }
}
