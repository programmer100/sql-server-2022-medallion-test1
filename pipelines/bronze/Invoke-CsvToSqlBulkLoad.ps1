#requires -Version 7.4

<#
.SYNOPSIS
    Streams a manifest-backed CSV into a source-specific Bronze heap with
    retry-safe SqlBulkCopy batches and SQL audit controls.

.DESCRIPTION
    The target table must already exist in the database project. Mapped source
    columns must be nullable NVARCHAR landing columns; business types and length
    rules belong in the mapping contract and the Bronze-to-Silver procedure.

    Each retry receives a new physical FileLoadAttemptId. Before SqlBulkCopy
    restarts the file, every row for the logical FileLoadId is deleted. This is
    required because UseInternalTransaction commits each BatchSize separately.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$ManifestPath,

    [Parameter(Mandatory)]
    [string]$MappingPath,

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
    [ValidateRange(1, 10000000)]
    [int]$NotifyAfter = 100000,

    [Parameter()]
    [ValidateRange(0, 2147483647)]
    [int]$BulkCopyTimeoutSeconds = 0,

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
    [ValidateRange(1024, 268435456)]
    [int]$MaxRecordCharacters = 16777216,

    [Parameter()]
    [switch]$CaptureRejectFragments,

    [Parameter()]
    [switch]$SkipHashVerification,

    [Parameter()]
    [string]$LogDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$manifestFile = Get-Item -LiteralPath $ManifestPath
$mappingFile = Get-Item -LiteralPath $MappingPath
$manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Json
$mapping = Get-Content -LiteralPath $mappingFile.FullName -Raw | ConvertFrom-Json
$script:TransientSqlErrors = @(-2, 20, 64, 233, 1205, 10053, 10054, 10060, 10928, 10929, 40197, 40501, 40613, 49918, 49919, 49920)
$script:AbandonStartedAfterMinutesValue = if ($PSBoundParameters.ContainsKey('AbandonStartedAfterMinutes')) { $AbandonStartedAfterMinutes } else { $null }

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Context
    )

    if (-not $Object.PSObject.Properties.Name.Contains($Name)) {
        throw "$Context is missing required property '$Name'."
    }
    $value = $Object.$Name
    if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
        throw "$Context property '$Name' cannot be empty."
    }
    return $value
}

function Assert-SqlIdentifier {
    param(
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Value -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,127}$') {
        throw "$Name '$Value' is not a supported SQL identifier."
    }
}

function Convert-HexToByteArray {
    param([Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$Hex)
    $bytes = [byte[]]::new(32)
    for ($index = 0; $index -lt 32; $index++) {
        $bytes[$index] = [Convert]::ToByte($Hex.Substring($index * 2, 2), 16)
    }
    return ,$bytes
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Add-SqlParameter {
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlCommand]$Command,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Data.SqlDbType]$Type,
        $Value,
        [int]$Size = 0,
        [System.Data.ParameterDirection]$Direction = [System.Data.ParameterDirection]::Input
    )

    $parameter = if ($Size -ne 0) {
        $Command.Parameters.Add($Name, $Type, $Size)
    }
    else {
        $Command.Parameters.Add($Name, $Type)
    }
    $parameter.Direction = $Direction
    if ($Direction -eq [System.Data.ParameterDirection]::Input -or $Direction -eq [System.Data.ParameterDirection]::InputOutput) {
        if ($null -eq $Value) {
            $parameter.Value = [DBNull]::Value
        }
        elseif ($Type -in @([System.Data.SqlDbType]::Binary, [System.Data.SqlDbType]::VarBinary)) {
            [byte[]]$binaryValue = $Value
            $parameter.Value = $binaryValue
        }
        else {
            $parameter.Value = $Value
        }
    }
    return $parameter
}

function Get-SqlConnectionString {
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = $SqlInstance
    $builder['Initial Catalog'] = $Database
    $builder['Application Name'] = 'SqlServerMedallion.CsvBulkLoad/1'
    $builder['Connect Timeout'] = 30
    $builder['Encrypt'] = $true
    $builder['TrustServerCertificate'] = [bool]$TrustServerCertificate
    if ($SqlCredential) {
        $builder['User ID'] = $SqlCredential.UserName
        $builder['Password'] = $SqlCredential.GetNetworkCredential().Password
    }
    else {
        $builder['Integrated Security'] = $true
    }
    return $builder.ConnectionString
}

function New-SqlConnection {
    $connection = [System.Data.SqlClient.SqlConnection]::new((Get-SqlConnectionString))
    $connection.Open()
    return $connection
}

