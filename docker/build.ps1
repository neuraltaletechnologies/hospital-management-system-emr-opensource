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

# --- make sure the Docker daemon is in Windows-container mode ----------------
$serverOs = (& docker version --format '{{.Server.Os}}' 2>$null)
if ($serverOs -ne 'windows') {
    Write-Warning "Docker is currently in '$serverOs' container mode - Windows containers are required."
    $cli = "$env:ProgramFiles\Docker\Docker\DockerCli.exe"
    if (Test-Path $cli) {
        Write-Host 'Switching Docker Desktop to Windows containers...' -ForegroundColor Cyan
        & $cli -SwitchWindowsEngine
        Start-Sleep -Seconds 8
        $serverOs = (& docker version --format '{{.Server.Os}}' 2>$null)
    }
    if ($serverOs -ne 'windows') {
        throw "Could not switch to Windows containers. Right-click the Docker tray icon -> 'Switch to Windows containers...', then re-run this script."
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
