#Requires -RunAsAdministrator
<#
    Prepares this machine to run the Danphe EMR Windows container.

      1. enables the Windows "Containers" optional feature      (may need a reboot)
      2. enables Microsoft-Hyper-V                              (recommended; may need a reboot)
      3. turns OFF Docker Desktop's containerd image store      (incompatible with Windows containers)
      4. switches Docker Desktop to the Windows engine          (if no reboot is pending)

    Run from an ELEVATED PowerShell:  .\docker\enable-windows-containers.ps1
#>
[CmdletBinding()]
param([switch]$SkipHyperV)

$ErrorActionPreference = 'Stop'
$rebootNeeded = $false

function Enable-Feature([string]$Name) {
    $f = Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction SilentlyContinue
    if (-not $f) { Write-Warning "Feature '$Name' not available on this SKU - skipping."; return }
    if ($f.State -eq 'Enabled') { Write-Host "  $Name : already enabled" -ForegroundColor Green; return }
    Write-Host "  enabling $Name ..." -ForegroundColor Cyan
    $r = Enable-WindowsOptionalFeature -Online -FeatureName $Name -All -NoRestart
    if ($r.RestartNeeded) { $script:rebootNeeded = $true }
}

Write-Host "`n[1/4] Windows optional features" -ForegroundColor White
Enable-Feature 'Containers'
if (-not $SkipHyperV) { Enable-Feature 'Microsoft-Hyper-V' }

Write-Host "`n[2/4] locate Docker Desktop" -ForegroundColor White
$ddDir = @(
    "$env:LOCALAPPDATA\Programs\DockerDesktop"
    "$env:ProgramFiles\Docker\Docker"
) | Where-Object { Test-Path (Join-Path $_ 'DockerCli.exe') } | Select-Object -First 1
if (-not $ddDir) { throw "Docker Desktop (DockerCli.exe) not found." }
$dockerCli = Join-Path $ddDir 'DockerCli.exe'
Write-Host "  $dockerCli" -ForegroundColor Green

Write-Host "`n[3/4] disable containerd image store (blocks Windows containers)" -ForegroundColor White
$settings = @(
    "$env:APPDATA\Docker\settings-store.json"
    "$env:APPDATA\Docker\settings.json"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if ($settings) {
    try {
        $json = Get-Content $settings -Raw | ConvertFrom-Json
        if ($json.PSObject.Properties.Name -contains 'UseContainerdSnapshotter' -and $json.UseContainerdSnapshotter) {
            Write-Host "  shutting down Docker Desktop..." -ForegroundColor Cyan
            & $dockerCli -Shutdown; Start-Sleep -Seconds 6
            $json.UseContainerdSnapshotter = $false
            ($json | ConvertTo-Json -Depth 30) | Set-Content $settings -Encoding UTF8
            Write-Host "  containerd image store: turned OFF" -ForegroundColor Green
        } else {
            Write-Host "  containerd image store: already off" -ForegroundColor Green
        }
    } catch {
        Write-Warning "  couldn't edit $settings automatically ($($_.Exception.Message))."
        Write-Warning "  Do it in the GUI: Docker Desktop -> Settings -> General ->"
        Write-Warning "  uncheck 'Use containerd for pulling and storing images' -> Apply & restart."
    }
} else {
    Write-Warning "  Docker settings file not found - check the containerd toggle manually in Settings -> General."
}

Write-Host "`n[4/4] engine" -ForegroundColor White
if ($rebootNeeded) {
    Write-Warning "REBOOT REQUIRED (Containers/Hyper-V just installed)."
    Write-Host   "After reboot:  start Docker Desktop  ->  run  .\docker\build.ps1" -ForegroundColor Yellow
} else {
    Write-Host "  starting Docker Desktop..." -ForegroundColor Cyan
    Start-Process (Join-Path $ddDir 'Docker Desktop.exe')
    Start-Sleep -Seconds 20
    & $dockerCli -SwitchWindowsEngine
    Start-Sleep -Seconds 10
    $os = (& docker version --format '{{.Server.Os}}' 2>$null)
    if ($os -eq 'windows') { Write-Host "  Docker is now in Windows-container mode. Run  .\docker\build.ps1" -ForegroundColor Green }
    else { Write-Warning "  engine is still '$os' - give Docker Desktop a minute to start, then run: & '$dockerCli' -SwitchWindowsEngine" }
}