function Invoke-StartPipelineRun {
    param([Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection)

    $command = $Connection.CreateCommand()
    $command.CommandText = '[audit].[usp_StartPipelineRun]'
    $command.CommandType = [System.Data.CommandType]::StoredProcedure
    try {
        $null = Add-SqlParameter $command '@PipelineName' NVarChar "Bronze.$feedName.CsvLoad" 128
        $null = Add-SqlParameter $command '@PipelineVersion' NVarChar ([string]$mapping.version) 64
        $null = Add-SqlParameter $command '@SourceSystem' NVarChar "SFTP:$feedName" 128
        $null = Add-SqlParameter $command '@SourceObject' NVarChar ([string]$manifest.remoteFileName) 261
        $null = Add-SqlParameter $command '@SourcePartition' NVarChar '' 256
        $null = Add-SqlParameter $command '@LoadMode' VarChar 'Full' 20
        $output = Add-SqlParameter $command '@PipelineRunId' BigInt $null 0 Output
        $null = $command.ExecuteNonQuery()
        return [long]$output.Value
    }
    finally {
        $command.Dispose()
    }
}

function Invoke-CompleteOrphanPipelineRun {
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory)][long]$PipelineRunId,
        [Parameter(Mandatory)][string]$ErrorMessage
    )

    $command = $Connection.CreateCommand()
    $command.CommandText = '[audit].[usp_CompletePipelineRun]'
    $command.CommandType = [System.Data.CommandType]::StoredProcedure
    try {
        $null = Add-SqlParameter $command '@PipelineRunId' BigInt $PipelineRunId
        $null = Add-SqlParameter $command '@Status' VarChar 'Failed' 20
        $null = Add-SqlParameter $command '@ErrorMessage' NVarChar $ErrorMessage -1
        $null = Add-SqlParameter $command '@CommitCheckpoint' Bit $false
        $null = $command.ExecuteNonQuery()
    }
    finally {
        $command.Dispose()
    }
}

function Invoke-RegisterFileArtifact {
    param([Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection)

    $command = $Connection.CreateCommand()
    $command.CommandText = '[audit].[usp_RegisterFileArtifact]'
    $command.CommandType = [System.Data.CommandType]::StoredProcedure
    try {
        $null = Add-SqlParameter $command '@FeedName' NVarChar $feedName 128
        $null = Add-SqlParameter $command '@RemoteDirectory' NVarChar ([string]$manifest.remoteDirectory) 1024
        $null = Add-SqlParameter $command '@RemoteFileName' NVarChar ([string]$manifest.remoteFileName) 260
        $null = Add-SqlParameter $command '@RemoteSizeBytes' BigInt ([long]$manifest.remoteSizeBytes)
        $null = Add-SqlParameter $command '@RemoteModifiedAtUtc' DateTime2 ([datetime]::Parse([string]$manifest.remoteModifiedAtUtc).ToUniversalTime())
        $null = Add-SqlParameter $command '@ArchiveRelativePath' NVarChar ([string]$manifest.archiveRelativePath) 1024
        $null = Add-SqlParameter $command '@ArchiveSha256' Binary (Convert-HexToByteArray ([string]$manifest.archiveSha256)) 32
        $null = Add-SqlParameter $command '@ArchiveSizeBytes' BigInt ([long]$manifest.archiveSizeBytes)
        $null = Add-SqlParameter $command '@AcquiredAtUtc' DateTime2 ([datetime]::Parse([string]$manifest.acquiredAtUtc).ToUniversalTime())
        $id = Add-SqlParameter $command '@FileArtifactId' BigInt $null 0 Output
        $inserted = Add-SqlParameter $command '@WasInserted' Bit $null 0 Output
        $null = $command.ExecuteNonQuery()
        return [pscustomobject]@{ FileArtifactId = [long]$id.Value; WasInserted = [bool]$inserted.Value }
    }
    finally {
        $command.Dispose()
    }
}

function Invoke-StartFileLoadAttempt {
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory)][long]$PipelineRunId,
        [Parameter(Mandatory)][long]$FileArtifactId
    )

    $command = $Connection.CreateCommand()
    $command.CommandText = '[audit].[usp_StartFileLoadAttempt]'
    $command.CommandType = [System.Data.CommandType]::StoredProcedure
    try {
        $null = Add-SqlParameter $command '@PipelineRunId' BigInt $PipelineRunId
        $null = Add-SqlParameter $command '@FileArtifactId' BigInt $FileArtifactId
        $null = Add-SqlParameter $command '@FeedName' NVarChar $feedName 128
        $null = Add-SqlParameter $command '@CsvFileName' NVarChar ([string]$manifest.csvFileName) 260
        $null = Add-SqlParameter $command '@CsvSha256' Binary (Convert-HexToByteArray ([string]$manifest.csvSha256)) 32
        $null = Add-SqlParameter $command '@CsvSizeBytes' BigInt ([long]$manifest.csvSizeBytes)
        $null = Add-SqlParameter $command '@MappingName' NVarChar ([string]$mapping.name) 128
        $null = Add-SqlParameter $command '@MappingVersion' NVarChar ([string]$mapping.version) 64
        $null = Add-SqlParameter $command '@MappingSha256' Binary $mappingHashBytes 32
        $null = Add-SqlParameter $command '@TargetSchema' NVarChar ([string]$mapping.target.schema) 128
        $null = Add-SqlParameter $command '@TargetTable' NVarChar ([string]$mapping.target.table) 128
        $null = Add-SqlParameter $command '@HostName' NVarChar ([Environment]::MachineName) 128
        $null = Add-SqlParameter $command '@ProcessId' Int $PID
        $null = Add-SqlParameter $command '@AbandonStartedAfterMinutes' Int $script:AbandonStartedAfterMinutesValue
        $fileLoad = Add-SqlParameter $command '@FileLoadId' BigInt $null 0 Output
        $attempt = Add-SqlParameter $command '@FileLoadAttemptId' BigInt $null 0 Output
        $skip = Add-SqlParameter $command '@ShouldSkip' Bit $null 0 Output
        $null = $command.ExecuteNonQuery()
        return [pscustomobject]@{
            FileLoadId = [long]$fileLoad.Value
            FileLoadAttemptId = if ($attempt.Value -eq [DBNull]::Value) { $null } else { [long]$attempt.Value }
            ShouldSkip = [bool]$skip.Value
        }
    }
    finally {
        $command.Dispose()
    }
}

