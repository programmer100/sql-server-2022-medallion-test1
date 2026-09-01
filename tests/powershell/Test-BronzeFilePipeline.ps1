#requires -Version 7.4

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$readerSource = Join-Path $repoRoot 'pipelines\bronze\CsvDataReader.cs'
$mappingPath = Join-Path $repoRoot 'examples\sftp-csv-bronze\mapping.example.json'
$configPath = Join-Path $repoRoot 'examples\sftp-csv-bronze\sftp-feed.example.json'
$sampleCsvPath = Join-Path $repoRoot 'examples\sftp-csv-bronze\sample-sales.csv'
$acquisitionScript = Join-Path $repoRoot 'pipelines\bronze\Invoke-SftpZipAcquisition.ps1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('SqlServerMedallion-PipelineTest-' + [guid]::NewGuid().ToString('N'))

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw "$Message Expected '$Expected', actual '$Actual'."
    }
}

try {
    Add-Type -Path $readerSource
    $mapping = Get-Content -LiteralPath $mappingPath -Raw | ConvertFrom-Json
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    Assert-Equal $mapping.schemaVersion 1 'Mapping schema version is invalid.'
    Assert-Equal $config.schemaVersion 1 'Acquisition schema version is invalid.'

    [string[]]$sourceColumns = @($mapping.columns | ForEach-Object { [string]$_.source })
    [string[]]$targetColumns = @($mapping.columns | ForEach-Object { [string]$_.target })
    [bool[]]$optionalColumns = @($mapping.columns | ForEach-Object { [bool]$_.optional })
    [int[]]$landingLengths = @($mapping.columns | ForEach-Object { [int]$_.landingMaxLength })
    $stream = [System.IO.File]::OpenRead($sampleCsvPath)
    $text = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true, 4096)
    $reader = [SqlServerMedallion.Bronze.CsvDataReader]::new(
        $text, ',', '"', $false,
        $sourceColumns, $targetColumns, $optionalColumns, $landingLengths,
        101, 202, 'sample-sales.csv', [DateTime]::UtcNow)
    $rows = [System.Collections.Generic.List[object]]::new()
    try {
        while ($reader.Read()) {
            $rows.Add([pscustomobject]@{
                TxnId = $reader.GetString($reader.GetOrdinal('TxnId'))
                TxnDate = $reader.GetString($reader.GetOrdinal('TxnDate'))
                Notes = $reader.GetString($reader.GetOrdinal('Notes'))
                SourceRecordNumber = $reader.GetInt64($reader.GetOrdinal('SourceRecordNumber'))
                FileLoadId = $reader.GetInt64($reader.GetOrdinal('FileLoadId'))
                FileLoadAttemptId = $reader.GetInt64($reader.GetOrdinal('FileLoadAttemptId'))
            })
        }
        Assert-Equal $reader.RowsParsed 2 'Parser did not count logical CSV records correctly.'
        Assert-Equal $reader.RowsAccepted 2 'Parser did not accept the expected records.'
        Assert-Equal $reader.RowsRejected 0 'Parser unexpectedly rejected a valid record.'
    }
    finally {
        $reader.Dispose()
    }
    Assert-Equal $rows.Count 2 'Unexpected sample row count.'
    Assert-Equal $rows[0].SourceRecordNumber 2 'Header-aware source record numbering is invalid.'
    Assert-Equal $rows[1].SourceRecordNumber 3 'Embedded newline changed logical record numbering.'
    Assert-Equal $rows[0].FileLoadId 101 'Logical file-load lineage was not injected.'
    Assert-Equal $rows[0].FileLoadAttemptId 202 'Physical-attempt lineage was not injected.'
    if ($rows[0].Notes -notmatch "quoted comma and\r?\nembedded newline") {
        throw 'Quoted embedded newline was not preserved.'
    }
    Assert-Equal $rows[1].TxnDate 'not-a-date' 'Bronze parser transformed an invalid business date.'

    $rejectText = [System.IO.StringReader]::new("a,b`n1`n")
    $rejectReader = [SqlServerMedallion.Bronze.CsvDataReader]::new(
        $rejectText, ',', '"', $false,
        [string[]]@('a', 'b'), [string[]]@('A', 'B'), [bool[]]@($false, $false), [int[]]@(10, 10),
        1, 1, 'reject.csv', [DateTime]::UtcNow)
    $rejectReader.MaxRejects = 1
    try {
        Assert-Equal $rejectReader.Read() $false 'Field-count reject should not be exposed to SqlBulkCopy.'
        Assert-Equal $rejectReader.RowsParsed 1 'Rejected record was not counted as parsed.'
        Assert-Equal $rejectReader.RowsRejected 1 'Field-count mismatch was not quarantined.'
    }
    finally {
        $rejectReader.Dispose()
    }

    New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
    $zipPath = Join-Path $temporaryRoot 'sample-sales.zip'
    Compress-Archive -LiteralPath $sampleCsvPath -DestinationPath $zipPath
    $archiveRoot = Join-Path $temporaryRoot 'archive'
    $workRoot = Join-Path $temporaryRoot 'work'
    $artifact = & $acquisitionScript `
        -ConfigPath $configPath `
        -LocalZipPath $zipPath `
        -ArchiveRoot $archiveRoot `
        -WorkRoot $workRoot
    if ($null -eq $artifact) {
        throw 'Local acquisition did not return an artifact manifest.'
    }
    $manifest = Get-Content -LiteralPath $artifact.ManifestPath -Raw | ConvertFrom-Json
    Assert-Equal $manifest.archiveSha256 (Get-FileHash -LiteralPath $manifest.archivePath -Algorithm SHA256).Hash.ToLowerInvariant() 'Archive hash mismatch.'
    Assert-Equal $manifest.csvSha256 (Get-FileHash -LiteralPath $manifest.csvPath -Algorithm SHA256).Hash.ToLowerInvariant() 'CSV hash mismatch.'
    Assert-Equal $manifest.csvSizeBytes (Get-Item -LiteralPath $manifest.csvPath).Length 'CSV byte count mismatch.'
    Assert-Equal (Get-Item -LiteralPath $manifest.archivePath).IsReadOnly $true 'Archived ZIP guardrail is not read-only.'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $unsafeZipPath = Join-Path $temporaryRoot 'unsafe.zip'
    $unsafeZip = [System.IO.Compression.ZipFile]::Open($unsafeZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $entry = $unsafeZip.CreateEntry('../escape.csv')
        $writer = [System.IO.StreamWriter]::new($entry.Open())
        try { $writer.WriteLine('id'); $writer.WriteLine('1') }
        finally { $writer.Dispose() }
    }
    finally {
        $unsafeZip.Dispose()
    }
    $unsafeFailed = $false
    try {
        $null = & $acquisitionScript `
            -ConfigPath $configPath `
            -LocalZipPath $unsafeZipPath `
            -ArchiveRoot (Join-Path $temporaryRoot 'unsafe-archive') `
            -WorkRoot (Join-Path $temporaryRoot 'unsafe-work')
    }
    catch {
        $unsafeFailed = $_.Exception.Message -match 'unsafe path'
    }
    Assert-Equal $unsafeFailed $true 'ZIP path traversal was not rejected.'

    Write-Host 'Bronze file-pipeline PowerShell tests passed.' -ForegroundColor Green
}
finally {
    $resolvedTemporaryRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
    $systemTemporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ((Test-Path -LiteralPath $resolvedTemporaryRoot) -and
        $resolvedTemporaryRoot.StartsWith($systemTemporaryRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Path]::GetFileName($resolvedTemporaryRoot).StartsWith('SqlServerMedallion-PipelineTest-', [StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}
