# Run Danphe EMR on a throwaway cloud Windows VM

Builds and runs the all-in-one Windows container on a rented Windows Server 2022 VM, so
your local Docker (Odoo / Omada / Postgres / …) is never touched. RDP in and use the app
in the VM's browser. Delete the VM when done — billing stops.

**Rough cost:** `Standard_D4s_v5` ≈ **$0.40/hr** all-in (compute + Windows licence + disk);
`Standard_D8s_v5` ≈ $0.80/hr and builds ~2× faster. A first build + a few hours of use ≈ **$3–6**.

---

## 0. Push the docker/ files to your fork

The `docker/` folder and `.dockerignore` are new and uncommitted. From your **local** machine:

```powershell
cd C:\Am_jhey\Github\hospital-management-system-emr-opensource
git add docker .dockerignore CLAUDE.md
git commit -m "Add Windows-container setup for Danphe EMR"
git push origin master
```

(If your fork is private, you'll also need a GitHub Personal Access Token when you `git clone` on the VM.)

---

## 1. Create the VM

### AWS (EC2) — use `docker/aws-vm.ps1`

From your **local** machine (AWS CLI already configured):

```powershell
cd C:\Am_jhey\Github\hospital-management-system-emr-opensource
.\docker\aws-vm.ps1                    # m5.xlarge, 256 GB, RDP locked to your IP
#   -Size m5.2xlarge   for a ~2x faster build (~$0.57/hr vs ~$0.30/hr in eu-central-1)
```

It resolves the latest Windows Server 2022 AMI, creates a key pair (`docker/danphe-emr-key.pem`)
and a security group (RDP from your current IP only), launches the instance, and prints the
**RDP host / Administrator / password**. `.\docker\aws-vm.ps1 -Info` reprints them later.

Needs a default VPC in the region (`aws ec2 describe-vpcs --filters Name=isDefault,Values=true`).
Uses your default region (`eu-central-1`); override with `-Region`.

> You're authenticated as the account **root user**. Fine for a one-off, but consider an IAM
> user with `AmazonEC2FullAccess` instead of root access keys.

Then skip to **step 2**.

### Azure (CLI) — alternative

Install [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli-windows) locally, `az login`, then:

```powershell
$RG   = "danphe-emr-rg"
$LOC  = "eastus"
$PASS = "ChangeMe_$(Get-Random)!aA9"          # save this - it's the RDP password
Write-Host "RDP password: $PASS"

az group create -n $RG -l $LOC

az vm create -g $RG -n danphe-vm `
  --image MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest `
  --size Standard_D4s_v5 `
  --admin-username azureuser --admin-password $PASS `
  --os-disk-size-gb 256 `
  --public-ip-sku Standard --nsg-rule RDP

# lock RDP down to your current public IP
$myip = (Invoke-RestMethod https://api.ipify.org)
az network nsg rule update -g $RG --nsg-name danphe-vmNSG -n rdp --source-address-prefixes "$myip/32"

# connection address
az vm show -d -g $RG -n danphe-vm --query publicIps -o tsv
```

No Azure CLI? Do the same in the **Azure Portal**: *Create a resource → Virtual machine*,
Image **Windows Server 2022 Datacenter: Azure Edition**, Size **D4s_v5**, OS disk **256 GB**,
Inbound port **RDP (3389)**. After it's created, restrict the RDP NSG rule to your IP.

---

## 2. RDP in and bootstrap

`mstsc /v:<public-ip>` → **AWS:** user `Administrator` + the password `aws-vm.ps1` printed.
**Azure:** user `azureuser` + the password you saved.

In an **elevated PowerShell** on the VM:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
iwr https://raw.githubusercontent.com/neuraltaletechnologies/hospital-management-system-emr-opensource/master/docker/setup-vm.ps1 -OutFile setup-vm.ps1
.\setup-vm.ps1
```

`setup-vm.ps1` installs Docker CE + the Containers feature (Microsoft's installer — **it
reboots the VM once**; reconnect RDP after ~2 min and re-run the script if `docker version`
still errors), then git.

---

## 3. Build & run

```powershell
git clone https://github.com/neuraltaletechnologies/hospital-management-system-emr-opensource.git C:\danphe
cd C:\danphe
.\docker\build.ps1        # 30-50 min on D4s_v5
.\docker\run.ps1          # first start restores the DBs (~3-6 min)
```

Then in the VM's browser (Edge is preinstalled): **http://localhost:8080/** → `admin` / `pass123`.

`build.ps1` will notice Docker is already in Windows mode and skip the engine switch — the
Docker-Desktop-specific steps (`enable-windows-containers.ps1`, containerd toggle) do **not**
apply on a Windows Server VM.

### See the app from your own browser (optional)

Simplest is to just use it inside the RDP session (Edge is preinstalled). To reach it from your
own machine instead, open port 8080 on the VM **and** in the cloud firewall:

```powershell
# on the VM
New-NetFirewallRule -DisplayName "danphe-8080" -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow
```
```powershell
# locally - AWS
$sg = (aws ec2 describe-security-groups --group-names danphe-emr-sg --query 'SecurityGroups[0].GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 8080 `
  --cidr "$((Invoke-RestMethod https://checkip.amazonaws.com).Trim())/32"

# locally - Azure
az network nsg rule create -g danphe-emr-rg --nsg-name danphe-vmNSG -n app `
  --priority 1010 --destination-port-ranges 8080 --access Allow --protocol Tcp `
  --source-address-prefixes "$((Invoke-RestMethod https://api.ipify.org))/32"
```
then browse to `http://<public-ip>:8080/`.

---

## 4. Pause / tear down

**AWS:**
```powershell
.\docker\aws-vm.ps1 -Terminate          # deletes instance + security group + key pair

# or just stop it to resume later (still pay ~$0.02/hr for the 256 GB disk):
aws ec2 stop-instances  --instance-ids <id>
aws ec2 start-instances --instance-ids <id>
```

**Azure:**
```powershell
az vm deallocate -g danphe-emr-rg -n danphe-vm     # stop compute charges (keeps the disk)
az vm start      -g danphe-emr-rg -n danphe-vm     # resume later
az group delete  -n danphe-emr-rg --yes --no-wait  # DELETE EVERYTHING - billing stops
```

The container's databases live on a Docker volume **inside the VM**, so terminating the instance
removes them too. To keep a built image: `docker save danphe-emr:local -o C:\danphe.tar` and copy
it off the VM first.