function Invoke-RecordCsvRejects {
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory)][long]$FileLoadAttemptId,
        [Parameter(Mandatory)]$Rejects
    )

    if ($Rejects.Count -eq 0) { return }
    $payload = @($Rejects | ForEach-Object {
        [ordered]@{
            sourceRecordNumber = $_.SourceRecordNumber
            reason = $_.Reason
            rawFragment = $_.RawFragment
        }
    }) | ConvertTo-Json -Depth 4 -Compress
    $command = $Connection.CreateCommand()
    $command.CommandText = '[audit].[usp_RecordCsvRowRejects]'
    $command.CommandType = [System.Data.CommandType]::StoredProcedure
    try {
        $null = Add-SqlParameter $command '@FileLoadAttemptId' BigInt $FileLoadAttemptId
        $null = Add-SqlParameter $command '@RejectsJson' NVarChar $payload -1
        $null = $command.ExecuteNonQuery()
    }
    finally {
        $command.Dispose()
    }
}

function Invoke-CompleteFileLoadAttempt {
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory)][long]$FileLoadAttemptId,
        [Parameter(Mandatory)][ValidateSet('Succeeded', 'Failed')][string]$Status,
        [Nullable[long]]$RowsParsed,
        [Nullable[long]]$RowsStaged,
        [Nullable[long]]$RowsRejected,
        [Nullable[decimal]]$DurationSeconds,
        [string]$ErrorMessage
    )

    $command = $Connection.CreateCommand()
    $command.CommandText = '[audit].[usp_CompleteFileLoadAttempt]'
    $command.CommandType = [System.Data.CommandType]::StoredProcedure
    try {
        $null = Add-SqlParameter $command '@FileLoadAttemptId' BigInt $FileLoadAttemptId
        $null = Add-SqlParameter $command '@Status' VarChar $Status 20
        $null = Add-SqlParameter $command '@RowsParsed' BigInt $RowsParsed
        $null = Add-SqlParameter $command '@RowsStaged' BigInt $RowsStaged
        $null = Add-SqlParameter $command '@RowsRejected' BigInt $RowsRejected
        $duration = Add-SqlParameter $command '@DurationSeconds' Decimal $DurationSeconds
        $duration.Precision = 18
        $duration.Scale = 3
        $null = Add-SqlParameter $command '@ErrorMessage' NVarChar $ErrorMessage -1
        $null = $command.ExecuteNonQuery()
    }
    finally {
        $command.Dispose()
    }
}

