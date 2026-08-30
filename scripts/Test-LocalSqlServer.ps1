#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.\\(),-]+$')]
    [string]$Server = 'localhost',

    [Parameter()]
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,127}$')]
    [string]$Database = 'SqlServerMedallion'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$smokeTestDirectory = Join-Path $repoRoot 'tests\smoke'
$sqlcmd = (Get-Command sqlcmd -ErrorAction SilentlyContinue).Source

if (-not $sqlcmd -and (Test-Path -LiteralPath 'C:\Program Files\SqlCmd\sqlcmd.exe')) {
    $sqlcmd = 'C:\Program Files\SqlCmd\sqlcmd.exe'
}

if (-not $sqlcmd) {
    throw 'sqlcmd was not found. Install Microsoft.Sqlcmd with WinGet and restart PowerShell 7.'
}

$environmentTest = @"
SET NOCOUNT ON;

IF CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) <> 16
    THROW 51000, N'The target is not SQL Server 2022.', 1;
IF CONVERT(nvarchar(128), SERVERPROPERTY('Edition')) NOT LIKE N'%Developer%'
    THROW 51001, N'The local target is not SQL Server Developer edition.', 1;
IF DB_ID(N'$Database') IS NULL
    THROW 51002, N'The local Medallion database does not exist.', 1;

DECLARE @CompatibilityLevel int;
DECLARE @RecoveryModel nvarchar(60);
DECLARE @QueryStoreOn bit;

SELECT
    @CompatibilityLevel = [compatibility_level],
    @RecoveryModel = [recovery_model_desc],
    @QueryStoreOn = [is_query_store_on]
FROM sys.databases
WHERE [name] = N'$Database';

IF @CompatibilityLevel <> 160
    THROW 51003, N'The local database compatibility level is not 160.', 1;
IF @RecoveryModel <> N'SIMPLE'
    THROW 51004, N'The local database recovery model is not SIMPLE.', 1;
IF @QueryStoreOn <> 1
    THROW 51005, N'Query Store is not enabled.', 1;

SELECT
    CONVERT(nvarchar(30), SERVERPROPERTY('ProductVersion')) AS [ProductVersion],
    CONVERT(nvarchar(128), SERVERPROPERTY('Edition')) AS [Edition],
    @CompatibilityLevel AS [CompatibilityLevel],
    @RecoveryModel AS [RecoveryModel],
    @QueryStoreOn AS [QueryStoreOn];
"@

& $sqlcmd -S $Server -d master -E -C -b -Q $environmentTest
if ($LASTEXITCODE -ne 0) {
    throw "Local SQL Server environment test failed with exit code $LASTEXITCODE."
}

$smokeTests = @(Get-ChildItem -LiteralPath $smokeTestDirectory -Filter '*.sql' -File | Sort-Object -Property Name)
if ($smokeTests.Count -eq 0) {
    throw "No SQL smoke tests were found in $smokeTestDirectory."
}

foreach ($smokeTest in $smokeTests) {
    Write-Host "Running $($smokeTest.Name)..."
    & $sqlcmd -S $Server -d $Database -E -C -b -i $smokeTest.FullName
    if ($LASTEXITCODE -ne 0) {
        throw "Database smoke test $($smokeTest.Name) failed with exit code $LASTEXITCODE."
    }
}

Write-Host 'Local SQL Server 2022 Medallion tests passed.' -ForegroundColor Green
