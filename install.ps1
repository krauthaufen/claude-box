# Install claude-box on Windows: add this folder to the user PATH and seed the package list.
$ErrorActionPreference = 'Stop'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'docker not found - install Docker Desktop first' }
$Repo = $PSScriptRoot
$p = [Environment]::GetEnvironmentVariable('Path','User')
if (($p -split ';') -notcontains $Repo) { [Environment]::SetEnvironmentVariable('Path', ($p.TrimEnd(';') + ";$Repo"), 'User') }
$Conf = Join-Path $env:APPDATA 'claude-box'; New-Item -ItemType Directory -Force $Conf | Out-Null
if (-not (Test-Path "$Conf\packages")) { Copy-Item "$Repo\packages.default" "$Conf\packages" }
if (-not (Test-Path "$Conf\network")) { Copy-Item "$Repo\network.default" "$Conf\network" }
Write-Host "installed: $Repo on PATH (open a new terminal)   packages: $Conf\packages"
