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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$configPath = Join-Path $repoRoot 'examples\sftp-csv-bronze\sftp-feed.example.json'
$sourceMappingPath = Join-Path $repoRoot 'examples\sftp-csv-bronze\mapping.example.json'
$sampleCsvPath = Join-Path $repoRoot 'examples\sftp-csv-bronze\sample-sales.csv'
$acquisitionScript = Join-Path $repoRoot 'pipelines\bronze\Invoke-SftpZipAcquisition.ps1'
$loaderScript = Join-Path $repoRoot 'pipelines\bronze\Invoke-CsvToSqlBulkLoad.ps1'
$suffix = [guid]::NewGuid().ToString('N').Substring(0, 12)
$tableName = "CsvPipelineTest_$suffix"
$mappingName = "csv_pipeline_test_$suffix"
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "SqlServerMedallion-Integration-$suffix"
$connectionString = "Server=$Server;Initial Catalog=$Database;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Application Name=SqlServerMedallion.IntegrationTest"
$connection = $null
$mappingPath = Join-Path $temporaryRoot 'mapping.json'

try {
    New-Item -ItemType Directory -Force -Path $temporaryRoot | Out-Null
    $mapping = Get-Content -LiteralPath $sourceMappingPath -Raw | ConvertFrom-Json
    $mapping.name = $mappingName
    $mapping.target.table = $tableName
    $mapping | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $mappingPath -Encoding utf8NoBOM

    $connection = [System.Data.SqlClient.SqlConnection]::new($connectionString)
    $connection.Open()
    $create = $connection.CreateCommand()
    $create.CommandText = @"
CREATE TABLE [bronze].[$tableName]
(
    [TxnId] NVARCHAR(4000) NULL,
    [TxnDate] NVARCHAR(4000) NULL,
    [CustomerCode] NVARCHAR(4000) NULL,
    [ProductSku] NVARCHAR(4000) NULL,
    [Quantity] NVARCHAR(4000) NULL,
    [UnitPriceCad] NVARCHAR(4000) NULL,
    [StoreCode] NVARCHAR(4000) NULL,
    [PromoCode] NVARCHAR(4000) NULL,
    [Notes] NVARCHAR(4000) NULL,
    [FileLoadId] BIGINT NOT NULL,
    [FileLoadAttemptId] BIGINT NOT NULL,
    [SourceRecordNumber] BIGINT NOT NULL,
    [SourceFileName] NVARCHAR(260) NOT NULL,
    [IngestedAtUtc] DATETIME2(7) NOT NULL
);
"@
    try { $null = $create.ExecuteNonQuery() }
    finally { $create.Dispose() }

    $zipPath = Join-Path $temporaryRoot 'sample-sales.zip'
    Compress-Archive -LiteralPath $sampleCsvPath -DestinationPath $zipPath
    $artifact = & $acquisitionScript `
        -ConfigPath $configPath `
        -LocalZipPath $zipPath `
        -ArchiveRoot (Join-Path $temporaryRoot 'archive') `
        -WorkRoot (Join-Path $temporaryRoot 'work')

    $manifest = Get-Content -LiteralPath $artifact.ManifestPath -Raw | ConvertFrom-Json
    $mappingHashHex = (Get-FileHash -LiteralPath $mappingPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $seed = $connection.CreateCommand()
    $seed.CommandText = @"
DECLARE @ArchiveSha256 BINARY(32) = CONVERT(BINARY(32), @ArchiveHashHex, 2);
DECLARE @CsvSha256 BINARY(32) = CONVERT(BINARY(32), @CsvHashHex, 2);
DECLARE @MappingSha256 BINARY(32) = CONVERT(BINARY(32), @MappingHashHex, 2);
DECLARE @FileArtifactId BIGINT;
DECLARE @WasInserted BIT;
DECLARE @PipelineRunId BIGINT;
DECLARE @FileLoadId BIGINT;
DECLARE @FileLoadAttemptId BIGINT;
DECLARE @ShouldSkip BIT;

EXEC [audit].[usp_RegisterFileArtifact]
    @FeedName = N'sample-pos-sales',
    @RemoteDirectory = N'local',
    @RemoteFileName = @RemoteFileName,
    @RemoteSizeBytes = @ArchiveSizeBytes,
    @RemoteModifiedAtUtc = @RemoteModifiedAtUtc,
    @ArchiveRelativePath = @ArchiveRelativePath,
    @ArchiveSha256 = @ArchiveSha256,
    @ArchiveSizeBytes = @ArchiveSizeBytes,
    @AcquiredAtUtc = @AcquiredAtUtc,
    @FileArtifactId = @FileArtifactId OUTPUT,
    @WasInserted = @WasInserted OUTPUT;

EXEC [audit].[usp_StartPipelineRun]
    @PipelineName = N'Bronze.sample-pos-sales.CsvLoad',
    @PipelineVersion = N'1.0.0',
    @SourceSystem = N'SFTP:sample-pos-sales',
    @SourceObject = @RemoteFileName,
    @LoadMode = 'Full',
    @PipelineRunId = @PipelineRunId OUTPUT;

EXEC [audit].[usp_StartFileLoadAttempt]
    @PipelineRunId = @PipelineRunId,
    @FileArtifactId = @FileArtifactId,
    @FeedName = N'sample-pos-sales',
    @CsvFileName = @CsvFileName,
    @CsvSha256 = @CsvSha256,
    @CsvSizeBytes = @CsvSizeBytes,
    @MappingName = @MappingName,
    @MappingVersion = N'1.0.0',
    @MappingSha256 = @MappingSha256,
    @TargetSchema = N'bronze',
    @TargetTable = N'$tableName',
    @HostName = N'integration-seed',
    @ProcessId = 1,
    @FileLoadId = @FileLoadId OUTPUT,
    @FileLoadAttemptId = @FileLoadAttemptId OUTPUT,
    @ShouldSkip = @ShouldSkip OUTPUT;

INSERT INTO [bronze].[$tableName]
(
    [FileLoadId],
    [FileLoadAttemptId],
    [SourceRecordNumber],
    [SourceFileName],
    [IngestedAtUtc]
)
VALUES
(
    @FileLoadId,
    @FileLoadAttemptId,
    999,
    N'partial.csv',
    SYSUTCDATETIME()
);

EXEC [audit].[usp_CompleteFileLoadAttempt]
    @FileLoadAttemptId = @FileLoadAttemptId,
    @Status = 'Failed',
    @RowsParsed = 1,
    @RowsStaged = 1,
    @RowsRejected = 0,
    @DurationSeconds = 0.001,
    @ErrorMessage = N'Expected seeded partial-batch failure.';
"@
    $null = $seed.Parameters.Add('@ArchiveHashHex', [System.Data.SqlDbType]::Char, 64)
    $seed.Parameters['@ArchiveHashHex'].Value = [string]$manifest.archiveSha256
    $null = $seed.Parameters.Add('@CsvHashHex', [System.Data.SqlDbType]::Char, 64)
    $seed.Parameters['@CsvHashHex'].Value = [string]$manifest.csvSha256
    $null = $seed.Parameters.Add('@MappingHashHex', [System.Data.SqlDbType]::Char, 64)
    $seed.Parameters['@MappingHashHex'].Value = $mappingHashHex
    $null = $seed.Parameters.Add('@RemoteFileName', [System.Data.SqlDbType]::NVarChar, 260)
    $seed.Parameters['@RemoteFileName'].Value = [string]$manifest.remoteFileName
    $null = $seed.Parameters.Add('@ArchiveSizeBytes', [System.Data.SqlDbType]::BigInt)
    $seed.Parameters['@ArchiveSizeBytes'].Value = [long]$manifest.archiveSizeBytes
    $null = $seed.Parameters.Add('@RemoteModifiedAtUtc', [System.Data.SqlDbType]::DateTime2)
    $seed.Parameters['@RemoteModifiedAtUtc'].Value = [datetime]::Parse([string]$manifest.remoteModifiedAtUtc).ToUniversalTime()
    $null = $seed.Parameters.Add('@ArchiveRelativePath', [System.Data.SqlDbType]::NVarChar, 1024)
    $seed.Parameters['@ArchiveRelativePath'].Value = [string]$manifest.archiveRelativePath
    $null = $seed.Parameters.Add('@AcquiredAtUtc', [System.Data.SqlDbType]::DateTime2)
    $seed.Parameters['@AcquiredAtUtc'].Value = [datetime]::Parse([string]$manifest.acquiredAtUtc).ToUniversalTime()
    $null = $seed.Parameters.Add('@CsvFileName', [System.Data.SqlDbType]::NVarChar, 260)
    $seed.Parameters['@CsvFileName'].Value = [string]$manifest.csvFileName
    $null = $seed.Parameters.Add('@CsvSizeBytes', [System.Data.SqlDbType]::BigInt)
    $seed.Parameters['@CsvSizeBytes'].Value = [long]$manifest.csvSizeBytes
    $null = $seed.Parameters.Add('@MappingName', [System.Data.SqlDbType]::NVarChar, 128)
    $seed.Parameters['@MappingName'].Value = $mappingName
    try { $null = $seed.ExecuteNonQuery() }
    finally { $seed.Dispose() }

    $result = & $loaderScript `
        -ManifestPath $artifact.ManifestPath `
        -MappingPath $mappingPath `
        -SqlInstance $Server `
        -Database $Database `
        -TrustServerCertificate `
        -BatchSize 1 `
        -NotifyAfter 1 `
        -MaxAttempts 2 `
        -SkipHashVerification

    if ($result.Status -ne 'Succeeded' -or $result.RowsParsed -ne 2 -or $result.RowsStaged -ne 2 -or $result.RowsRejected -ne 0) {
        throw 'CSV loader did not return the expected reconciled result.'
    }

    $verify = $connection.CreateCommand()
    $verify.CommandText = @"
SELECT
    [RowCount] = COUNT_BIG(*),
    [InvalidDateCount] = SUM(CASE WHEN [TxnDate] = N'not-a-date' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    [EmbeddedNewlineCount] = SUM(CASE WHEN [Notes] LIKE N'quoted comma and%' + CHAR(10) + N'embedded newline' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    [LogicalLoadCount] = COUNT_BIG(DISTINCT [FileLoadId]),
    [AttemptCount] = COUNT_BIG(DISTINCT [FileLoadAttemptId])
FROM [bronze].[$tableName];
"@
    try {
        $reader = $verify.ExecuteReader()
        try {
            $null = $reader.Read()
            if ([long]$reader['RowCount'] -ne 2 -or
                [long]$reader['InvalidDateCount'] -ne 1 -or
                [long]$reader['EmbeddedNewlineCount'] -ne 1 -or
                [long]$reader['LogicalLoadCount'] -ne 1 -or
                [long]$reader['AttemptCount'] -ne 1) {
                throw 'Bronze rows did not preserve the expected source values and lineage.'
            }
        }
        finally { $reader.Dispose() }
    }
    finally { $verify.Dispose() }

    $audit = $connection.CreateCommand()
    $audit.CommandText = @'
SELECT
    [SuccessfulAttemptCount] = SUM(CASE WHEN [attempts].[Status] = 'Succeeded' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END),
    [FailedAttemptCount] = SUM(CASE WHEN [attempts].[Status] = 'Failed' THEN CONVERT(BIGINT, 1) ELSE CONVERT(BIGINT, 0) END)
FROM [audit].[FileLoad] AS [loads]
INNER JOIN [audit].[FileLoadAttempt] AS [attempts]
    ON [attempts].[FileLoadId] = [loads].[FileLoadId]
WHERE [loads].[MappingName] = @MappingName
  AND [loads].[Status] = 'Succeeded'
  AND [loads].[RowsParsed] = 2
  AND [loads].[RowsStaged] = 2
  AND [loads].[RowsRejected] = 0;
'@
    $null = $audit.Parameters.Add('@MappingName', [System.Data.SqlDbType]::NVarChar, 128)
    $audit.Parameters['@MappingName'].Value = $mappingName
    try {
        $reader = $audit.ExecuteReader()
        try {
            $null = $reader.Read()
            if ([long]$reader['SuccessfulAttemptCount'] -ne 1 -or [long]$reader['FailedAttemptCount'] -ne 1) {
                throw 'File-load audit controls did not retain the failed partial attempt and successful retry.'
            }
        }
        finally { $reader.Dispose() }
    }
    finally { $audit.Dispose() }

    Write-Host 'CSV-to-SQL bulk-load integration test passed.' -ForegroundColor Green
}
finally {
    if ($connection -and $connection.State -eq [System.Data.ConnectionState]::Open) {
        $cleanup = $connection.CreateCommand()
        $cleanup.CommandText = @"
DECLARE @PipelineRuns TABLE ([PipelineRunId] BIGINT PRIMARY KEY);
DECLARE @Artifacts TABLE ([FileArtifactId] BIGINT PRIMARY KEY);

INSERT INTO @PipelineRuns ([PipelineRunId])
SELECT [attempts].[PipelineRunId]
FROM [audit].[FileLoadAttempt] AS [attempts]
INNER JOIN [audit].[FileLoad] AS [loads]
    ON [loads].[FileLoadId] = [attempts].[FileLoadId]
WHERE [loads].[MappingName] = @MappingName;

INSERT INTO @Artifacts ([FileArtifactId])
SELECT DISTINCT [loads].[FileArtifactId]
FROM [audit].[FileLoad] AS [loads]
WHERE [loads].[MappingName] = @MappingName;

DELETE [rejects]
FROM [audit].[CsvRowReject] AS [rejects]
INNER JOIN [audit].[FileLoadAttempt] AS [attempts]
    ON [attempts].[FileLoadAttemptId] = [rejects].[FileLoadAttemptId]
INNER JOIN [audit].[FileLoad] AS [loads]
    ON [loads].[FileLoadId] = [attempts].[FileLoadId]
WHERE [loads].[MappingName] = @MappingName;

DELETE [attempts]
FROM [audit].[FileLoadAttempt] AS [attempts]
INNER JOIN [audit].[FileLoad] AS [loads]
    ON [loads].[FileLoadId] = [attempts].[FileLoadId]
WHERE [loads].[MappingName] = @MappingName;

DELETE FROM [audit].[FileLoad]
WHERE [MappingName] = @MappingName;

DELETE [runs]
FROM [audit].[PipelineRun] AS [runs]
INNER JOIN @PipelineRuns AS [selected]
    ON [selected].[PipelineRunId] = [runs].[PipelineRunId];

DELETE [artifacts]
FROM [audit].[FileArtifact] AS [artifacts]
INNER JOIN @Artifacts AS [selected]
    ON [selected].[FileArtifactId] = [artifacts].[FileArtifactId]
WHERE NOT EXISTS
(
    SELECT 1
    FROM [audit].[FileLoad] AS [remaining]
    WHERE [remaining].[FileArtifactId] = [artifacts].[FileArtifactId]
);

IF OBJECT_ID(N'[bronze].[$tableName]', N'U') IS NOT NULL
    DROP TABLE [bronze].[$tableName];
"@
        $null = $cleanup.Parameters.Add('@MappingName', [System.Data.SqlDbType]::NVarChar, 128)
        $cleanup.Parameters['@MappingName'].Value = $mappingName
        try { $null = $cleanup.ExecuteNonQuery() }
        catch { Write-Warning "Integration-test SQL cleanup failed: $($_.Exception.Message)" }
        finally { $cleanup.Dispose() }
        $connection.Dispose()
    }

    $resolvedTemporaryRoot = [System.IO.Path]::GetFullPath($temporaryRoot)
    $systemTemporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ((Test-Path -LiteralPath $resolvedTemporaryRoot) -and
        $resolvedTemporaryRoot.StartsWith($systemTemporaryRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [System.IO.Path]::GetFileName($resolvedTemporaryRoot).StartsWith('SqlServerMedallion-Integration-', [StringComparison]::Ordinal)) {
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}
