# Install claude-box on Windows: add this folder to the user PATH, seed the config files and
# add "Open with Claude Box" to the Explorer right-click menu (per user, no admin needed).
# Remove the menu entry again with:  install.cmd -Uninstall
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'
$Repo = $PSScriptRoot
$Keys = 'HKCU:\Software\Classes\Directory\shell\ClaudeBox', 'HKCU:\Software\Classes\Directory\Background\shell\ClaudeBox'

if ($Uninstall) {
  foreach ($k in $Keys) { if (Test-Path $k) { Remove-Item -Recurse -Force $k } }
  $p = [Environment]::GetEnvironmentVariable('Path','User')
  [Environment]::SetEnvironmentVariable('Path', (($p -split ';') | Where-Object { $_ -and $_ -ne $Repo }) -join ';', 'User')
  Write-Host 'claude-box: removed from PATH and Explorer menu (config in %APPDATA%\claude-box kept)'
  exit 0
}

if (-not (Get-Command docker,podman -ErrorAction SilentlyContinue)) { throw 'docker or podman not found - install Docker Desktop, Rancher Desktop or Podman first' }
$p = [Environment]::GetEnvironmentVariable('Path','User')
if (($p -split ';') -notcontains $Repo) { [Environment]::SetEnvironmentVariable('Path', ($p.TrimEnd(';') + ";$Repo"), 'User') }
$Conf = Join-Path $env:APPDATA 'claude-box'; New-Item -ItemType Directory -Force $Conf | Out-Null
if (-not (Test-Path "$Conf\packages")) { Copy-Item "$Repo\packages.default" "$Conf\packages" }
if (-not (Test-Path "$Conf\network")) { Copy-Item "$Repo\network.default" "$Conf\network" }

# Explorer menu. Windows Terminal renders Claude's UI correctly; the legacy console garbles
# glyphs and line endings, so prefer wt.exe and fall back to cmd only if it's missing.
$Cmd = Join-Path $Repo 'claude-box.cmd'
if (Get-Command wt.exe -ErrorAction SilentlyContinue) { $Launch = "wt.exe -d `"%V`" cmd /k `"$Cmd`"" }
else { $Launch = "cmd.exe /k `"cd /d `"%V`" && `"$Cmd`"`"" }
foreach ($k in $Keys) {
  New-Item -Force $k | Out-Null
  Set-Item -Path $k -Value 'Open with Claude Box'
  New-ItemProperty -Force -Path $k -Name 'Icon' -Value 'cmd.exe' | Out-Null
  New-Item -Force "$k\command" | Out-Null
  Set-Item -Path "$k\command" -Value $Launch
}
Write-Host "installed: $Repo on PATH (open a new terminal), Explorer menu 'Open with Claude Box'"
Write-Host "config:    $Conf\packages, $Conf\network"
if ($Launch -like 'cmd.exe*') { Write-Host 'note: install Windows Terminal (winget install Microsoft.WindowsTerminal) for correct rendering' }
