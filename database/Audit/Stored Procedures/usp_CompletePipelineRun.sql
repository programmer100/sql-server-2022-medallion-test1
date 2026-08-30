CREATE PROCEDURE [audit].[usp_CompletePipelineRun]
    @PipelineRunId BIGINT,
    @Status VARCHAR(20),
    @RowsRead BIGINT = NULL,
    @RowsWritten BIGINT = NULL,
    @RowsRejected BIGINT = NULL,
    @ErrorMessage NVARCHAR(MAX) = NULL,
    @CommitCheckpoint BIT = 0,
    @WatermarkType NVARCHAR(128) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @Status NOT IN ('Succeeded', 'Failed', 'Cancelled')
        THROW 51020, N'Completion status must be Succeeded, Failed, or Cancelled.', 1;

    IF @RowsRead < 0 OR @RowsWritten < 0 OR @RowsRejected < 0
        THROW 51021, N'Pipeline row counts cannot be negative.', 1;

    IF @CommitCheckpoint = 1
       AND
       (
           @Status <> 'Succeeded'
           OR NULLIF(LTRIM(RTRIM(@WatermarkType)), N'') IS NULL
       )
        THROW 51022, N'A checkpoint requires a successful run and a WatermarkType.', 1;

    DECLARE @InitialTransactionCount INT = @@TRANCOUNT;
    DECLARE @PipelineName NVARCHAR(128);
    DECLARE @SourceSystem NVARCHAR(128);
    DECLARE @SourceObject NVARCHAR(261);
    DECLARE @SourcePartition NVARCHAR(256);
    DECLARE @WatermarkEnd NVARCHAR(4000);

    BEGIN TRY
        IF @InitialTransactionCount = 0
            BEGIN TRANSACTION;
        ELSE
            SAVE TRANSACTION [CompletePipelineRun];

        SELECT
            @PipelineName = [PipelineName],
            @SourceSystem = [SourceSystem],
            @SourceObject = [SourceObject],
            @SourcePartition = [SourcePartition],
            @WatermarkEnd = [WatermarkEnd]
        FROM [audit].[PipelineRun] WITH (UPDLOCK, HOLDLOCK)
        WHERE [PipelineRunId] = @PipelineRunId
          AND [Status] = 'Started';

        IF @PipelineName IS NULL
            THROW 51023, N'The pipeline run does not exist or is already complete.', 1;

        IF @CommitCheckpoint = 1
           AND
           (
               @SourceSystem IS NULL
               OR @SourceObject IS NULL
               OR @WatermarkEnd IS NULL
           )
            THROW 51024, N'The run does not contain the source identity and upper watermark required for a checkpoint.', 1;

        IF @CommitCheckpoint = 1
        BEGIN
            UPDATE [audit].[PipelineCheckpoint] WITH (UPDLOCK, HOLDLOCK)
            SET
                [WatermarkValue] = @WatermarkEnd,
                [WatermarkType] = @WatermarkType,
                [LastSuccessfulPipelineRunId] = @PipelineRunId,
                [UpdatedAtUtc] = SYSUTCDATETIME()
            WHERE [PipelineName] = @PipelineName
              AND [SourceSystem] = @SourceSystem
              AND [SourceObject] = @SourceObject
              AND [SourcePartition] = @SourcePartition;

            IF @@ROWCOUNT = 0
            BEGIN
                INSERT INTO [audit].[PipelineCheckpoint]
                (
                    [PipelineName],
                    [SourceSystem],
                    [SourceObject],
                    [SourcePartition],
                    [WatermarkValue],
                    [WatermarkType],
                    [LastSuccessfulPipelineRunId]
                )
                VALUES
                (
                    @PipelineName,
                    @SourceSystem,
                    @SourceObject,
                    @SourcePartition,
                    @WatermarkEnd,
                    @WatermarkType,
                    @PipelineRunId
                );
            END;
        END;

        UPDATE [audit].[PipelineRun]
        SET
            [CompletedAtUtc] = SYSUTCDATETIME(),
            [Status] = @Status,
            [RowsRead] = @RowsRead,
            [RowsWritten] = @RowsWritten,
            [RowsRejected] = @RowsRejected,
            [ErrorMessage] = @ErrorMessage
        WHERE [PipelineRunId] = @PipelineRunId;

        IF @InitialTransactionCount = 0
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @InitialTransactionCount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @InitialTransactionCount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION [CompletePipelineRun];

        THROW;
    END CATCH;
END;
