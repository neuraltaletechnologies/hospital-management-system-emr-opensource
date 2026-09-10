<#
    Deploy (or delete) the Danphe EMR build VM as a CloudFormation stack.

      .\docker\aws\deploy.ps1                 # create the stack, print RDP host / user / password
      .\docker\aws\deploy.ps1 -Info           # reprint connection details
      .\docker\aws\deploy.ps1 -InstanceType c5.2xlarge   # only works after upgrading to the Paid plan
      .\docker\aws\deploy.ps1 -Delete         # delete the stack (removes instance, SG, key pair, role)

    Needs the AWS CLI configured (`aws sts get-caller-identity` works) and a default VPC.
#>
[CmdletBinding()]
param(
    [string]$Stack         = 'danphe-emr',
    [string]$InstanceType  = 'm7i-flex.large',
    [int]   $RootVolumeGiB = 256,
    [string]$Region        = '',
    [switch]$Info,
    [switch]$Delete
)

$ErrorActionPreference = 'Stop'
$templatePath = Join-Path $PSScriptRoot 'danphe-emr-vm.yaml'
$pemPath      = Join-Path $PSScriptRoot "$Stack.pem"

# --- aws.exe -------------------------------------------------------------
$awsExe = (Get-Command aws -ErrorAction SilentlyContinue).Source
if (-not $awsExe) {
    $awsExe = @(
        "$env:LOCALAPPDATA\Programs\Amazon\AWSCLIV2\aws.exe"
        "$env:ProgramFiles\Amazon\AWSCLIV2\aws.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $awsExe) { throw "aws.exe not found. Install AWS CLI v2." }
if ($Region) { $env:AWS_REGION = $Region; $env:AWS_DEFAULT_REGION = $Region }

# Wrapper: run aws.exe, throw on non-zero, return trimmed stdout.
function Invoke-AwsRaw {
    param([Parameter(ValueFromRemainingArguments)] [string[]] $Args)
    $out = & $awsExe @Args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "aws $($Args -join ' ')`n$out" }
    ($out | Out-String).Trim()
}

function Get-Outputs {
    $j = & $awsExe cloudformation describe-stacks --stack-name $Stack --query 'Stacks[0].Outputs' --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $j) { return $null }
    $o = @{}; ($j | ConvertFrom-Json) | ForEach-Object { $o[$_.OutputKey] = $_.OutputValue }
    $o
}

function Show-Access {
    $o = Get-Outputs
    if (-not $o) { throw "Stack '$Stack' has no outputs yet." }
    if (-not (Test-Path $pemPath)) {
        Write-Host "Fetching private key -> $pemPath" -ForegroundColor Cyan
        Invoke-AwsRaw ssm get-parameter --name $o.PrivateKeyParameter --with-decryption --query 'Parameter.Value' --output text |
            Set-Content $pemPath -Encoding ascii
    }
    Write-Host "Waiting for the Windows password (~4 min after first boot)..." -ForegroundColor Cyan
    & $awsExe ec2 wait password-data-available --instance-ids $o.InstanceId
    $pw = Invoke-AwsRaw ec2 get-password-data --instance-id $o.InstanceId --priv-launch-key $pemPath --query 'PasswordData' --output text
    $ip = Invoke-AwsRaw ec2 describe-instances --instance-ids $o.InstanceId --query 'Reservations[0].Instances[0].PublicIpAddress' --output text

    Write-Host "`n=======================================================" -ForegroundColor Green
    Write-Host "  RDP host : $ip"
    Write-Host "  user     : Administrator"
    Write-Host "  password : $pw"
    Write-Host "  connect  : mstsc /v:$ip"
    Write-Host "=======================================================" -ForegroundColor Green
    Write-Host @"

On the VM, elevated PowerShell:

  Set-ExecutionPolicy Bypass -Scope Process -Force
  iwr https://raw.githubusercontent.com/neuraltaletechnologies/hospital-management-system-emr-opensource/master/docker/setup-vm.ps1 -OutFile setup-vm.ps1
  .\setup-vm.ps1

  git clone https://github.com/neuraltaletechnologies/hospital-management-system-emr-opensource.git C:\danphe
  cd C:\danphe
  .\docker\build.ps1        # ~60-90 min on m7i-flex.large
  .\docker\run.ps1          # http://localhost:8080/  (admin / pass123)

Tear down when finished:   .\docker\aws\deploy.ps1 -Delete
"@
}

# ======================================================================
if ($Delete) {
    Write-Host "Deleting stack '$Stack'..." -ForegroundColor Yellow
    & $awsExe cloudformation delete-stack --stack-name $Stack
    & $awsExe cloudformation wait stack-delete-complete --stack-name $Stack
    Remove-Item $pemPath -ErrorAction SilentlyContinue
    Write-Host "Stack deleted. Nothing left to pay for." -ForegroundColor Green
    return
}

if ($Info) { Show-Access; return }

# --- create ---------------------------------------------------------
$status = & $awsExe cloudformation describe-stacks --stack-name $Stack --query 'Stacks[0].StackStatus' --output text 2>$null
if ($LASTEXITCODE -eq 0 -and $status) {
    throw "Stack '$Stack' already exists ($status). Use -Info, or -Delete first."
}

Write-Host "[1/4] discovering default VPC + subnet + your public IP" -ForegroundColor White
$vpc = Invoke-AwsRaw ec2 describe-vpcs --filters 'Name=isDefault,Values=true' --query 'Vpcs[0].VpcId' --output text
if (-not $vpc -or $vpc -eq 'None') {
    throw "No default VPC in this region. Create one with:  aws ec2 create-default-vpc"
}
$subnet = Invoke-AwsRaw ec2 describe-subnets `
    --filters "Name=vpc-id,Values=$vpc" 'Name=default-for-az,Values=true' `
    --query 'Subnets[0].SubnetId' --output text
$myip = (Invoke-RestMethod 'https://checkip.amazonaws.com').Trim()
Write-Host "      vpc=$vpc  subnet=$subnet  cidr=$myip/32" -ForegroundColor Green

Write-Host "[2/4] creating stack '$Stack' ($InstanceType)" -ForegroundColor White
Invoke-AwsRaw cloudformation create-stack --stack-name $Stack `
    --template-body "file://$templatePath" `
    --capabilities CAPABILITY_IAM `
    --on-failure DO_NOTHING `
    --parameters `
        "ParameterKey=AllowedCidr,ParameterValue=$myip/32" `
        "ParameterKey=InstanceType,ParameterValue=$InstanceType" `
        "ParameterKey=RootVolumeGiB,ParameterValue=$RootVolumeGiB" `
        "ParameterKey=VpcId,ParameterValue=$vpc" `
        "ParameterKey=SubnetId,ParameterValue=$subnet" | Out-Null

Write-Host "[3/4] waiting for the stack to finish (~3-5 min)..." -ForegroundColor White
& $awsExe cloudformation wait stack-create-complete --stack-name $Stack
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Stack did not reach CREATE_COMPLETE. Failed resources:"
    & $awsExe cloudformation describe-stack-events --stack-name $Stack `
        --query "StackEvents[?ends_with(ResourceStatus, 'FAILED')].[LogicalResourceId, ResourceStatusReason]" `
        --output text
    Write-Host "`nInspect, then clean up with:  .\docker\aws\deploy.ps1 -Delete" -ForegroundColor Yellow
    throw "create-stack failed."
}

Write-Host "[4/4] connection details" -ForegroundColor White
Show-Access
