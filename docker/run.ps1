<#
    Starts (or restarts) the Danphe EMR container.

      .\docker\run.ps1              # start, then follow logs
      .\docker\run.ps1 -Fresh      # drop the DB volume and re-restore from seed
      .\docker\run.ps1 -Port 9000  # publish on a different host port

    App:  http://localhost:<Port>/   (default 8080)   login  admin / pass123
#>
[CmdletBinding()]
param(
    [string]$Tag       = 'danphe-emr:local',
    [string]$Name      = 'danphe-emr',
    [int]   $Port      = 8080,
    [string]$Volume    = 'danphe-emr-data',
    [string]$Memory    = '8g',
    [switch]$Fresh
)

$ErrorActionPreference = 'Stop'

& docker rm -f $Name 2>$null | Out-Null

if ($Fresh) {
    Write-Host "Removing volume '$Volume' (databases will be rebuilt from seed)..." -ForegroundColor Yellow
    & docker volume rm $Volume 2>$null | Out-Null
}
& docker volume create $Volume | Out-Null

Write-Host "Starting $Name ..." -ForegroundColor Cyan
& docker run -d `
    --name $Name `
    --memory $Memory `
    -p "${Port}:80" `
    -v "${Volume}:C:\data" `
    --restart unless-stopped `
    $Tag
if ($LASTEXITCODE -ne 0) { throw "docker run failed ($LASTEXITCODE)" }

Write-Host ""
Write-Host "First start restores DanpheAdmin + the EMR database (~2-6 min)." -ForegroundColor Gray
Write-Host "Watch progress below; when you see 'Now listening on: http://[::]:80' it is ready." -ForegroundColor Gray
Write-Host "  ->  http://localhost:$Port/    (admin / pass123)" -ForegroundColor Green
Write-Host "  (Ctrl+C just stops the log tail, not the container.)" -ForegroundColor DarkGray
Write-Host ""
& docker logs -f $Name
