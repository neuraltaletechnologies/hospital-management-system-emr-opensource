# Danphe EMR — containerized (all-in-one Windows image)

Runs the whole stack in **one Windows container** so nothing lands on your host:

```
[ Windows container ]
  SQL Server 2019 Express  (.\SQLEXPRESS, sa auth)   <- user DBs in C:\data (volume)
  DanpheEMR.exe            (ASP.NET Core 2.0 / .NET Framework 4.6.1, Kestrel :80)
  wwwroot/DanpheApp/dist   (prebuilt Angular 7 bundle)
```

The **only** host-level change is enabling the Windows *Containers* feature (Docker Desktop does this).

---

## Why it has to be a Windows container

The backend targets **.NET Framework 4.6.1** and references Windows-only assemblies
(`System.Web`, `System.Drawing`, `WindowsBase`, `Syncfusion.XlsIO.WinForms`, EF6).
.NET Framework does not run on Linux — so no Linux container, no WSL, no macOS.

## Requirements

| | |
|---|---|
| Host OS | Windows 10 21H2+ / Windows 11 (you have 11 Pro ✅) |
| RAM | 8 GB free for the container (you have 31 GB ✅) |
| Disk | **~45 GB free** during the first build — base images are big (you have 177 GB ✅) |
| Docker Desktop | installed, with **Windows containers** enabled |
| Time | first build **30–50 min** (pulls ~15 GB, restores NuGet, `npm install`, MSBuild, `ng build`). Rebuilds are cached and fast. |

## One-time: enable Windows containers

From an **elevated PowerShell** at the repo root:

```powershell
.\docker\enable-windows-containers.ps1
```

It does the three things Windows containers need:

1. enables the Windows **Containers** feature (and Hyper-V) — **reboot** if it says so
2. turns **off** Docker Desktop's *containerd image store* — Windows containers do **not**
   work with it (Settings → General → "Use containerd for pulling and storing images")
3. switches Docker Desktop to the **Windows engine**

Your Linux containers just pause while in Windows mode; switch back any time with the Docker
tray icon → *"Switch to Linux containers…"* (or `DockerCli.exe -SwitchLinuxEngine`).

After a reboot: start Docker Desktop, then run `.\docker\build.ps1`.

## Build & run

From the repo root, in an **elevated PowerShell**:

```powershell
.\docker\build.ps1          # builds  danphe-emr:local
.\docker\run.ps1            # starts it, publishes http://localhost:8080, tails the log
```

When the log shows `Now listening on: http://[::]:80`, open:

**http://localhost:8080/**  →  log in with **admin / pass123**

Useful variants:

```powershell
.\docker\build.ps1 -NoCache            # clean rebuild
.\docker\run.ps1 -Port 9000            # different host port
.\docker\run.ps1 -Fresh               # wipe the DB volume and re-restore from the seed files
docker stop danphe-emr                 # stop
docker start danphe-emr                # start again (DBs persist in the volume)
docker logs -f danphe-emr              # follow logs
docker exec -it danphe-emr powershell  # shell inside the container
```

## Data persistence

User databases (`DanpheAdmin`, `Dev_DanpheEMR_INT1`) live in the named volume
**`danphe-emr-data`** mounted at `C:\data`. They survive `docker stop/start` and image
rebuilds. `run.ps1 -Fresh` deletes the volume and the next start rebuilds both DBs from
`Database/1. Admin-Db/*.sql` and `Database/2. EMR-Db/**/*.zip`.

## What the container does on first start (`entrypoint.ps1`)

1. start SQL Server Express, point default data/log dirs at `C:\data`
2. run `1. DanpheAdmin_CompleteDB.sql` → creates `DanpheAdmin` (skipped if it exists)
3. unzip `Dev_DanpheEMR_INT1.zip`, `RESTORE DATABASE` with auto `MOVE` → `Dev_DanpheEMR_INT1` (skipped if it exists)
4. launch `DanpheEMR.exe`

---

## Troubleshooting

This is a 2019-era stack; the first build may need a nudge. Common spots:

| Symptom | Fix |
|---|---|
| `build.ps1`: *"Could not switch to Windows containers"* | Switch manually via the Docker tray icon; confirm `docker version` shows `Server: … OS/Arch: windows/amd64`. |
| Base image pull errors / very slow | `docker pull mcr.microsoft.com/dotnet/framework/sdk:4.8-windowsservercore-ltsc2022` on its own first; retry. |
| Host is Windows 10 or older build → container won't start | build with `.\docker\build.ps1 -WindowsTag ltsc2019` and run with `docker run --isolation=hyperv …` (edit `run.ps1`). |
| MSBuild: *"reference assemblies for .NETFramework,Version=v4.6.1 were not found"* | add to the **build** stage before the `msbuild` line: `RUN nuget install Microsoft.NETFramework.ReferenceAssemblies.net461 -Version 1.0.3 -OutputDirectory C:\refpacks` and pass `/p:FrameworkPathOverride=…`, **or** retarget: `/p:TargetFrameworkVersion=v4.8`. |
| `npm install` fails on `node-sass` / `node-gyp` | it's an optional dep — usually a warning, not fatal. If it blocks the build, add `RUN choco install -y python2 visualstudio2019-workload-vctools` to the build stage, or run `npm.cmd install --no-optional`. |
| `npm ERR! Unexpected end of JSON` / network | re-run `build.ps1`; npm 6 registry hiccups are transient. |
| choco `sql-server-express` fails to start the service during install | the entrypoint retries `Start-Service`; if the image build itself fails here, add `/SQLSVCACCOUNT:"NT AUTHORITY\SYSTEM"` to the choco `--params` in the Dockerfile. |
| Container starts, SQL up, app exits immediately | `docker logs danphe-emr` — most likely a startup exception from `NepaliDate` / `RBAC` querying a table that the restored DB doesn't have, or a bad connection string. Shell in and test: `docker exec -it danphe-emr powershell` → `sqlcmd -S .\SQLEXPRESS -U sa -P 'Danphe#EMR2024' -Q "SELECT name FROM sys.databases"`. |
| `RESTORE FILELISTONLY` / restore fails | check the `.bak` extracted: `docker exec -it danphe-emr powershell` → `Get-ChildItem C:\data`. The zip must contain `Dev_DanpheEMR_INT1.bak`. |
| Login page loads but styling/JS 404 | the Angular build didn't land in `wwwroot/DanpheApp/dist/DanpheApp`. Check build logs for the `ng build` step; bundle names must be `runtime.js/polyfills.js/styles.js/vendor.js/main.js` (non-prod), which is what the Dockerfile requests. |
| Excel export throws `Syncfusion license` | expected — add a free [Syncfusion community license key](https://www.syncfusion.com/products/communitylicense) via `SyncfusionLicenseProvider.RegisterLicense(...)` if you need those reports. |

To iterate quickly on the runtime layer without rebuilding everything, edit
`entrypoint.ps1` / `appsettings.docker.json` and rebuild — those are copied near the end of
the Dockerfile so only the last few layers rebuild.