function Test-IsTransientSqlFailure {
    param([Parameter(Mandatory)][Exception]$Exception)
    $current = $Exception
    while ($current) {
        if ($current.PSObject.Properties.Name -contains 'Number' -and [int]$current.Number -in $script:TransientSqlErrors) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
}

function Test-LandingTableContract {
    param([Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection)

    $schemaName = [string]$mapping.target.schema
    $tableName = [string]$mapping.target.table
    $command = $Connection.CreateCommand()
    $command.CommandText = @'
SELECT
    [columns].[name],
    [types].[name] AS [TypeName],
    [columns].[max_length],
    [columns].[scale],
    [columns].[is_nullable],
    [columns].[is_identity],
    [columns].[is_computed]
FROM sys.tables AS [tables]
INNER JOIN sys.schemas AS [schemas]
    ON [schemas].[schema_id] = [tables].[schema_id]
INNER JOIN sys.columns AS [columns]
    ON [columns].[object_id] = [tables].[object_id]
INNER JOIN sys.types AS [types]
    ON [types].[user_type_id] = [columns].[user_type_id]
WHERE [schemas].[name] = @SchemaName
  AND [tables].[name] = @TableName;
'@
    $null = Add-SqlParameter $command '@SchemaName' NVarChar $schemaName 128
    $null = Add-SqlParameter $command '@TableName' NVarChar $tableName 128
    $actual = @{}
    try {
        $reader = $command.ExecuteReader()
        try {
            while ($reader.Read()) {
                $actual[[string]$reader['name']] = [pscustomobject]@{
                    TypeName = [string]$reader['TypeName']
                    MaxLength = [int]$reader['max_length']
                    Scale = [int]$reader['scale']
                    IsNullable = [bool]$reader['is_nullable']
                    IsIdentity = [bool]$reader['is_identity']
                    IsComputed = [bool]$reader['is_computed']
                }
            }
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $command.Dispose()
    }
    if ($actual.Count -eq 0) {
        throw "Landing table [$schemaName].[$tableName] does not exist. Add it to the SQL project before loading."
    }

    foreach ($column in $mapping.columns) {
        $target = [string]$column.target
        if (-not $actual.ContainsKey($target)) {
            throw "Landing table is missing mapped target column '$target'."
        }
        $metadata = $actual[$target]
        if ($metadata.TypeName -ne 'nvarchar' -or -not $metadata.IsNullable -or $metadata.IsIdentity -or $metadata.IsComputed) {
            throw "Landing column '$target' must be a nullable, noncomputed, nonidentity NVARCHAR column."
        }
        $requiredCharacters = [int]$column.landingMaxLength
        if ($requiredCharacters -eq -1 -and $metadata.MaxLength -ne -1) {
            throw "Landing column '$target' must be NVARCHAR(MAX) for landingMaxLength -1."
        }
        if ($requiredCharacters -gt 0 -and $metadata.MaxLength -ne -1 -and ($metadata.MaxLength / 2) -lt $requiredCharacters) {
            throw "Landing column '$target' holds $($metadata.MaxLength / 2) characters but mapping requires $requiredCharacters."
        }
    }

    $technical = @{
        FileLoadId = @{ Type = 'bigint'; Nullable = $false }
        FileLoadAttemptId = @{ Type = 'bigint'; Nullable = $false }
        SourceRecordNumber = @{ Type = 'bigint'; Nullable = $false }
        SourceFileName = @{ Type = 'nvarchar'; Nullable = $false; MinCharacters = 260 }
        IngestedAtUtc = @{ Type = 'datetime2'; Nullable = $false; Scale = 7 }
    }
    foreach ($name in $technical.Keys) {
        if (-not $actual.ContainsKey($name)) {
            throw "Landing table is missing technical column '$name'."
        }
        $expected = $technical[$name]
        $metadata = $actual[$name]
        if ($metadata.TypeName -ne $expected.Type -or $metadata.IsNullable -ne $expected.Nullable) {
            throw "Landing technical column '$name' has an invalid type or nullability."
        }
        if ($expected.ContainsKey('MinCharacters') -and $metadata.MaxLength -ne -1 -and ($metadata.MaxLength / 2) -lt $expected.MinCharacters) {
            throw "Landing technical column '$name' is too narrow."
        }
        if ($expected.ContainsKey('Scale') -and $metadata.Scale -ne $expected.Scale) {
            throw "Landing technical column '$name' must use scale $($expected.Scale)."
        }
    }

    if ($mapping.target.requireHeap) {
        $indexCommand = $Connection.CreateCommand()
        $indexCommand.CommandText = @'
SELECT COUNT_BIG(*)
FROM sys.indexes AS [indexes]
INNER JOIN sys.tables AS [tables]
    ON [tables].[object_id] = [indexes].[object_id]
INNER JOIN sys.schemas AS [schemas]
    ON [schemas].[schema_id] = [tables].[schema_id]
WHERE [schemas].[name] = @SchemaName
  AND [tables].[name] = @TableName
  AND [indexes].[index_id] > 0;
'@
        $null = Add-SqlParameter $indexCommand '@SchemaName' NVarChar $schemaName 128
        $null = Add-SqlParameter $indexCommand '@TableName' NVarChar $tableName 128
        try {
            if ([long]$indexCommand.ExecuteScalar() -ne 0) {
                throw "Landing table [$schemaName].[$tableName] must be a heap because target.requireHeap is true."
            }
        }
        finally {
            $indexCommand.Dispose()
        }
    }
}

function Clear-PartialRows {
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory)][long]$FileLoadId
    )

    $schemaName = [string]$mapping.target.schema
    $tableName = [string]$mapping.target.table
    $command = $Connection.CreateCommand()
    $command.CommandText = "DELETE FROM [$schemaName].[$tableName] WHERE [FileLoadId] = @FileLoadId;"
    $command.CommandTimeout = 0
    $null = Add-SqlParameter $command '@FileLoadId' BigInt $FileLoadId
    try {
        return [long]$command.ExecuteNonQuery()
    }
    finally {
        $command.Dispose()
    }
}

