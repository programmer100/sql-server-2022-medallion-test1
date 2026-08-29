#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.\\(),-]+$')]
    [string]$Server = 'localhost',

    [Parameter()]
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,127}$')]
    [string]$Database = 'SqlServerMedallion',

    [Parameter()]
    [ValidateRange(2048, 65536)]
    [int]$MaxServerMemoryMB = 8192
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$buildScript = Join-Path $PSScriptRoot 'Build.ps1'
$dacpacPath = Join-Path $repoRoot 'database\bin\Release\SqlServerMedallion.dacpac'
$smokeTestPath = Join-Path $repoRoot 'tests\smoke\001_layer_schemas_exist.sql'

$sqlcmd = (Get-Command sqlcmd -ErrorAction SilentlyContinue).Source
$sqlpackage = (Get-Command sqlpackage -ErrorAction SilentlyContinue).Source

if (-not $sqlcmd -and (Test-Path -LiteralPath 'C:\Program Files\SqlCmd\sqlcmd.exe')) {
    $sqlcmd = 'C:\Program Files\SqlCmd\sqlcmd.exe'
}
if (-not $sqlpackage) {
    $wingetSqlPackage = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\Microsoft.SqlPackage_Microsoft.Winget.Source_8wekyb3d8bbwe\sqlpackage.exe'
    if (Test-Path -LiteralPath $wingetSqlPackage) {
        $sqlpackage = $wingetSqlPackage
    }
}

if (-not $sqlcmd) {
    throw 'sqlcmd was not found. Install Microsoft.Sqlcmd with WinGet and restart PowerShell 7.'
}
if (-not $sqlpackage) {
    throw 'SqlPackage was not found. Install Microsoft.SqlPackage with WinGet and restart PowerShell 7.'
}

Write-Host 'Building the SQL Server 2022 database project...'
& $buildScript -Configuration Release

$masterCheck = @"
SET NOCOUNT ON;
IF CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) <> 16
    THROW 51000, N'The target is not SQL Server 2022.', 1;
IF CONVERT(nvarchar(128), SERVERPROPERTY('Edition')) NOT LIKE N'%Developer%'
    THROW 51001, N'The local target is not SQL Server Developer edition.', 1;
"@

& $sqlcmd -S $Server -d master -E -C -b -Q $masterCheck
if ($LASTEXITCODE -ne 0) {
    throw "SQL Server prerequisite validation failed with exit code $LASTEXITCODE."
}

$targetConnectionString = "Server=$Server;Initial Catalog=$Database;Integrated Security=True;Encrypt=True;TrustServerCertificate=True"

Write-Host "Publishing $Database to $Server..."
& $sqlpackage `
    /Action:Publish `
    "/SourceFile:$dacpacPath" `
    "/TargetConnectionString:$targetConnectionString" `
    /p:BlockOnPossibleDataLoss=True `
    /p:DropObjectsNotInSource=False `
    /p:ScriptDatabaseOptions=True
if ($LASTEXITCODE -ne 0) {
    throw "SqlPackage publish failed with exit code $LASTEXITCODE."
}

$localConfiguration = @"
EXEC sys.sp_configure N'show advanced options', 1;
RECONFIGURE;
EXEC sys.sp_configure N'max server memory (MB)', $MaxServerMemoryMB;
RECONFIGURE;
EXEC sys.sp_configure N'show advanced options', 0;
RECONFIGURE;
ALTER DATABASE [$Database] SET RECOVERY SIMPLE;
"@

Write-Host 'Applying local-only SQL Server settings...'
& $sqlcmd -S $Server -d master -E -C -b -Q $localConfiguration
if ($LASTEXITCODE -ne 0) {
    throw "Local SQL Server configuration failed with exit code $LASTEXITCODE."
}

Write-Host 'Running the live database smoke test...'
& $sqlcmd -S $Server -d $Database -E -C -b -i $smokeTestPath
if ($LASTEXITCODE -ne 0) {
    throw "Database smoke test failed with exit code $LASTEXITCODE."
}

Write-Host "Local database $Database is ready on $Server." -ForegroundColor Green
Write-Host "SQL Server max memory: $MaxServerMemoryMB MB; database recovery: SIMPLE."
