<#
    Provision (or tear down) a throwaway AWS EC2 Windows Server 2022 instance to build
    and run the Danphe EMR container. Nothing on your local machine is touched.

      .\docker\aws-vm.ps1                 # create; prints RDP host / user / password
      .\docker\aws-vm.ps1 -Size m5.2xlarge   # bigger box, ~2x faster build
      .\docker\aws-vm.ps1 -Info           # show connection details again
      .\docker\aws-vm.ps1 -Terminate      # delete instance + security group + key pair

    Requires the AWS CLI, already configured (`aws sts get-caller-identity` works).
    Cost in eu-central-1: m5.xlarge Windows ~= $0.30/hr, m5.2xlarge ~= $0.57/hr (+ ~$0.02/hr for the 256 GB disk).
#>
[CmdletBinding()]
param(
    [string]$Name       = 'danphe-emr',
    [string]$Size       = 'm5.xlarge',
    [int]   $DiskGB     = 256,
    [string]$Region     = '',
    [switch]$Info,
    [switch]$Terminate
)

$ErrorActionPreference = 'Stop'

# --- locate aws.exe -------------------------------------------------------
$aws = (Get-Command aws -ErrorAction SilentlyContinue).Source
if (-not $aws) {
    $aws = @(
        "$env:LOCALAPPDATA\Programs\Amazon\AWSCLIV2\aws.exe"
        "$env:ProgramFiles\Amazon\AWSCLIV2\aws.exe"
        "${env:ProgramFiles(x86)}\Amazon\AWSCLIV2\aws.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $aws) { throw "aws.exe not found. Install the AWS CLI v2." }
Set-Alias -Name aws -Value $aws -Scope Script

$regionArg = @()
if ($Region) { $regionArg = @('--region', $Region) }

$keyName  = "$Name-key"
$sgName   = "$Name-sg"
$pemPath  = Join-Path $PSScriptRoot "$Name.pem"
$tagFilter = "Name=tag:Name,Values=$Name", "Name=instance-state-name,Values=pending,running,stopping,stopped"

function Get-InstanceId {
    aws @regionArg ec2 describe-instances --filters $tagFilter `
        --query 'Reservations[].Instances[0].InstanceId' --output text
}

# ======================================================================
# TEARDOWN
# ======================================================================
if ($Terminate) {
    $iid = Get-InstanceId
    if ($iid -and $iid -ne 'None') {
        Write-Host "Terminating $iid ..." -ForegroundColor Yellow
        aws @regionArg ec2 terminate-instances --instance-ids $iid | Out-Null
        aws @regionArg ec2 wait instance-terminated --instance-ids $iid
    }
    aws @regionArg ec2 delete-security-group --group-name $sgName 2>$null | Out-Null
    aws @regionArg ec2 delete-key-pair --key-name $keyName 2>$null | Out-Null
    Remove-Item $pemPath -ErrorAction SilentlyContinue
    Write-Host "Done. All $Name resources removed." -ForegroundColor Green
    return
}

# ======================================================================
# INFO
# ======================================================================
if ($Info) {
    $iid = Get-InstanceId
    if (-not $iid -or $iid -eq 'None') { throw "No instance tagged '$Name' found." }
    $ip  = aws @regionArg ec2 describe-instances --instance-ids $iid --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
    $pw  = aws @regionArg ec2 get-password-data --instance-id $iid --priv-launch-key $pemPath --query 'PasswordData' --output text
    Write-Host "`n  RDP host : $ip"       -ForegroundColor Cyan
    Write-Host "  user     : Administrator"
    Write-Host "  password : $pw"
    Write-Host "`n  mstsc /v:$ip`n"
    return
}

# ======================================================================
# CREATE
# ======================================================================
if ((Get-InstanceId) -notin @($null, '', 'None')) {
    throw "An instance tagged '$Name' already exists. Use -Info or -Terminate."
}

Write-Host "[1/5] resolving latest Windows Server 2022 AMI..." -ForegroundColor White
$ami = aws @regionArg ssm get-parameter `
    --name /aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base `
    --query 'Parameter.Value' --output text
Write-Host "      $ami"

Write-Host "[2/5] key pair -> $pemPath" -ForegroundColor White
aws @regionArg ec2 delete-key-pair --key-name $keyName 2>$null | Out-Null
aws @regionArg ec2 create-key-pair --key-name $keyName --query 'KeyMaterial' --output text | Set-Content $pemPath -Encoding ascii

Write-Host "[3/5] security group (RDP from your IP only)" -ForegroundColor White
$myip = (Invoke-RestMethod 'https://checkip.amazonaws.com').Trim()
$sgId = aws @regionArg ec2 create-security-group --group-name $sgName `
    --description "Danphe EMR throwaway VM" --query 'GroupId' --output text
aws @regionArg ec2 authorize-security-group-ingress --group-id $sgId `
    --protocol tcp --port 3389 --cidr "$myip/32" | Out-Null
Write-Host "      $sgId  (RDP <- $myip/32)"

Write-Host "[4/5] launching $Size with a $DiskGB GB gp3 disk..." -ForegroundColor White
$iid = aws @regionArg ec2 run-instances `
    --image-id $ami --instance-type $Size --key-name $keyName --security-group-ids $sgId `
    --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$DiskGB,VolumeType=gp3}" `
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$Name}]" `
    --query 'Instances[0].InstanceId' --output text
Write-Host "      $iid - waiting for it to boot..."
aws @regionArg ec2 wait instance-running --instance-ids $iid

Write-Host "[5/5] waiting for the Windows password (~4 min)..." -ForegroundColor White
aws @regionArg ec2 wait password-data-available --instance-ids $iid
$pw = aws @regionArg ec2 get-password-data --instance-id $iid --priv-launch-key $pemPath --query 'PasswordData' --output text
$ip = aws @regionArg ec2 describe-instances --instance-ids $iid --query 'Reservations[0].Instances[0].PublicIpAddress' --output text

Write-Host "`n=======================================================" -ForegroundColor Green
Write-Host "  RDP host : $ip"
Write-Host "  user     : Administrator"
Write-Host "  password : $pw"
Write-Host "=======================================================" -ForegroundColor Green
Write-Host @"

Connect:   mstsc /v:$ip

Then, in an ELEVATED PowerShell on the VM:

  Set-ExecutionPolicy Bypass -Scope Process -Force
  iwr https://raw.githubusercontent.com/neuraltaletechnologies/hospital-management-system-emr-opensource/master/docker/setup-vm.ps1 -OutFile setup-vm.ps1
  .\setup-vm.ps1                       # installs Docker + git; reboots once

  git clone https://github.com/neuraltaletechnologies/hospital-management-system-emr-opensource.git C:\danphe
  cd C:\danphe
  .\docker\build.ps1                   # 30-50 min
  .\docker\run.ps1                     # http://localhost:8080/  (admin / pass123)

When finished:   .\docker\aws-vm.ps1 -Terminate
"@