function Get-StagedRowCount {
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory)][long]$FileLoadId
    )

    $schemaName = [string]$mapping.target.schema
    $tableName = [string]$mapping.target.table
    $command = $Connection.CreateCommand()
    $command.CommandText = "SELECT COUNT_BIG(*) FROM [$schemaName].[$tableName] WHERE [FileLoadId] = @FileLoadId;"
    $command.CommandTimeout = 0
    $null = Add-SqlParameter $command '@FileLoadId' BigInt $FileLoadId
    try {
        return [long]$command.ExecuteScalar()
    }
    finally {
        $command.Dispose()
    }
}

function Invoke-BulkCopy {
    param(
        [Parameter(Mandatory)][long]$FileLoadId,
        [Parameter(Mandatory)][long]$FileLoadAttemptId
    )

    $csvFile = Get-Item -LiteralPath ([string]$manifest.csvPath)
    $source = $mapping.source
    $encoding = [System.Text.Encoding]::GetEncoding([string]$source.encoding)
    $stream = [System.IO.FileStream]::new($csvFile.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read, 1048576, [System.IO.FileOptions]::SequentialScan)
    $textReader = [System.IO.StreamReader]::new($stream, $encoding, $true, 1048576)
    [string[]]$sourceColumns = @($mapping.columns | ForEach-Object { [string]$_.source })
    [string[]]$targetColumns = @($mapping.columns | ForEach-Object { [string]$_.target })
    [bool[]]$optionalColumns = @($mapping.columns | ForEach-Object { [bool]$_.optional })
    [int[]]$landingLengths = @($mapping.columns | ForEach-Object { [int]$_.landingMaxLength })
    $reader = [SqlServerMedallion.Bronze.CsvDataReader]::new(
        $textReader,
        [char]([string]$source.delimiter),
        [char]([string]$source.quote),
        [bool]$source.treatEmptyAsNull,
        $sourceColumns,
        $targetColumns,
        $optionalColumns,
        $landingLengths,
        $FileLoadId,
        $FileLoadAttemptId,
        $csvFile.Name,
        [DateTime]::UtcNow)
    $reader.MaxRejects = $MaxRejects
    $reader.MaxRecordCharacters = $MaxRecordCharacters
    $reader.CaptureRejectFragments = [bool]$CaptureRejectFragments

    $mappedSources = @($mapping.columns | ForEach-Object { [string]$_.source })
    $extraColumns = @($reader.Header | Where-Object { $_ -notin $mappedSources })
    if ($extraColumns.Count -gt 0) {
        if ($mapping.strictHeader) {
            $reader.Dispose()
            throw "CSV header contains unmapped column(s): $($extraColumns -join ', ')."
        }
        Write-LoadEvent -Message "CSV header contains unmapped column(s): $($extraColumns -join ', ')." -Level Warn
    }

    $options = [System.Data.SqlClient.SqlBulkCopyOptions]::TableLock -bor
        [System.Data.SqlClient.SqlBulkCopyOptions]::KeepNulls -bor
        [System.Data.SqlClient.SqlBulkCopyOptions]::UseInternalTransaction
    $connection = New-SqlConnection
    $bulk = [System.Data.SqlClient.SqlBulkCopy]::new($connection, $options, $null)
    $handler = [System.Data.SqlClient.SqlRowsCopiedEventHandler]{
        param($sender, $eventArgs)
        Write-Host ('  ... {0:N0} rows copied' -f $eventArgs.RowsCopied) -ForegroundColor DarkGray
    }
    try {
        $bulk.DestinationTableName = "[$($mapping.target.schema)].[$($mapping.target.table)]"
        $bulk.BatchSize = $BatchSize
        $bulk.NotifyAfter = $NotifyAfter
        $bulk.BulkCopyTimeout = $BulkCopyTimeoutSeconds
        $bulk.EnableStreaming = $true
        foreach ($targetColumn in $targetColumns) {
            $null = $bulk.ColumnMappings.Add($targetColumn, $targetColumn)
        }
        foreach ($technicalColumn in 'FileLoadId', 'FileLoadAttemptId', 'SourceRecordNumber', 'SourceFileName', 'IngestedAtUtc') {
            $null = $bulk.ColumnMappings.Add($technicalColumn, $technicalColumn)
        }
        $bulk.add_SqlRowsCopied($handler)
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        $bulk.WriteToServer([System.Data.IDataReader]$reader)
        $stopwatch.Stop()
        return [pscustomobject]@{
            RowsParsed = $reader.RowsParsed
            RowsAccepted = $reader.RowsAccepted
            RowsRejected = $reader.RowsRejected
            Rejects = @($reader.Rejects)
            DurationSeconds = $stopwatch.Elapsed.TotalSeconds
        }
    }
    finally {
        $bulk.remove_SqlRowsCopied($handler)
        $bulk.Dispose()
        $connection.Dispose()
        $reader.Dispose()
    }
}

