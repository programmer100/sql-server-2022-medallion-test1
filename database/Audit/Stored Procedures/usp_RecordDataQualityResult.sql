CREATE PROCEDURE [audit].[usp_RecordDataQualityResult]
    @PipelineRunId BIGINT,
    @LayerName VARCHAR(10),
    @ObjectName NVARCHAR(261),
    @RuleName NVARCHAR(128),
    @RuleVersion NVARCHAR(32),
    @Severity VARCHAR(10),
    @Passed BIT,
    @FailedRowCount BIGINT = NULL,
    @Disposition VARCHAR(20) = 'Observed',
    @ThresholdDescription NVARCHAR(4000) = NULL,
    @Details NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    INSERT INTO [audit].[DataQualityResult]
    (
        [PipelineRunId],
        [LayerName],
        [ObjectName],
        [RuleName],
        [RuleVersion],
        [Severity],
        [Passed],
        [FailedRowCount],
        [Disposition],
        [ThresholdDescription],
        [Details]
    )
    SELECT
        @PipelineRunId,
        @LayerName,
        @ObjectName,
        @RuleName,
        @RuleVersion,
        @Severity,
        @Passed,
        @FailedRowCount,
        @Disposition,
        @ThresholdDescription,
        @Details
    FROM [audit].[PipelineRun]
    WHERE [PipelineRunId] = @PipelineRunId
      AND [Status] = 'Started';

    IF @@ROWCOUNT = 0
        THROW 51030, N'Data-quality results can be recorded only for an active pipeline run.', 1;
END;
