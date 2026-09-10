<#
    Danphe EMR container entrypoint.

    1. start SQL Server Express
    2. point default data/log dirs at C:\data  (mount a volume there to persist)
    3. create the DanpheAdmin database (from the seed .sql) if missing
    4. restore the EMR database (from the seed .zip -> .bak) if missing
    5. launch DanpheEMR.exe (Kestrel, port 80) in the foreground
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'

$instance   = '.\SQLEXPRESS'
$sqlService = 'MSSQL$SQLEXPRESS'
$saPassword = if ($env:SA_PASSWORD) { $env:SA_PASSWORD } else { 'Danphe#EMR2024' }
$dataDir    = 'C:\data'
$seedDir    = 'C:\seed\Database'
$adminDb    = 'DanpheAdmin'
$emrDb      = 'Dev_DanpheEMR_INT1'

function Log($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

Import-Module SqlServer -DisableNameChecking

function Invoke-Sql {
    param([string]$Query, [string]$Database = 'master', [int]$Timeout = 0)
    Invoke-Sqlcmd -ServerInstance $instance -Username 'sa' -Password $saPassword `
                  -Database $Database -Query $Query -QueryTimeout $Timeout -OutputSqlErrors $true
}

function Wait-ForSql {
    for ($i = 1; $i -le 90; $i++) {
        try { Invoke-Sql 'SELECT 1' | Out-Null; return } catch { Start-Sleep -Seconds 2 }
    }
    throw 'SQL Server did not become available in time.'
}

# ---------------------------------------------------------------------------
Log '=== Danphe EMR container starting ==='
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null

Log 'Starting SQL Server Express...'
Set-Service -Name $sqlService -StartupType Automatic
try { Start-Service $sqlService } catch { Log "Start-Service warning: $($_.Exception.Message)" ; Start-Sleep 5 ; Start-Service $sqlService }
Wait-ForSql
Log 'SQL Server is accepting connections.'

# --- keep user databases on the (optionally mounted) C:\data volume ---------
$needsRestart = $false
$curData = (Invoke-Sql "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(4000)) AS p").p
if ($curData -ne "$dataDir\") {
    Log "Setting default data/log directory to $dataDir"
    Invoke-Sql @"
EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'DefaultData', REG_SZ, N'$dataDir';
EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'DefaultLog',  REG_SZ, N'$dataDir';
"@
    $needsRestart = $true
}
if ($needsRestart) {
    Restart-Service $sqlService -Force
    Wait-ForSql
}

# --- 1. DanpheAdmin --------------------------------------------------------
$adminExists = (Invoke-Sql "SELECT DB_ID('$adminDb') AS id").id
if ($adminExists -is [System.DBNull] -or $null -eq $adminExists) {
    Log "Creating $adminDb from seed script..."
    $adminSql = Join-Path $seedDir '1. Admin-Db\1. DanpheAdmin_CompleteDB.sql'
    Invoke-Sqlcmd -ServerInstance $instance -Username 'sa' -Password $saPassword `
                  -InputFile $adminSql -QueryTimeout 0 -OutputSqlErrors $true
    Log "$adminDb created."
} else {
    Log "$adminDb already present - skipping."
}

# --- 2. EMR database -----------------------------------------------------
$emrExists = (Invoke-Sql "SELECT DB_ID('$emrDb') AS id").id
if ($emrExists -is [System.DBNull] -or $null -eq $emrExists) {
    $bak = Join-Path $dataDir 'Dev_DanpheEMR_INT1.bak'
    if (-not (Test-Path $bak)) {
        Log 'Extracting EMR backup from seed archive (this takes a minute)...'
        Expand-Archive -Path (Join-Path $seedDir '2. EMR-Db\DanpheInternationalDB\Dev_DanpheEMR_INT1.zip') `
                       -DestinationPath $dataDir -Force
    }
    Log "Reading backup file list..."
    $files = Invoke-Sql "RESTORE FILELISTONLY FROM DISK = N'$bak'"
    $moves = ($files | ForEach-Object {
        $ext = if ($_.Type -eq 'L') { 'ldf' } else { 'mdf' }
        "MOVE N'$($_.LogicalName)' TO N'$dataDir\$($emrDb)_$($_.FileId).$ext'"
    }) -join ', '

    Log "Restoring $emrDb ..."
    Invoke-Sql "RESTORE DATABASE [$emrDb] FROM DISK = N'$bak' WITH REPLACE, RECOVERY, $moves" -Timeout 0
    Remove-Item $bak -Force -ErrorAction SilentlyContinue
    Log "$emrDb restored."
} else {
    Log "$emrDb already present - skipping."
}

# --- 3. launch the app -------------------------------------------------
Set-Location C:\app
if (-not (Test-Path C:\app\DanpheEmrAPI.xml)) {
    '<?xml version="1.0"?><doc><assembly><name>DanpheEMR</name></assembly><members/></doc>' |
        Set-Content -Encoding UTF8 C:\app\DanpheEmrAPI.xml
}

$env:ASPNETCORE_URLS = 'http://+:80'
Log '=== Starting DanpheEMR.exe on http://+:80 ==='
& C:\app\DanpheEMR.exe
$code = $LASTEXITCODE
Log "DanpheEMR.exe exited with code $code"
exit $code
