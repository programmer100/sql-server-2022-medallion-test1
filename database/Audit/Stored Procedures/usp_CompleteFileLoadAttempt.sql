CREATE PROCEDURE [audit].[usp_CompleteFileLoadAttempt]
    @FileLoadAttemptId BIGINT,
    @Status VARCHAR(20),
    @RowsParsed BIGINT = NULL,
    @RowsStaged BIGINT = NULL,
    @RowsRejected BIGINT = NULL,
    @DurationSeconds DECIMAL(18, 3) = NULL,
    @ErrorMessage NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Status NOT IN ('Succeeded', 'Failed')
        THROW 51130, N'File-load completion status must be Succeeded or Failed.', 1;

    IF @RowsParsed < 0 OR @RowsStaged < 0 OR @RowsRejected < 0 OR @DurationSeconds < 0
        THROW 51131, N'File-load counts and duration cannot be negative.', 1;

    IF @Status = 'Succeeded'
       AND
       (
           @RowsParsed IS NULL
           OR @RowsStaged IS NULL
           OR @RowsRejected IS NULL
           OR @RowsParsed <> @RowsStaged + @RowsRejected
       )
        THROW 51132, N'A successful file load must reconcile parsed rows to staged plus rejected rows.', 1;

    DECLARE @InitialTransactionCount INT = @@TRANCOUNT;
    DECLARE @FileLoadId BIGINT;
    DECLARE @PipelineRunId BIGINT;

    BEGIN TRY
        IF @InitialTransactionCount = 0
            BEGIN TRANSACTION;
        ELSE
            SAVE TRANSACTION [CompleteFileLoadAttempt];

        SELECT
            @FileLoadId = [FileLoadId],
            @PipelineRunId = [PipelineRunId]
        FROM [audit].[FileLoadAttempt] WITH (UPDLOCK, HOLDLOCK)
        WHERE [FileLoadAttemptId] = @FileLoadAttemptId
          AND [Status] = 'Started';

        IF @FileLoadId IS NULL
            THROW 51133, N'The file-load attempt does not exist or is already complete.', 1;

        UPDATE [audit].[FileLoadAttempt]
        SET
            [Status] = @Status,
            [RowsParsed] = @RowsParsed,
            [RowsStaged] = @RowsStaged,
            [RowsRejected] = @RowsRejected,
            [DurationSeconds] = @DurationSeconds,
            [ErrorMessage] = @ErrorMessage,
            [CompletedAtUtc] = SYSUTCDATETIME()
        WHERE [FileLoadAttemptId] = @FileLoadAttemptId;

        UPDATE [audit].[FileLoad]
        SET
            [Status] = @Status,
            [RowsParsed] = @RowsParsed,
            [RowsStaged] = @RowsStaged,
            [RowsRejected] = @RowsRejected,
            [DurationSeconds] = @DurationSeconds,
            [ErrorMessage] = @ErrorMessage,
            [CompletedAtUtc] = SYSUTCDATETIME()
        WHERE [FileLoadId] = @FileLoadId;

        EXEC [audit].[usp_CompletePipelineRun]
            @PipelineRunId = @PipelineRunId,
            @Status = @Status,
            @RowsRead = @RowsParsed,
            @RowsWritten = @RowsStaged,
            @RowsRejected = @RowsRejected,
            @ErrorMessage = @ErrorMessage,
            @CommitCheckpoint = 0;

        IF @InitialTransactionCount = 0
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @InitialTransactionCount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @InitialTransactionCount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION [CompleteFileLoadAttempt];

        THROW;
    END CATCH;
END;
