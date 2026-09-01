SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @ArchiveHash BINARY(32) = HASHBYTES('SHA2_256', N'smoke archive');
    DECLARE @CsvHash BINARY(32) = HASHBYTES('SHA2_256', N'smoke csv');
    DECLARE @MappingHash BINARY(32) = HASHBYTES('SHA2_256', N'smoke mapping');
    DECLARE @FileArtifactId BIGINT;
    DECLARE @DuplicateFileArtifactId BIGINT;
    DECLARE @WasInserted BIT;
    DECLARE @PipelineRunId BIGINT;
    DECLARE @RetryPipelineRunId BIGINT;
    DECLARE @SkipPipelineRunId BIGINT;
    DECLARE @FileLoadId BIGINT;
    DECLARE @RetryFileLoadId BIGINT;
    DECLARE @SkippedFileLoadId BIGINT;
    DECLARE @FileLoadAttemptId BIGINT;
    DECLARE @RetryFileLoadAttemptId BIGINT;
    DECLARE @SkippedFileLoadAttemptId BIGINT;
    DECLARE @ShouldSkip BIT;

    EXEC [audit].[usp_RegisterFileArtifact]
        @FeedName = N'SmokeSftpFeed',
        @RemoteDirectory = N'/outbound',
        @RemoteFileName = N'smoke.zip',
        @RemoteSizeBytes = 1024,
        @RemoteModifiedAtUtc = '2026-08-31T12:00:00Z',
        @ArchiveRelativePath = N'SmokeSftpFeed/2026/08/31/smoke.zip',
        @ArchiveSha256 = @ArchiveHash,
        @ArchiveSizeBytes = 1024,
        @AcquiredAtUtc = '2026-08-31T12:01:00Z',
        @FileArtifactId = @FileArtifactId OUTPUT,
        @WasInserted = @WasInserted OUTPUT;

    IF @WasInserted <> 1
        THROW 51140, N'The first artifact registration was not reported as new.', 1;

    EXEC [audit].[usp_RegisterFileArtifact]
        @FeedName = N'SmokeSftpFeed',
        @RemoteDirectory = N'/outbound',
        @RemoteFileName = N'renamed-smoke.zip',
        @RemoteSizeBytes = 1024,
        @RemoteModifiedAtUtc = '2026-08-31T12:02:00Z',
        @ArchiveRelativePath = N'SmokeSftpFeed/2026/08/31/renamed-smoke.zip',
        @ArchiveSha256 = @ArchiveHash,
        @ArchiveSizeBytes = 1024,
        @AcquiredAtUtc = '2026-08-31T12:03:00Z',
        @FileArtifactId = @DuplicateFileArtifactId OUTPUT,
        @WasInserted = @WasInserted OUTPUT;

    IF @WasInserted <> 0 OR @DuplicateFileArtifactId <> @FileArtifactId
        THROW 51141, N'Archive content idempotency did not return the existing artifact.', 1;

    EXEC [audit].[usp_StartPipelineRun]
        @PipelineName = N'Bronze.SmokeSftpFeed.CsvLoad',
        @PipelineVersion = N'test-1',
        @SourceSystem = N'SFTP:SmokeSftpFeed',
        @SourceObject = N'smoke.csv',
        @LoadMode = 'Full',
        @PipelineRunId = @PipelineRunId OUTPUT;

    EXEC [audit].[usp_StartFileLoadAttempt]
        @PipelineRunId = @PipelineRunId,
        @FileArtifactId = @FileArtifactId,
        @FeedName = N'SmokeSftpFeed',
        @CsvFileName = N'smoke.csv',
        @CsvSha256 = @CsvHash,
        @CsvSizeBytes = 4096,
        @MappingName = N'smoke_mapping',
        @MappingVersion = N'1.0.0',
        @MappingSha256 = @MappingHash,
        @TargetSchema = N'bronze',
        @TargetTable = N'SmokeRaw',
        @HostName = N'smoke-host',
        @ProcessId = 1234,
        @FileLoadId = @FileLoadId OUTPUT,
        @FileLoadAttemptId = @FileLoadAttemptId OUTPUT,
        @ShouldSkip = @ShouldSkip OUTPUT;

    IF @ShouldSkip <> 0 OR @FileLoadAttemptId IS NULL
        THROW 51142, N'The first physical load attempt was not started.', 1;

    EXEC [audit].[usp_RecordCsvRowRejects]
        @FileLoadAttemptId = @FileLoadAttemptId,
        @RejectsJson = N'[{"sourceRecordNumber":3,"reason":"Field count mismatch","rawFragment":null}]';

    EXEC [audit].[usp_CompleteFileLoadAttempt]
        @FileLoadAttemptId = @FileLoadAttemptId,
        @Status = 'Failed',
        @RowsParsed = 3,
        @RowsStaged = 2,
        @RowsRejected = 1,
        @DurationSeconds = 1.250,
        @ErrorMessage = N'Expected transient smoke-test failure.';

    EXEC [audit].[usp_StartPipelineRun]
        @PipelineName = N'Bronze.SmokeSftpFeed.CsvLoad',
        @PipelineVersion = N'test-1',
        @SourceSystem = N'SFTP:SmokeSftpFeed',
        @SourceObject = N'smoke.csv',
        @LoadMode = 'Full',
        @PipelineRunId = @RetryPipelineRunId OUTPUT;

    EXEC [audit].[usp_StartFileLoadAttempt]
        @PipelineRunId = @RetryPipelineRunId,
        @FileArtifactId = @FileArtifactId,
        @FeedName = N'SmokeSftpFeed',
        @CsvFileName = N'smoke.csv',
        @CsvSha256 = @CsvHash,
        @CsvSizeBytes = 4096,
        @MappingName = N'smoke_mapping',
        @MappingVersion = N'1.0.0',
        @MappingSha256 = @MappingHash,
        @TargetSchema = N'bronze',
        @TargetTable = N'SmokeRaw',
        @HostName = N'smoke-host',
        @ProcessId = 1234,
        @FileLoadId = @RetryFileLoadId OUTPUT,
        @FileLoadAttemptId = @RetryFileLoadAttemptId OUTPUT,
        @ShouldSkip = @ShouldSkip OUTPUT;

    IF @ShouldSkip <> 0
       OR @RetryFileLoadId <> @FileLoadId
       OR @RetryFileLoadAttemptId = @FileLoadAttemptId
        THROW 51143, N'The failed logical file load was not restarted as a new physical attempt.', 1;

    EXEC [audit].[usp_CompleteFileLoadAttempt]
        @FileLoadAttemptId = @RetryFileLoadAttemptId,
        @Status = 'Succeeded',
        @RowsParsed = 10,
        @RowsStaged = 9,
        @RowsRejected = 1,
        @DurationSeconds = 2.500;

    EXEC [audit].[usp_StartPipelineRun]
        @PipelineName = N'Bronze.SmokeSftpFeed.CsvLoad',
        @PipelineVersion = N'test-1',
        @SourceSystem = N'SFTP:SmokeSftpFeed',
        @SourceObject = N'smoke.csv',
        @LoadMode = 'Full',
        @PipelineRunId = @SkipPipelineRunId OUTPUT;

    EXEC [audit].[usp_StartFileLoadAttempt]
        @PipelineRunId = @SkipPipelineRunId,
        @FileArtifactId = @FileArtifactId,
        @FeedName = N'SmokeSftpFeed',
        @CsvFileName = N'smoke.csv',
        @CsvSha256 = @CsvHash,
        @CsvSizeBytes = 4096,
        @MappingName = N'smoke_mapping',
        @MappingVersion = N'1.0.0',
        @MappingSha256 = @MappingHash,
        @TargetSchema = N'bronze',
        @TargetTable = N'SmokeRaw',
        @HostName = N'smoke-host',
        @ProcessId = 1234,
        @FileLoadId = @SkippedFileLoadId OUTPUT,
        @FileLoadAttemptId = @SkippedFileLoadAttemptId OUTPUT,
        @ShouldSkip = @ShouldSkip OUTPUT;

    IF @ShouldSkip <> 1
       OR @SkippedFileLoadId <> @FileLoadId
       OR @SkippedFileLoadAttemptId IS NOT NULL
        THROW 51144, N'A previously successful content/mapping/target combination was not skipped.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM [audit].[FileLoad]
        WHERE [FileLoadId] = @FileLoadId
          AND [Status] = 'Succeeded'
          AND [RowsParsed] = 10
          AND [RowsStaged] = 9
          AND [RowsRejected] = 1
    )
        THROW 51145, N'The logical file load did not retain the reconciled successful outcome.', 1;

    IF
    (
        SELECT COUNT_BIG(*)
        FROM [audit].[FileLoadAttempt]
        WHERE [FileLoadId] = @FileLoadId
    ) <> 2
        THROW 51146, N'The logical file load did not retain both physical attempts.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM [audit].[PipelineRun]
        WHERE [PipelineRunId] = @SkipPipelineRunId
          AND [Status] = 'Succeeded'
          AND [RowsRead] = 0
          AND [RowsWritten] = 0
    )
        THROW 51147, N'The idempotent skip did not complete its pipeline run.', 1;

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;

PRINT N'File-ingestion control behavior is valid.';
