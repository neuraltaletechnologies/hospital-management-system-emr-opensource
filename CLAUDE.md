# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Danphe EMR — an open-source hospital management information system (HMIS) + EMR/EHR, deployed in
production hospitals across Nepal, India, Bangladesh, Kenya and elsewhere. ~20 clinical/operational
modules (Billing, Pharmacy, Lab, Radiology, Inventory, Accounting, ADT, Nursing, Emergency, OT,
Clinical, Claim/Insurance, etc.), plus 50+ lab-machine (LIS) integrations.

Developer setup guide (authoritative): https://opensource-emr.github.io/hospital-management-emr/#setup
Demo: http://202.51.74.168:302/ (admin / pass123)

## Tech stack — read this before assuming anything

- **Backend: ASP.NET Core 2.0 MVC hosted on .NET Framework 4.6.1** (`net461`). This is a legacy
  MSBuild solution with old-style `.csproj` for the class libraries. There is **no `dotnet build` /
  `dotnet run`** workflow.
- **Data access is Entity Framework 6** (`System.Data.Entity`, EF6 `DbContext`), *not* EF Core —
  even though `Microsoft.EntityFrameworkCore.*` packages appear in the web `.csproj`.
- Database: **SQL Server**, two separate databases (see below).
- **Frontend: Angular 7** SPA (TypeScript 3.1, Angular CLI 7.3) under
  `Code/Websites/DanpheEMR/wwwroot/DanpheApp`, built to static JS that the ASP.NET app serves.
- Auth: server session + RBAC, plus JWT bearer tokens for API calls. Real-time: SignalR.
- `Code/Solutions/global.json` pins .NET SDK 8.0.302 — **stale and unused**; the solution targets
  `net461`. Don't treat this as a .NET 8 project.

## Solution layout

`Code/Solutions/DanpheEMR.sln` (Visual Studio 2019 / v16) contains:

| Project | Role |
|---|---|
| `Websites/DanpheEMR` (`DanpheEMR.csproj`) | The web app — MVC + API controllers, Razor views, and the Angular app under `wwwroot/DanpheApp`. Startup: `Startup.cs`, `Program.cs`, `ConfigureServices.cs`. |
| `Components/DanpheEMR.ServerModel` | EF entity/POCO models, DTOs, and FluentValidation validators. One folder per domain (`LabModels`, `BillingModels`, …). Large (~675 files). |
| `Components/DanpheEMR.DalLayer` | One EF6 `*DbContext` per domain module (`LabDbContext`, `BillingDbContext`, …). `OnModelCreating` maps each `DbSet` to its physical table name. |
| `Components/DanpheEMR.Core` | `DanpheCache` (SQL-backed cache), configuration types, dynamic templates, lookups, parameters, `CoreDbContext`. |
| `Components/DanpheEMR.Security` | RBAC (roles / permissions / policies / routes), connection-string & password encryption (`RBAC.DecryptPassword`), `RbacDbContext`. Talks to the **DanpheAdmin** DB. |
| `Components/DanpheEMR.Sync`, `Components/DanpheEMR.Jobs` | Remote sync + background jobs — IRD Nepal (fiscal/tax) and SSF (social-security insurance) integrations. |
| `Components/DanpheEMR.AccTransfer` | Standalone accounting-transfer console app. |
| `Utilities/ServerSidePrinter`, `Utilities/TestingPlayGroundConsole` | Helper console apps (separate `.sln` for the printer). |

`Database/` — `1. Admin-Db/1. DanpheAdmin_CompleteDB.sql` (admin/RBAC DB), `2. EMR-Db/` (EMR DB,
zipped), `CleanUpScript.sql` (full DB reset — see also the external Danphe-HIMS-EMR-Cleanupscript repo).

## Databases

Three connection strings in `Code/Websites/DanpheEMR/appsettings.json`:

- `Connectionstring` — main **EMR** database (clinical/billing/pharmacy/etc.)
- `ConnectionStringAdmin` — **DanpheAdmin** database (RBAC users/roles/routes, `DanpheAudit` table,
  distributed cache)
- `ConnectionStringPACSServer` — radiology PACS database

