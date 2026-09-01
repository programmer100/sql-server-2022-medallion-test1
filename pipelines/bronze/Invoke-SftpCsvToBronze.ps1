#requires -Version 7.4

<#
.SYNOPSIS
    Runs the secure SFTP ZIP acquisition and retry-safe CSV-to-Bronze loader.
#>
[CmdletBinding(DefaultParameterSetName = 'Sftp')]
param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [Parameter(Mandatory)]
    [string]$MappingPath,

    [Parameter(ParameterSetName = 'Sftp')]
    [pscredential]$SftpCredential,

    [Parameter(Mandatory, ParameterSetName = 'Local')]
    [string]$LocalZipPath,

    [Parameter()]
    [string]$ArchiveRoot,

    [Parameter()]
    [string]$WorkRoot,

    [Parameter(ParameterSetName = 'Sftp')]
    [string]$WinScpAssemblyPath,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9_.\\(),-]+$')]
    [string]$SqlInstance = 'localhost',

    [Parameter()]
    [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,127}$')]
    [string]$Database = 'SqlServerMedallion',

    [Parameter()]
    [pscredential]$SqlCredential,

    [Parameter()]
    [switch]$TrustServerCertificate,

    [Parameter()]
    [ValidateRange(1, 1000000)]
    [int]$BatchSize = 100000,

    [Parameter()]
    [ValidateRange(1, 10)]
    [int]$MaxAttempts = 3,

    [Parameter()]
    [ValidateRange(0, 100000)]
    [int]$MaxRejects = 100,

    [Parameter()]
    [ValidateRange(1, 10080)]
    [int]$AbandonStartedAfterMinutes,

    [Parameter()]
    [switch]$CaptureRejectFragments,

    [Parameter()]
    [switch]$ReverifyHashes,

    [Parameter()]
    [switch]$ContinueOnFileError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$acquisitionScript = Join-Path $PSScriptRoot 'Invoke-SftpZipAcquisition.ps1'
$loaderScript = Join-Path $PSScriptRoot 'Invoke-CsvToSqlBulkLoad.ps1'

$acquisitionParameters = @{
    ConfigPath = $ConfigPath
}
if ($PSBoundParameters.ContainsKey('ArchiveRoot')) { $acquisitionParameters.ArchiveRoot = $ArchiveRoot }
if ($PSBoundParameters.ContainsKey('WorkRoot')) { $acquisitionParameters.WorkRoot = $WorkRoot }
if ($PSCmdlet.ParameterSetName -eq 'Local') {
    $acquisitionParameters.LocalZipPath = $LocalZipPath
}
else {
    if ($SftpCredential) { $acquisitionParameters.SftpCredential = $SftpCredential }
    if ($PSBoundParameters.ContainsKey('WinScpAssemblyPath')) { $acquisitionParameters.WinScpAssemblyPath = $WinScpAssemblyPath }
}

$artifacts = @(& $acquisitionScript @acquisitionParameters)
if ($artifacts.Count -eq 0) {
    Write-Host 'No stable artifacts were acquired.' -ForegroundColor Yellow
    return
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($artifact in $artifacts) {
    $loaderParameters = @{
        ManifestPath = $artifact.ManifestPath
        MappingPath = $MappingPath
        SqlInstance = $SqlInstance
        Database = $Database
        BatchSize = $BatchSize
        MaxAttempts = $MaxAttempts
        MaxRejects = $MaxRejects
        TrustServerCertificate = [bool]$TrustServerCertificate
    }
    if ($SqlCredential) { $loaderParameters.SqlCredential = $SqlCredential }
    if ($PSBoundParameters.ContainsKey('AbandonStartedAfterMinutes')) {
        $loaderParameters.AbandonStartedAfterMinutes = $AbandonStartedAfterMinutes
    }
    if ($CaptureRejectFragments) { $loaderParameters.CaptureRejectFragments = $true }
    if (-not $ReverifyHashes) { $loaderParameters.SkipHashVerification = $true }

    try {
        $result = & $loaderScript @loaderParameters
        if ($null -ne $result) { $results.Add($result) }
    }
    catch {
        if (-not $ContinueOnFileError) { throw }
        Write-Warning "Load failed for $($artifact.ManifestPath): $($_.Exception.Message)"
        $results.Add([pscustomobject]@{
            Status = 'Failed'
            ManifestPath = $artifact.ManifestPath
            ErrorMessage = $_.Exception.Message
        })
    }
}

return $results
