CREATE PROCEDURE [audit].[usp_StartFileLoadAttempt]
    @PipelineRunId BIGINT,
    @FileArtifactId BIGINT,
    @FeedName NVARCHAR(128),
    @CsvFileName NVARCHAR(260),
    @CsvSha256 BINARY(32),
    @CsvSizeBytes BIGINT,
    @MappingName NVARCHAR(128),
    @MappingVersion NVARCHAR(64),
    @MappingSha256 BINARY(32),
    @TargetSchema NVARCHAR(128),
    @TargetTable NVARCHAR(128),
    @HostName NVARCHAR(128),
    @ProcessId INT,
    @AbandonStartedAfterMinutes INT = NULL,
    @FileLoadId BIGINT OUTPUT,
    @FileLoadAttemptId BIGINT OUTPUT,
    @ShouldSkip BIT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @TargetSchema <> N'bronze'
        THROW 51110, N'CSV landing targets must be in the bronze schema.', 1;

    IF @CsvSizeBytes < 0
        THROW 51111, N'CsvSizeBytes cannot be negative.', 1;

    IF @ProcessId <= 0
        THROW 51112, N'ProcessId must be positive.', 1;

    IF @AbandonStartedAfterMinutes IS NOT NULL AND @AbandonStartedAfterMinutes <= 0
        THROW 51113, N'AbandonStartedAfterMinutes must be positive when supplied.', 1;

    IF NULLIF(LTRIM(RTRIM(@FeedName)), N'') IS NULL
       OR NULLIF(LTRIM(RTRIM(@CsvFileName)), N'') IS NULL
       OR NULLIF(LTRIM(RTRIM(@MappingName)), N'') IS NULL
       OR NULLIF(LTRIM(RTRIM(@MappingVersion)), N'') IS NULL
       OR NULLIF(LTRIM(RTRIM(@TargetTable)), N'') IS NULL
       OR NULLIF(LTRIM(RTRIM(@HostName)), N'') IS NULL
        THROW 51114, N'File-load identity, mapping, target, and host values are required.', 1;

    DECLARE @InitialTransactionCount INT = @@TRANCOUNT;
    DECLARE @ExistingStatus VARCHAR(20);
    DECLARE @ActiveAttemptId BIGINT;
    DECLARE @ActiveAttemptStartedAtUtc DATETIME2(7);
    DECLARE @AbandonedPipelineRunId BIGINT;
    DECLARE @AttemptNumber INT;

    BEGIN TRY
        IF @InitialTransactionCount = 0
            BEGIN TRANSACTION;
        ELSE
            SAVE TRANSACTION [StartFileLoadAttempt];

        IF NOT EXISTS
        (
            SELECT 1
            FROM [audit].[PipelineRun] WITH (UPDLOCK, HOLDLOCK)
            WHERE [PipelineRunId] = @PipelineRunId
              AND [Status] = 'Started'
        )
            THROW 51115, N'The pipeline run does not exist or is already complete.', 1;

        IF NOT EXISTS
        (
            SELECT 1
            FROM [audit].[FileArtifact]
            WHERE [FileArtifactId] = @FileArtifactId
              AND [FeedName] = @FeedName
        )
            THROW 51116, N'The file artifact does not exist for the specified feed.', 1;

        SELECT
            @FileLoadId = [FileLoadId],
            @ExistingStatus = [Status]
        FROM [audit].[FileLoad] WITH (UPDLOCK, HOLDLOCK)
        WHERE [FeedName] = @FeedName
          AND [CsvSha256] = @CsvSha256
          AND [TargetSchema] = @TargetSchema
          AND [TargetTable] = @TargetTable
          AND [MappingSha256] = @MappingSha256;

        IF @ExistingStatus = 'Succeeded'
        BEGIN
            SET @FileLoadAttemptId = NULL;
            SET @ShouldSkip = 1;

            EXEC [audit].[usp_CompletePipelineRun]
                @PipelineRunId = @PipelineRunId,
                @Status = 'Succeeded',
                @RowsRead = 0,
                @RowsWritten = 0,
                @RowsRejected = 0,
                @CommitCheckpoint = 0;

            IF @InitialTransactionCount = 0
                COMMIT TRANSACTION;

            RETURN;
        END;

        IF @ExistingStatus = 'Started'
        BEGIN
            SELECT TOP (1)
                @ActiveAttemptId = [FileLoadAttemptId],
                @ActiveAttemptStartedAtUtc = [StartedAtUtc],
                @AbandonedPipelineRunId = [PipelineRunId]
            FROM [audit].[FileLoadAttempt] WITH (UPDLOCK, HOLDLOCK)
            WHERE [FileLoadId] = @FileLoadId
              AND [Status] = 'Started'
            ORDER BY [AttemptNumber] DESC;

            IF @ActiveAttemptId IS NOT NULL
            BEGIN
                IF @AbandonStartedAfterMinutes IS NULL
                   OR @ActiveAttemptStartedAtUtc >= DATEADD(MINUTE, -@AbandonStartedAfterMinutes, SYSUTCDATETIME())
                    THROW 51117, N'Another file-load attempt is still active. Verify that process before explicitly abandoning a stale attempt.', 1;

                UPDATE [audit].[FileLoadAttempt]
                SET
                    [Status] = 'Abandoned',
                    [CompletedAtUtc] = SYSUTCDATETIME(),
                    [ErrorMessage] = N'Explicitly abandoned as stale before a restart.'
                WHERE [FileLoadAttemptId] = @ActiveAttemptId;

                EXEC [audit].[usp_CompletePipelineRun]
                    @PipelineRunId = @AbandonedPipelineRunId,
                    @Status = 'Failed',
                    @ErrorMessage = N'File-load attempt was explicitly abandoned as stale.',
                    @CommitCheckpoint = 0;

                UPDATE [audit].[FileLoad]
                SET
                    [Status] = 'Failed',
                    [CompletedAtUtc] = SYSUTCDATETIME(),
                    [ErrorMessage] = N'Previous file-load attempt was explicitly abandoned as stale.'
                WHERE [FileLoadId] = @FileLoadId;
            END;
        END;

        IF @FileLoadId IS NULL
        BEGIN
            INSERT INTO [audit].[FileLoad]
            (
                [FileArtifactId],
                [FeedName],
                [CsvFileName],
                [CsvSha256],
                [CsvSizeBytes],
                [MappingName],
                [MappingVersion],
                [MappingSha256],
                [TargetSchema],
                [TargetTable],
                [Status]
            )
            VALUES
            (
                @FileArtifactId,
                @FeedName,
                @CsvFileName,
                @CsvSha256,
                @CsvSizeBytes,
                @MappingName,
                @MappingVersion,
                @MappingSha256,
                @TargetSchema,
                @TargetTable,
                'Started'
            );

            SET @FileLoadId = CONVERT(BIGINT, SCOPE_IDENTITY());
        END
        ELSE
        BEGIN
            UPDATE [audit].[FileLoad]
            SET
                [Status] = 'Started',
                [RowsParsed] = NULL,
                [RowsStaged] = NULL,
                [RowsRejected] = NULL,
                [DurationSeconds] = NULL,
                [ErrorMessage] = NULL,
                [CompletedAtUtc] = NULL
            WHERE [FileLoadId] = @FileLoadId;
        END;

        SELECT @AttemptNumber = COALESCE(MAX([AttemptNumber]), 0) + 1
        FROM [audit].[FileLoadAttempt] WITH (UPDLOCK, HOLDLOCK)
        WHERE [FileLoadId] = @FileLoadId;

        INSERT INTO [audit].[FileLoadAttempt]
        (
            [FileLoadId],
            [PipelineRunId],
            [AttemptNumber],
            [Status],
            [HostName],
            [ProcessId]
        )
        VALUES
        (
            @FileLoadId,
            @PipelineRunId,
            @AttemptNumber,
            'Started',
            @HostName,
            @ProcessId
        );

        SET @FileLoadAttemptId = CONVERT(BIGINT, SCOPE_IDENTITY());
        SET @ShouldSkip = 0;

        IF @InitialTransactionCount = 0
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @InitialTransactionCount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @InitialTransactionCount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION [StartFileLoadAttempt];

        THROW;
    END CATCH;
END;
