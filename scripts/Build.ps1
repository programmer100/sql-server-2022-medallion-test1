#requires -Version 7.4

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$projectPath = Join-Path $repoRoot 'database\SqlServerMedallion.sqlproj'

$dotnet = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
if (-not $dotnet -and (Test-Path -LiteralPath 'C:\Program Files\dotnet\dotnet.exe')) {
    $dotnet = 'C:\Program Files\dotnet\dotnet.exe'
}
if (-not $dotnet) {
    throw 'The .NET 8 SDK is required. Install Microsoft.DotNet.SDK.8, restart PowerShell 7, and rerun this script.'
}

$installedSdks = & $dotnet --list-sdks
if ($installedSdks -notmatch '(?m)^8\.') {
    throw 'The .NET 8 SDK is required, but no .NET 8 SDK was found.'
}

& $dotnet build $projectPath --configuration $Configuration
if ($LASTEXITCODE -ne 0) {
    throw "dotnet build failed with exit code $LASTEXITCODE."
}
