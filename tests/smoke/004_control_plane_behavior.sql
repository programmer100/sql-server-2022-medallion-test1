SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @FirstRunId BIGINT;
    DECLARE @SecondRunId BIGINT;
    DECLARE @FailedRunId BIGINT;
    DECLARE @ReplayRunId BIGINT;

    EXEC [audit].[usp_StartPipelineRun]
        @PipelineName = N'Smoke.SourceToBronze',
        @PipelineVersion = N'test-1',
        @SourceSystem = N'SmokeSource',
        @SourceObject = N'dbo.SmokeObject',
        @SourcePartition = N'default',
        @LoadMode = 'Watermark',
        @WatermarkStart = N'0',
        @WatermarkEnd = N'100',
        @PipelineRunId = @FirstRunId OUTPUT;

    EXEC [audit].[usp_RecordDataQualityResult]
        @PipelineRunId = @FirstRunId,
        @LayerName = 'Bronze',
        @ObjectName = N'bronze.SmokeObject',
        @RuleName = N'SourceRowsRetained',
        @RuleVersion = N'1',
        @Severity = 'Error',
        @Passed = 1,
        @FailedRowCount = 0,
        @Disposition = 'Observed',
        @ThresholdDescription = N'No source rows may be discarded.';

    EXEC [audit].[usp_RecordLineageEvent]
        @PipelineRunId = @FirstRunId,
        @SourceLayer = 'Source',
        @SourceObject = N'SmokeSource.dbo.SmokeObject',
        @TargetLayer = 'Bronze',
        @TargetObject = N'bronze.SmokeObject',
        @TransformationName = N'Smoke.SourceToBronze',
        @TransformationVersion = N'test-1',
        @RowsAffected = 10;

    EXEC [audit].[usp_CompletePipelineRun]
        @PipelineRunId = @FirstRunId,
        @Status = 'Succeeded',
        @RowsRead = 10,
        @RowsWritten = 10,
        @RowsRejected = 0,
        @CommitCheckpoint = 1,
        @WatermarkType = N'bigint';

    EXEC [audit].[usp_StartPipelineRun]
        @PipelineName = N'Smoke.SourceToBronze',
        @PipelineVersion = N'test-1',
        @SourceSystem = N'SmokeSource',
        @SourceObject = N'dbo.SmokeObject',
        @SourcePartition = N'default',
        @LoadMode = 'Watermark',
        @WatermarkStart = N'100',
        @WatermarkEnd = N'200',
        @PipelineRunId = @SecondRunId OUTPUT;

    EXEC [audit].[usp_CompletePipelineRun]
        @PipelineRunId = @SecondRunId,
        @Status = 'Succeeded',
        @RowsRead = 5,
        @RowsWritten = 5,
        @RowsRejected = 0,
        @CommitCheckpoint = 1,
        @WatermarkType = N'bigint';

    EXEC [audit].[usp_StartPipelineRun]
        @PipelineName = N'Smoke.SourceToBronze',
        @PipelineVersion = N'test-1',
        @SourceSystem = N'SmokeSource',
        @SourceObject = N'dbo.SmokeObject',
        @SourcePartition = N'default',
        @LoadMode = 'Watermark',
        @WatermarkStart = N'200',
        @WatermarkEnd = N'300',
        @PipelineRunId = @FailedRunId OUTPUT;

    EXEC [audit].[usp_CompletePipelineRun]
        @PipelineRunId = @FailedRunId,
        @Status = 'Failed',
        @RowsRead = 3,
        @RowsWritten = 0,
        @RowsRejected = 3,
        @ErrorMessage = N'Expected smoke-test failure.',
        @CommitCheckpoint = 0;

    EXEC [audit].[usp_StartPipelineRun]
        @PipelineName = N'Smoke.SourceToBronze',
        @PipelineVersion = N'test-2',
        @LoadMode = 'Replay',
        @ReplayOfPipelineRunId = @FirstRunId,
        @PipelineRunId = @ReplayRunId OUTPUT;

    EXEC [audit].[usp_CompletePipelineRun]
        @PipelineRunId = @ReplayRunId,
        @Status = 'Cancelled',
        @ErrorMessage = N'Expected smoke-test cancellation.',
        @CommitCheckpoint = 0;

    IF NOT EXISTS
    (
        SELECT 1
        FROM [audit].[PipelineRun]
        WHERE [PipelineRunId] = @FirstRunId
          AND [Status] = 'Succeeded'
          AND [CompletedAtUtc] IS NOT NULL
          AND [RowsRead] = 10
          AND [RowsWritten] = 10
          AND [RowsRejected] = 0
    )
        THROW 51030, N'Pipeline completion did not persist the expected outcome.', 1;

    IF
    (
        SELECT COUNT_BIG(*)
        FROM [audit].[PipelineCheckpoint]
        WHERE [PipelineName] = N'Smoke.SourceToBronze'
          AND [SourceSystem] = N'SmokeSource'
          AND [SourceObject] = N'dbo.SmokeObject'
          AND [SourcePartition] = N'default'
    ) <> 1
        THROW 51031, N'Checkpoint update was not idempotent by pipeline/source/partition.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM [audit].[PipelineCheckpoint]
        WHERE [PipelineName] = N'Smoke.SourceToBronze'
          AND [SourceSystem] = N'SmokeSource'
          AND [SourceObject] = N'dbo.SmokeObject'
          AND [SourcePartition] = N'default'
          AND [WatermarkValue] = N'200'
          AND [WatermarkType] = N'bigint'
          AND [LastSuccessfulPipelineRunId] = @SecondRunId
    )
        THROW 51032, N'Checkpoint did not advance to the last successful upper boundary.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM [audit].[PipelineCheckpoint]
        WHERE [PipelineName] = N'Smoke.SourceToBronze'
          AND [WatermarkValue] = N'300'
    )
        THROW 51035, N'A failed run advanced the committed checkpoint.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM [audit].[PipelineRun]
        WHERE [PipelineRunId] = @ReplayRunId
          AND [ReplayOfPipelineRunId] = @FirstRunId
          AND [LoadMode] = 'Replay'
          AND [WatermarkStart] = N'0'
          AND [WatermarkEnd] = N'100'
          AND [Status] = 'Cancelled'
    )
        THROW 51036, N'Replay ancestry or inherited extraction boundaries were not recorded.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM [audit].[DataQualityResult]
        WHERE [PipelineRunId] = @FirstRunId
          AND [RuleName] = N'SourceRowsRetained'
          AND [Passed] = 1
    )
        THROW 51033, N'Data-quality result was not recorded.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM [audit].[LineageEvent]
        WHERE [PipelineRunId] = @FirstRunId
          AND [SourceLayer] = 'Source'
          AND [TargetLayer] = 'Bronze'
    )
        THROW 51034, N'Lineage event was not recorded.', 1;

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;

PRINT N'Audit control-plane behavior is valid.';