if ([int](Get-RequiredProperty $manifest 'schemaVersion' 'Artifact manifest') -ne 1) {
    throw 'Unsupported artifact manifest schemaVersion.'
}
if ([int](Get-RequiredProperty $mapping 'schemaVersion' 'CSV mapping') -ne 1) {
    throw 'Unsupported CSV mapping schemaVersion.'
}
$feedName = [string](Get-RequiredProperty $manifest 'feedName' 'Artifact manifest')
foreach ($name in 'remoteDirectory', 'remoteFileName', 'remoteSizeBytes', 'remoteModifiedAtUtc', 'acquiredAtUtc', 'archivePath', 'archiveRelativePath', 'archiveSha256', 'archiveSizeBytes', 'csvPath', 'csvFileName', 'csvSha256', 'csvSizeBytes') {
    $null = Get-RequiredProperty $manifest $name 'Artifact manifest'
}
foreach ($name in 'name', 'version', 'source', 'target', 'columns') {
    $null = Get-RequiredProperty $mapping $name 'CSV mapping'
}
if (-not $mapping.PSObject.Properties.Name.Contains('strictHeader')) {
    $mapping | Add-Member -MemberType NoteProperty -Name strictHeader -Value $true
}
foreach ($name in 'delimiter', 'quote', 'hasHeader', 'encoding', 'treatEmptyAsNull') {
    $null = Get-RequiredProperty $mapping.source $name 'CSV mapping source'
}
if (-not [bool]$mapping.source.hasHeader) {
    throw 'The robust name-based loader requires source.hasHeader=true.'
}
if (([string]$mapping.source.delimiter).Length -ne 1 -or ([string]$mapping.source.quote).Length -ne 1) {
    throw 'CSV delimiter and quote must each contain exactly one character.'
}
$null = [System.Text.Encoding]::GetEncoding([string]$mapping.source.encoding)
foreach ($name in 'schema', 'table', 'requireHeap') {
    $null = Get-RequiredProperty $mapping.target $name 'CSV mapping target'
}
if ([string]$mapping.target.schema -ne 'bronze') {
    throw 'CSV mapping target.schema must be bronze.'
}
Assert-SqlIdentifier ([string]$mapping.target.schema) 'target.schema'
Assert-SqlIdentifier ([string]$mapping.target.table) 'target.table'
if (@($mapping.columns).Count -eq 0) {
    throw 'CSV mapping must contain at least one column.'
}
$duplicateSources = @($mapping.columns.source | Group-Object | Where-Object Count -gt 1)
$duplicateTargets = @($mapping.columns.target | Group-Object | Where-Object Count -gt 1)
if ($duplicateSources.Count -gt 0 -or $duplicateTargets.Count -gt 0) {
    throw 'CSV mapping source and target column names must be unique.'
}
foreach ($column in $mapping.columns) {
    foreach ($name in 'source', 'target', 'landingMaxLength', 'businessType', 'optional') {
        $null = Get-RequiredProperty $column $name 'CSV mapping column'
    }
    Assert-SqlIdentifier ([string]$column.target) 'column.target'
    if ([int]$column.landingMaxLength -eq 0 -or [int]$column.landingMaxLength -lt -1) {
        throw "Column '$($column.target)' landingMaxLength must be -1 for NVARCHAR(MAX) or a positive character count."
    }
}