Connection-string passwords may be stored encrypted; `Startup` decrypts them at boot via
`RBAC.DecryptPassword`. The JWT key, dev DB credentials and a Google service-account path are
committed in `appsettings.json` as dev defaults and are meant to be overridden per deployment.

## Backend request architecture

- **API controllers inherit `CommonController`** (`Websites/DanpheEMR/Utilities/CommonController.cs`):
  base route `api/[controller]`, class-level `[DanpheDataFilter]` (validates the JWT / current user)
  and `[RequestFormSizeLimit]`.
- **`*ViewController` classes** return Razor views for a module's "main" shell page. They gate access
  through RBAC: `GetView(urlFullPath, viewPath)` checks the user's valid routes, or
  `[DanpheViewFilter("permission-name")]` checks a permission.
- Controller actions wrap their work in `InvokeHttpGetFunction<T>` / `InvokeHttpPostFunction<T>` /
  `...PutFunction<T>` (and `...Async` / `...SingleTransactionScope` variants). These always return a
  **`DanpheHTTPResponse<T>` envelope**: `{ Status, Results, ErrorMessage }`. The Angular side expects
  exactly this shape — keep new endpoints consistent.
- **Two coexisting styles.** Older modules: `new XxxDbContext(connString)` created directly inside the
  controller, business logic in `*BL.cs` files. Newer modules: DI-injected `IXxxService`, registered
  in `DependencyInjection/DanpheServicesExtensions.cs` (`AddDanpheServices`) and `ConfigureServices.cs`,
  with a matching `Services/<Domain>/` folder. **Prefer the service + DI pattern for new code** where
  one already exists for that area.
- Middleware pipeline (`Startup.Configure`): `RewindMiddleWare` (enables re-reading the raw request
  body — filters and `ReadPostData()` depend on this) → session → `ExceptionMiddleware` (global
  handler) → MVC.
- JSON is **Newtonsoft with `DefaultContractResolver`** — property names stay **PascalCase**, not
  camelCase. Use `DanpheJSONConvert` for (de)serialization.
- Logging: **Serilog** (`logging.Configuration.json`). Auditing: **Audit.NET** writing to the
  `DanpheAudit` table in the admin DB, toggled by `IsAuditEnable` in `appsettings.json`;
  `CommonController.AddAuditField` stamps the current user onto a context.
- Nepali (Bikram Sambat) calendar is first-class — `NepaliDate` singleton, `DanpheDateConverter`.
- Swagger UI and a browsable `/node_modules` file server are enabled **only** when
  `appsettings.json` `environment:isdevelopment` is `true`.

## Frontend architecture

- `src/app/app.module.ts` is the root module. `src/app/app-routing.constant.ts` maps each top-level
  route (`Lab`, `Billing`, `Pharmacy`, `ADTMain`, …) to a **lazy-loaded feature module**
  (`loadChildren: "./labs/labs.module#LabsModule"`), most guarded by `AuthGuardService`.
- **Per-module service split**: `*.dl.service.ts` = data layer (raw `HttpClient` calls to `/api/...`,
  returns the `DanpheHTTPResponse` envelope), `*.bl.service.ts` = business layer / state. Generic
  CRUD lives in `shared/dl.service.ts` (`Read` / `Add` / `Update`).
- POST/PUT bodies are sent as a **JSON string with `Content-Type: application/x-www-form-urlencoded`**
  (the backend reads the raw body), not as `application/json`. Match the existing calls.
- `HashLocationStrategy` — URLs contain `#`.
- The SPA is **hosted inside Razor views** (`Views/Home/Index.cshtml`, `Views/Home/AppMain.cshtml`):
  the `<my-app loginToken="@token">` element receives the JWT from server-side `TempData`, and the
  left-nav menu is server-rendered from the user's RBAC routes. Built bundles are referenced as
  `/DanpheApp/dist/DanpheApp/{runtime,polyfills,styles,vendor,main}.js`.
- Shared UI widgets in `src/app/shared/`: `danphe-grid` (wraps ag-grid), autocomplete, Nepali-aware
  datepickers, CKEditor/Summernote wrappers, confirmation dialogs, loader interceptor.

