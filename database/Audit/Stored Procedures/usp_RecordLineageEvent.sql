CREATE PROCEDURE [audit].[usp_RecordLineageEvent]
    @PipelineRunId BIGINT,
    @SourceLayer VARCHAR(10),
    @SourceObject NVARCHAR(261),
    @TargetLayer VARCHAR(10),
    @TargetObject NVARCHAR(261),
    @TransformationName NVARCHAR(128),
    @TransformationVersion NVARCHAR(64),
    @RowsAffected BIGINT = NULL,
    @Details NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    INSERT INTO [audit].[LineageEvent]
    (
        [PipelineRunId],
        [SourceLayer],
        [SourceObject],
        [TargetLayer],
        [TargetObject],
        [TransformationName],
        [TransformationVersion],
        [RowsAffected],
        [Details]
    )
    SELECT
        @PipelineRunId,
        @SourceLayer,
        @SourceObject,
        @TargetLayer,
        @TargetObject,
        @TransformationName,
        @TransformationVersion,
        @RowsAffected,
        @Details
    FROM [audit].[PipelineRun]
    WHERE [PipelineRunId] = @PipelineRunId
      AND [Status] = 'Started';

    IF @@ROWCOUNT = 0
        THROW 51040, N'Lineage can be recorded only for an active pipeline run.', 1;
END;
