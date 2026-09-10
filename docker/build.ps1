<#
    Builds the Danphe EMR all-in-one Windows container image.
    Run from an elevated PowerShell (Docker Desktop must be in *Windows containers* mode).

      .\docker\build.ps1                 # normal build
      .\docker\build.ps1 -NoCache        # rebuild from scratch
      .\docker\build.ps1 -WindowsTag ltsc2019   # older base (needs -Isolation hyperv)
#>
[CmdletBinding()]
param(
    [string]$Tag        = 'danphe-emr:local',
    [string]$WindowsTag = 'ltsc2022',
    [switch]$NoCache
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
Set-Location $repoRoot

# --- locate Docker Desktop's DockerCli.exe (per-user or per-machine install) --
function Get-DockerCli {
    @(
        "$env:LOCALAPPDATA\Programs\DockerDesktop\DockerCli.exe"
        "$env:ProgramFiles\Docker\Docker\DockerCli.exe"
        "$env:ProgramFiles\Docker\Docker\resources\DockerCli.exe"
        "${env:ProgramFiles(x86)}\Docker\Docker\DockerCli.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}

# --- make sure the Docker daemon is in Windows-container mode ----------------
$serverOs = (& docker version --format '{{.Server.Os}}' 2>$null)
if ($serverOs -ne 'windows') {
    Write-Warning "Docker is in '$serverOs' container mode - this image needs Windows containers."
    $cli = Get-DockerCli
    if (-not $cli) {
        throw "DockerCli.exe not found. Switch via the Docker tray icon -> 'Switch to Windows containers...' and re-run."
    }
    Write-Host "Switching Docker Desktop to the Windows engine ($cli)..." -ForegroundColor Cyan
    & $cli -SwitchWindowsEngine
    Start-Sleep -Seconds 10
    $serverOs = (& docker version --format '{{.Server.Os}}' 2>$null)

    if ($serverOs -ne 'windows') {
        Write-Host ""
        Write-Warning @"
Still in '$serverOs' mode. The switch usually fails for one of these reasons:

  1. Docker Desktop's 'containerd image store' is ON (Settings -> General ->
     uncheck 'Use containerd for pulling and storing images' -> Apply & restart).
     Windows containers are NOT supported with the containerd store.

  2. The Windows 'Containers' feature is not enabled.

Run (as Administrator):   .\docker\enable-windows-containers.ps1
then reboot if it asks, start Docker Desktop, and re-run this script.
"@
        throw "Docker is not in Windows-container mode."
    }
}
Write-Host "Docker daemon OS: $serverOs" -ForegroundColor Green

# --- build -----------------------------------------------------------------
$dockerArgs = [System.Collections.Generic.List[string]]@(
    'build'
    '-f', 'docker/Dockerfile'
    '-t', $Tag
    '--build-arg', "WINDOWS_TAG=$WindowsTag"
    '--memory', '8g'          # ng build / MSBuild are memory-hungry
)
if ($NoCache) { $dockerArgs.Add('--no-cache') }
$dockerArgs.Add('.')

Write-Host "docker $($dockerArgs -join ' ')" -ForegroundColor DarkGray
& docker $dockerArgs
if ($LASTEXITCODE -ne 0) { throw "docker build failed ($LASTEXITCODE)" }

Write-Host ""
Write-Host "Built $Tag.  Start it with:  .\docker\run.ps1" -ForegroundColor Green