## Build & run

**Platform:** Windows only. The backend is .NET Framework 4.6.1 and references Windows-only
assemblies (`System.Web`, `System.Drawing`, `WindowsBase`, `Syncfusion.XlsIO.WinForms`, EF6) — it
does not run on Linux/macOS or in a Linux container.

**Containerized option:** `docker/` holds an all-in-one **Windows container** (SQL Server Express +
built app + Angular bundles) — `docker/build.ps1` then `docker/run.ps1`; see `docker/README.md`.
Requires Docker Desktop in Windows-containers mode.

### 1. Databases
Restore `Database/1. Admin-Db/1. DanpheAdmin_CompleteDB.sql` and the EMR DB from
`Database/2. EMR-Db/DanpheInternationalDB/Dev_DanpheEMR_INT1.zip`, then set the three connection
strings in `Code/Websites/DanpheEMR/appsettings.json`.

### 2. Backend
Open `Code/Solutions/DanpheEMR.sln` in **Visual Studio 2019** with the .NET Framework 4.6.1 targeting
pack and ASP.NET Core 2.0 tooling. NuGet restore covers both `packages.config` (class libraries →
restored into `Code/Solutions/packages/`) and `PackageReference` (web project). Run the `DanpheEMR`
project — IIS Express, `http://localhost:56326`, lands on `/Account/Login`,
`ASPNETCORE_ENVIRONMENT=development`.

Command line (Developer Command Prompt / MSBuild, not `dotnet`):
```
nuget restore Code/Solutions/DanpheEMR.sln
msbuild Code/Solutions/DanpheEMR.sln /p:Configuration=Debug
```

### 3. Frontend
From `Code/Websites/DanpheEMR/wwwroot/DanpheApp` (Node.js — the CI image uses 10.x):
```
npm install
npm run build          # ng build; the "build" script sets --max-old-space-size=16384
```
Watch build (what you normally run during dev) — the `--deploy-url` is required so bundles resolve
under the Razor host:
```
ng build --watch --deploy-url=/DanpheApp/dist/DanpheApp/
```
`Gruntfile.js` (`grunt` / `grunt-shell`) runs that same watch build, reading the target path from
`ngbuildpath` in `appsettings.json`.

Production: `ng build --prod`, then follow the commented instructions in `Views/Home/Index.cshtml`
(paste the generated `dist/DanpheApp/Index.html` script tags).

`ng serve` (port 4200) exists but the app is normally exercised through the .NET host, not standalone.

### Lint & test (frontend)
```
npm run lint                        # tslint
npm test                            # ng test — Karma + Jasmine (Chrome)
```
Single spec: `ng test --include='**/my.component.spec.ts'`, or edit `files` in `src/karma.conf.js`.
Spec coverage in this repo is minimal; there is no meaningful backend test suite
(`Utilities/TestingPlayGroundConsole` is a scratch console app).

### CI
`bitbucket-pipelines.yml` only — a Node image running `npm install` + `ng build`. No .NET CI.
The root `status` file is a stray `git branch` dump; ignore it.

## Conventions & gotchas

- New API endpoints: return `DanpheHTTPResponse<T>` via the `InvokeHttp*Function` helpers; keep JSON
  PascalCase; register business logic as an `IXxxService` in `DanpheServicesExtensions`.
- A very common legacy anti-pattern here is `catch (Exception ex) { throw ex; }` (loses the stack
  trace) and per-call `new XxxDbContext(connString)`. Don't copy it into new code.
- EF6 mapping: entity → table names are declared in each `DbContext.OnModelCreating`, not by
  convention. When adding a `DbSet`, add the `ToTable(...)` mapping.
- RBAC: a page is reachable only if the user's route/permission set (loaded into session at login and
  cached) allows it. New screens need a route + permission seeded in the DanpheAdmin DB, wired into
  both `app-routing.constant.ts` and a `*ViewController` action.
- `.editorconfig` at `Code/Solutions/.editorconfig` is effectively empty; frontend formatting is
  driven by `.vscode/settings.json` (format-on-save, organize-imports) and `tslint.json`.