$archiveFile = Get-Item -LiteralPath ([string]$manifest.archivePath)
$csvFile = Get-Item -LiteralPath ([string]$manifest.csvPath)
if ($archiveFile.Length -ne [long]$manifest.archiveSizeBytes -or $archiveFile.Length -ne [long]$manifest.remoteSizeBytes) {
    throw 'Archive manifest byte counts do not reconcile.'
}
if ($csvFile.Length -ne [long]$manifest.csvSizeBytes) {
    throw 'CSV manifest byte count does not match the extracted file.'
}
if (-not $SkipHashVerification) {
    if ((Get-Sha256Hex $archiveFile.FullName) -ne ([string]$manifest.archiveSha256).ToLowerInvariant()) {
        throw 'Archived ZIP SHA-256 does not match the artifact manifest.'
    }
    if ((Get-Sha256Hex $csvFile.FullName) -ne ([string]$manifest.csvSha256).ToLowerInvariant()) {
        throw 'Extracted CSV SHA-256 does not match the artifact manifest.'
    }
}

$mappingHashHex = Get-Sha256Hex $mappingFile.FullName
$mappingHashBytes = Convert-HexToByteArray $mappingHashHex
if (-not $PSBoundParameters.ContainsKey('LogDirectory')) {
    $LogDirectory = Join-Path $manifestFile.DirectoryName 'logs'
}
New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
$logPath = Join-Path $LogDirectory ('csvload-{0:yyyyMMdd-HHmmss}-{1}.jsonl' -f [DateTime]::UtcNow, ([guid]::NewGuid().ToString('N').Substring(0, 8)))

function Write-LoadEvent {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info',
        [hashtable]$Data
    )
    $event = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        level = $Level
        feedName = $feedName
        mappingName = [string]$mapping.name
        message = $Message
        host = [Environment]::MachineName
        processId = $PID
        data = $Data
    }
    ($event | ConvertTo-Json -Depth 6 -Compress) | Add-Content -LiteralPath $logPath -Encoding utf8NoBOM
    $color = if ($Level -eq 'Error') { 'Red' } elseif ($Level -eq 'Warn') { 'Yellow' } else { 'Gray' }
    Write-Host ('{0:HH:mm:ss} [{1,-5}] {2}' -f [DateTime]::Now, $Level.ToUpperInvariant(), $Message) -ForegroundColor $color
}

$readerSource = Join-Path $PSScriptRoot 'CsvDataReader.cs'
if ($null -eq ('SqlServerMedallion.Bronze.CsvDataReader' -as [type])) {
    Add-Type -Path $readerSource
}

if (-not $PSCmdlet.ShouldProcess($csvFile.FullName, "Bulk load into [$($mapping.target.schema)].[$($mapping.target.table)]")) {
    return
}

