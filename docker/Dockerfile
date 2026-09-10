# escape=`
# =============================================================================
#  Danphe EMR - all-in-one Windows container
#  (ASP.NET Core 2.0 on .NET Framework 4.6.1 + Angular 7 + SQL Server Express)
#
#  MUST be built with Docker in "Windows containers" mode on a Windows host.
#  Linux containers cannot run .NET Framework.
#
#  Stage 1 (build)   : mcr.microsoft.com/dotnet/framework/sdk    - MSBuild + NuGet + Node 12
#  Stage 2 (runtime) : mcr.microsoft.com/dotnet/framework/aspnet - + SQL Server Express
#
#  First `docker run` restores DanpheAdmin + the EMR DB into C:\data
#  (mount a volume there to persist them). App listens on port 80 (Kestrel).
# =============================================================================

ARG WINDOWS_TAG=ltsc2022

# -----------------------------------------------------------------------------
# Stage 1: build the backend (.NET Framework) and the frontend (Angular 7)
# -----------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/framework/sdk:4.8-windowsservercore-${WINDOWS_TAG} AS build
SHELL ["powershell", "-NoProfile", "-Command", "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';"]

# --- Node.js 12 (last version that reliably runs Angular CLI 7 / npm 6) --------
ARG NODE_VERSION=12.22.12
RUN Invoke-WebRequest -UseBasicParsing -Uri \"https://nodejs.org/dist/v$env:NODE_VERSION/node-v$env:NODE_VERSION-win-x64.zip\" -OutFile node.zip ; `
    Expand-Archive node.zip -DestinationPath C:\ ; `
    Rename-Item \"C:\node-v$env:NODE_VERSION-win-x64\" C:\node ; `
    Remove-Item node.zip ; `
    [Environment]::SetEnvironmentVariable('Path', 'C:\node;' + [Environment]::GetEnvironmentVariable('Path','Machine'), 'Machine')

WORKDIR C:\src
COPY Code C:\src\Code

# --- Restore NuGet packages --------------------------------------------------
#  * class libraries use packages.config  -> restored from the .sln into Code\Solutions\packages
#  * the web project uses PackageReference -> restored via msbuild /t:Restore
RUN nuget restore C:\src\Code\Solutions\DanpheEMR.sln -NonInteractive -Verbosity quiet
RUN msbuild C:\src\Code\Websites\DanpheEMR\DanpheEMR.csproj /t:Restore /p:Configuration=Release /nologo /v:minimal

# --- Build the web app (+ its 6 project references) into C:\build -------------
#  DocumentationFile is forced on: Startup -> AddSwaggerAndJwtServices calls
#  IncludeXmlComments("DanpheEmrAPI.xml") unconditionally and throws if missing.
RUN msbuild C:\src\Code\Websites\DanpheEMR\DanpheEMR.csproj `
      /p:Configuration=Release /p:Platform=AnyCPU /m /nologo /v:minimal `
      /p:OutDir=C:\build\ /p:DebugType=None `
      /p:PreserveCompilationContext=true `
      /p:GenerateDocumentationFile=true /p:DocumentationFile=DanpheEmrAPI.xml

# Razor views compile at runtime -> they must ship next to the exe
RUN Copy-Item -Recurse -Force C:\src\Code\Websites\DanpheEMR\Views C:\build\Views ; `
    Copy-Item -Force C:\src\Code\Websites\DanpheEMR\web.config C:\build\ -ErrorAction SilentlyContinue

# --- Static web root (themes, assets-dph, fileuploads, ...) ------------------
#  wwwroot is excluded from the project build; copy it now, BEFORE npm creates
#  node_modules under DanpheApp, so the copy stays small.
RUN Copy-Item -Recurse -Force C:\src\Code\Websites\DanpheEMR\wwwroot C:\build\wwwroot ; `
    Remove-Item -Recurse -Force C:\build\wwwroot\DanpheApp\dist -ErrorAction SilentlyContinue

# --- Build the Angular 7 SPA -----------------------------------------------
#  Non-prod bundle names (runtime/polyfills/styles/vendor/main.js) are what
#  Views/Home/Index.cshtml references. Output lands inside the staged wwwroot.
#  Node heap is capped at NG_HEAP_MB (default 4096) so the build fits on an
#  8 GiB VM; bump it with --build-arg NG_HEAP_MB=8192 on a bigger box.
ARG NG_HEAP_MB=4096
WORKDIR C:\src\Code\Websites\DanpheEMR\wwwroot\DanpheApp
RUN C:\node\npm.cmd install --no-audit --no-fund --loglevel=error
RUN & C:\node\node.exe --max-old-space-size=${NG_HEAP_MB} `
      .\node_modules\@angular\cli\bin\ng build `
      --output-path C:\build\wwwroot\DanpheApp\dist\DanpheApp `
      --deploy-url /DanpheApp/dist/DanpheApp/ `
      --output-hashing none

# -----------------------------------------------------------------------------
# Stage 2: runtime - ASP.NET Framework host + SQL Server Express
# -----------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/framework/aspnet:4.8-windowsservercore-${WINDOWS_TAG} AS runtime
SHELL ["powershell", "-NoProfile", "-Command", "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue';"]

ARG SA_PASSWORD=Danphe#EMR2024
ENV SA_PASSWORD=$SA_PASSWORD `
    ASPNETCORE_URLS=http://+:80 `
    ASPNETCORE_ENVIRONMENT=Production

# --- Chocolatey ------------------------------------------------------------
RUN Set-ExecutionPolicy Bypass -Scope Process -Force ; `
    [Net.ServicePointManager]::SecurityProtocol = 3072 ; `
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# --- SQL Server 2019 Express (engine) + command-line tools ----------------
RUN $p = \"'/INSTANCENAME:SQLEXPRESS /SECURITYMODE:SQL /SAPWD:$env:SA_PASSWORD /TCPENABLED:1 /NPENABLED:1'\" ; `
    choco install -y --no-progress sql-server-express --params $p
RUN choco install -y --no-progress sqlserver-cmdlineutils

# --- SqlServer PowerShell module (v21: no forced TLS - simplest for localhost)
RUN Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null ; `
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted ; `
    Install-Module -Name SqlServer -RequiredVersion 21.1.18256 -Force -AllowClobber -Scope AllUsers

# --- App + seed data -----------------------------------------------------
WORKDIR C:\app
COPY --from=build C:\build C:\app
COPY Database C:\seed\Database
COPY docker\appsettings.docker.json C:\app\appsettings.json
COPY docker\entrypoint.ps1 C:\entrypoint.ps1

RUN New-Item -ItemType Directory -Force -Path `
      C:\data, C:\app\Logs, C:\app\filestore\reports, C:\app\filestore\logs, `
      C:\app\wwwroot\fileuploads | Out-Null

EXPOSE 80
VOLUME C:\data

HEALTHCHECK --interval=20s --timeout=6s --start-period=240s --retries=12 `
  CMD powershell -NoProfile -Command `
    "try { if ((Invoke-WebRequest -UseBasicParsing http://localhost/Account/Login -TimeoutSec 5).StatusCode -eq 200) { exit 0 } else { exit 1 } } catch { exit 1 }"

ENTRYPOINT ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "C:\\entrypoint.ps1"]
