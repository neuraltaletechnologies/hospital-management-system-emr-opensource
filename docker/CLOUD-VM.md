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

## 1. Create the VM (Azure CLI)

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

> AWS equivalent: EC2, AMI *"Microsoft Windows Server 2022 Base"*, `t3.xlarge` or `m5.xlarge`,
> 256 GB gp3 root volume, security group RDP from your IP.

---

## 2. RDP in and bootstrap

`mstsc /v:<public-ip>` → user `azureuser`, the password you saved.

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

Either keep using it inside the RDP session, or open port 8080:

```powershell
# on the VM
New-NetFirewallRule -DisplayName "danphe-8080" -Direction Inbound -Protocol TCP -LocalPort 8080 -Action Allow
```
```powershell
# locally
az network nsg rule create -g danphe-emr-rg --nsg-name danphe-vmNSG -n app `
  --priority 1010 --destination-port-ranges 8080 --access Allow --protocol Tcp `
  --source-address-prefixes "$((Invoke-RestMethod https://api.ipify.org))/32"
```
then browse to `http://<public-ip>:8080/`.

---

## 4. Pause / tear down

```powershell
az vm deallocate -g danphe-emr-rg -n danphe-vm     # stop compute charges (keeps the disk ~$12/mo)
az vm start      -g danphe-emr-rg -n danphe-vm     # resume later

az group delete  -n danphe-emr-rg --yes --no-wait  # DELETE EVERYTHING - billing stops
```

The container's databases live on a Docker volume **inside the VM**, so `az group delete`
removes them too. If you want to keep a built image, `docker save danphe-emr:local -o C:\danphe.tar`
and copy it off the VM before deleting.