$control = New-SqlConnection
try {
    Test-LandingTableContract -Connection $control
    $artifact = Invoke-RegisterFileArtifact -Connection $control
    Write-LoadEvent -Message 'Artifact registered.' -Data @{
        fileArtifactId = $artifact.FileArtifactId
        wasInserted = $artifact.WasInserted
        archiveSha256 = [string]$manifest.archiveSha256
        csvSha256 = [string]$manifest.csvSha256
        mappingSha256 = $mappingHashHex
    }

    for ($attemptIndex = 1; $attemptIndex -le $MaxAttempts; $attemptIndex++) {
        $pipelineRunId = Invoke-StartPipelineRun -Connection $control
        try {
            $attempt = Invoke-StartFileLoadAttempt -Connection $control -PipelineRunId $pipelineRunId -FileArtifactId $artifact.FileArtifactId
        }
        catch {
            try { Invoke-CompleteOrphanPipelineRun -Connection $control -PipelineRunId $pipelineRunId -ErrorMessage $_.Exception.Message }
            catch { Write-Warning "Could not close pipeline run $pipelineRunId after attempt-start failure: $($_.Exception.Message)" }
            throw
        }

        if ($attempt.ShouldSkip) {
            Write-LoadEvent -Message 'Identical CSV content, mapping, and Bronze target already succeeded; skipped.' -Level Warn -Data @{
                fileLoadId = $attempt.FileLoadId
                pipelineRunId = $pipelineRunId
            }
            return [pscustomobject]@{
                Status = 'Skipped'
                FileLoadId = $attempt.FileLoadId
                FileLoadAttemptId = $null
                PipelineRunId = $pipelineRunId
                RowsParsed = 0
                RowsStaged = 0
                RowsRejected = 0
                LogPath = $logPath
            }
        }

        $deletedRows = Clear-PartialRows -Connection $control -FileLoadId $attempt.FileLoadId
        if ($deletedRows -gt 0) {
            Write-LoadEvent -Message "Removed $deletedRows partial row(s) before retrying the logical file load." -Level Warn -Data @{
                fileLoadId = $attempt.FileLoadId
                fileLoadAttemptId = $attempt.FileLoadAttemptId
            }
        }

        $attemptStopwatch = [Diagnostics.Stopwatch]::StartNew()
        try {
            Write-LoadEvent -Message "Starting bulk-copy attempt $attemptIndex/$MaxAttempts." -Data @{
                fileLoadId = $attempt.FileLoadId
                fileLoadAttemptId = $attempt.FileLoadAttemptId
                pipelineRunId = $pipelineRunId
                csvSizeBytes = $csvFile.Length
                batchSize = $BatchSize
            }
            $result = Invoke-BulkCopy -FileLoadId $attempt.FileLoadId -FileLoadAttemptId $attempt.FileLoadAttemptId
            $stagedRows = Get-StagedRowCount -Connection $control -FileLoadId $attempt.FileLoadId
            if ($result.RowsAccepted -ne $stagedRows -or $result.RowsParsed -ne $stagedRows + $result.RowsRejected) {
                throw "Row reconciliation failed: parsed $($result.RowsParsed), accepted $($result.RowsAccepted), staged $stagedRows, rejected $($result.RowsRejected)."
            }
            Invoke-RecordCsvRejects -Connection $control -FileLoadAttemptId $attempt.FileLoadAttemptId -Rejects $result.Rejects
            $attemptStopwatch.Stop()
            Invoke-CompleteFileLoadAttempt `
                -Connection $control `
                -FileLoadAttemptId $attempt.FileLoadAttemptId `
                -Status Succeeded `
                -RowsParsed $result.RowsParsed `
                -RowsStaged $stagedRows `
                -RowsRejected $result.RowsRejected `
                -DurationSeconds ([decimal]$attemptStopwatch.Elapsed.TotalSeconds)

            $rowsPerSecond = if ($result.DurationSeconds -gt 0) { $result.RowsParsed / $result.DurationSeconds } else { 0 }
            $mbPerSecond = if ($result.DurationSeconds -gt 0) { ($csvFile.Length / 1MB) / $result.DurationSeconds } else { 0 }
            Write-LoadEvent -Message 'Bulk load succeeded and reconciled.' -Data @{
                fileLoadId = $attempt.FileLoadId
                fileLoadAttemptId = $attempt.FileLoadAttemptId
                pipelineRunId = $pipelineRunId
                rowsParsed = $result.RowsParsed
                rowsStaged = $stagedRows
                rowsRejected = $result.RowsRejected
                rowsPerSecond = [math]::Round($rowsPerSecond)
                mbPerSecond = [math]::Round($mbPerSecond, 2)
            }
            return [pscustomobject]@{
                Status = 'Succeeded'
                FileLoadId = $attempt.FileLoadId
                FileLoadAttemptId = $attempt.FileLoadAttemptId
                PipelineRunId = $pipelineRunId
                RowsParsed = $result.RowsParsed
                RowsStaged = $stagedRows
                RowsRejected = $result.RowsRejected
                RowsPerSecond = [math]::Round($rowsPerSecond)
                MegabytesPerSecond = [math]::Round($mbPerSecond, 2)
                LogPath = $logPath
            }
        }
        catch {
            $attemptStopwatch.Stop()
            $failure = $_
            $isTransient = Test-IsTransientSqlFailure -Exception $failure.Exception
            try {
                Invoke-CompleteFileLoadAttempt `
                    -Connection $control `
                    -FileLoadAttemptId $attempt.FileLoadAttemptId `
                    -Status Failed `
                    -DurationSeconds ([decimal]$attemptStopwatch.Elapsed.TotalSeconds) `
                    -ErrorMessage $failure.Exception.Message
            }
            catch {
                Write-Warning "Could not complete failed file-load attempt $($attempt.FileLoadAttemptId): $($_.Exception.Message)"
            }
            try {
                $removedAfterFailure = Clear-PartialRows -Connection $control -FileLoadId $attempt.FileLoadId
                Write-LoadEvent -Message "Removed $removedAfterFailure partial row(s) after failed attempt." -Level Warn
            }
            catch {
                Write-LoadEvent -Message "Could not remove partial rows after failure: $($_.Exception.Message)" -Level Warn
            }

            if (-not $isTransient -or $attemptIndex -eq $MaxAttempts) {
                Write-LoadEvent -Message "Bulk load failed: $($failure.Exception.Message)" -Level Error -Data @{
                    fileLoadId = $attempt.FileLoadId
                    fileLoadAttemptId = $attempt.FileLoadAttemptId
                    transient = $isTransient
                }
                throw $failure
            }

            $delaySeconds = [math]::Min(30, [math]::Pow(2, $attemptIndex)) + (Get-Random -Minimum 0.0 -Maximum 1.0)
            Write-LoadEvent -Message "Transient SQL failure; retrying with a new physical attempt in $([math]::Round($delaySeconds, 1)) seconds." -Level Warn
            Start-Sleep -Seconds $delaySeconds
        }
    }
}
finally {
    $control.Dispose()
}
