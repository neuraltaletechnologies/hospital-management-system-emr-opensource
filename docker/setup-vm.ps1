#Requires -RunAsAdministrator
<#
    Bootstraps a fresh Windows Server 2022 VM to build & run the Danphe EMR container.
    Installs: the Windows Containers feature + Docker CE (Microsoft's installer), git, and
    sets git long-paths.

    Run in an ELEVATED PowerShell on the VM:
        Set-ExecutionPolicy Bypass -Scope Process -Force
        iwr https://raw.githubusercontent.com/<your-fork>/master/docker/setup-vm.ps1 -OutFile setup-vm.ps1
        .\setup-vm.ps1

    NOTE: the Docker install reboots the VM once and resumes automatically. Your RDP
    session will drop - reconnect after ~2 min and, if 'docker version' still fails,
    just run this script again.
#>
$ErrorActionPreference = 'Stop'

Write-Host "`n[1/3] Docker CE + Windows Containers feature" -ForegroundColor White
if (Get-Command docker -ErrorAction SilentlyContinue) {
    docker version --format '  already installed: server {{.Server.Version}} ({{.Server.Os}})'
} else {
    $script = "$env:TEMP\install-docker-ce.ps1"
    Invoke-WebRequest -UseBasicParsing `
        'https://raw.githubusercontent.com/microsoft/Windows-Containers/Main/helpful_tools/Install-DockerCE/install-docker-ce.ps1' `
        -OutFile $script
    Write-Host "  running Microsoft's install-docker-ce.ps1 (this reboots once and resumes)..." -ForegroundColor Cyan
    & $script
}

Write-Host "`n[2/3] Chocolatey + git" -ForegroundColor White
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = 3072
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    choco install -y --no-progress git
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
}
git config --global core.longpaths true

Write-Host "`n[3/3] done" -ForegroundColor White
Write-Host @"

Next (normal PowerShell is fine):

  git clone https://github.com/neuraltaletechnologies/hospital-management-system-emr-opensource.git C:\danphe
  cd C:\danphe
  .\docker\build.ps1        # 30-50 min
  .\docker\run.ps1          # then open http://localhost:8080/  (admin / pass123)

If 'docker version' errors here, the reboot from step 1 is still pending -
reconnect RDP and re-run this script.
"@ -ForegroundColor Green
