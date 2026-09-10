# Run Danphe EMR on a throwaway cloud Windows VM

Builds and runs the all-in-one Windows container on a rented Windows Server 2022 VM, so
your local Docker (Odoo / Omada / Postgres / ...) is never touched. RDP in and use the app
in the VM's browser. Delete the stack/VM when done and billing stops.

**Cost on the AWS Free plan:** `m7i-flex.large` (2 vCPU / 8 GiB) is free-tier eligible, so a
build plus a few hours of use is drawn from your $100 credits (effectively free). It is a
small box, so the first build takes **~60-90 min**.

---

## 0. Push the docker/ files to your fork

The `docker/` folder and `.dockerignore` are new and uncommitted. From your **local** machine:

```powershell
cd C:\Am_jhey\Github\hospital-management-system-emr-opensource
git add docker .dockerignore CLAUDE.md .gitignore
git commit -m "Add Windows-container + cloud-VM setup"
git push origin master
```

(If your fork is private, you also need a GitHub Personal Access Token when you `git clone` on the VM.)

---

## 1. Create the VM

### AWS (CloudFormation) - `docker/aws/deploy.ps1`

From your **local** machine (AWS CLI configured, default VPC present):

```powershell
cd C:\Am_jhey\Github\hospital-management-system-emr-opensource
.\docker\aws\deploy.ps1
#   -InstanceType c5.2xlarge   only after upgrading the account to the Paid plan
```

`deploy.ps1` finds your default VPC/subnet and public IP, then deploys the
**`docker/aws/danphe-emr-vm.yaml`** stack: one `m7i-flex.large` Windows Server 2022 instance,
RDP restricted to your `/32`, IMDSv2 required, encrypted 256 GiB root, SSM enabled. It fetches
the auto-generated private key from SSM to `docker/aws/danphe-emr.pem` (git-ignored) and prints
**RDP host / Administrator / password**. Reprint later with `.\docker\aws\deploy.ps1 -Info`.

Tear down with `.\docker\aws\deploy.ps1 -Delete` (deletes the whole stack).

### Azure (CLI) - alternative

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

`mstsc /v:<public-ip>` -> **AWS:** user `Administrator` + the password `deploy.ps1` printed.
**Azure:** user `azureuser` + the password you saved.

In an **elevated PowerShell** on the VM:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
iwr https://raw.githubusercontent.com/neuraltaletechnologies/hospital-management-system-emr-opensource/master/docker/setup-vm.ps1 -OutFile setup-vm.ps1
.\setup-vm.ps1
```

`setup-vm.ps1` installs Docker CE and git. On the AWS box the Containers feature is already on
(the CloudFormation UserData enabled it and rebooted once before you connected), so no further
reboot. If `docker version` errors, wait ~1 min for that reboot to finish and re-run the script.

---

## 3. Build & run

```powershell
git clone https://github.com/neuraltaletechnologies/hospital-management-system-emr-opensource.git C:\danphe
cd C:\danphe
.\docker\build.ps1        # ~60-90 min on m7i-flex.large (2 vCPU)
.\docker\run.ps1          # first start restores the DBs (~5-10 min on this box)
```

Then in the VM's browser (Edge is preinstalled): **http://localhost:8080/** -> `admin` / `pass123`.

`build.ps1` notices Docker is already in Windows mode and skips the engine switch. The
Docker-Desktop-only steps (`enable-windows-containers.ps1`, the containerd toggle) do **not**
apply on a Windows Server VM. `build.ps1` caps the Angular build heap at 4 GiB (`-NgHeapMB`)
so it fits in 8 GiB.

### See the app from your own browser (optional)

Simplest is to just use it inside the RDP session (Edge is preinstalled). To reach it from your
own machine instead, open port 8080 on the VM **and** in the cloud firewall:

```powershell
# on the VM
New-NetFirewallRule -DisplayName "danphe-8080" -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow
```
```powershell
# locally - AWS (add 8080 to the stack's security group, from your IP)
$sg = (aws cloudformation describe-stack-resources --stack-name danphe-emr `
  --logical-resource-id SecurityGroup --query 'StackResources[0].PhysicalResourceId' --output text)
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
.\docker\aws\deploy.ps1 -Delete                    # delete the whole stack - billing stops

# or just stop the instance to resume later (still pay ~$0.02/hr for the 256 GiB disk):
$id = (aws cloudformation describe-stacks --stack-name danphe-emr `
       --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text)
aws ec2 stop-instances  --instance-ids $id
aws ec2 start-instances --instance-ids $id
```

**Azure:**
```powershell
az vm deallocate -g danphe-emr-rg -n danphe-vm     # stop compute charges (keeps the disk)
az vm start      -g danphe-emr-rg -n danphe-vm     # resume later
az group delete  -n danphe-emr-rg --yes --no-wait  # DELETE EVERYTHING, billing stops
```

The container's databases live on a Docker volume **inside the VM**, so deleting the stack
removes them too. To keep a built image: `docker save danphe-emr:local -o C:\danphe.tar` and
copy it off the VM first.
