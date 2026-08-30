CREATE PROCEDURE [audit].[usp_StartPipelineRun]
    @PipelineName NVARCHAR(128),
    @PipelineVersion NVARCHAR(64),
    @SourceSystem NVARCHAR(128) = NULL,
    @SourceObject NVARCHAR(261) = NULL,
    @SourcePartition NVARCHAR(256) = N'',
    @LoadMode VARCHAR(20) = 'Full',
    @WatermarkStart NVARCHAR(4000) = NULL,
    @WatermarkEnd NVARCHAR(4000) = NULL,
    @ReplayOfPipelineRunId BIGINT = NULL,
    @PipelineRunId BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@PipelineName)), N'') IS NULL
        THROW 51010, N'PipelineName is required.', 1;

    IF NULLIF(LTRIM(RTRIM(@PipelineVersion)), N'') IS NULL
        THROW 51011, N'PipelineVersion is required.', 1;

    IF @LoadMode NOT IN ('Full', 'Watermark', 'ChangeTracking', 'CDC', 'Replay')
        THROW 51012, N'LoadMode is invalid.', 1;

    IF @LoadMode = 'Replay'
    BEGIN
        IF @ReplayOfPipelineRunId IS NULL
            THROW 51013, N'ReplayOfPipelineRunId is required for Replay mode.', 1;

        SELECT
            @SourceSystem = COALESCE(@SourceSystem, [SourceSystem]),
            @SourceObject = COALESCE(@SourceObject, [SourceObject]),
            @SourcePartition = CASE
                WHEN @SourcePartition = N'' THEN [SourcePartition]
                ELSE @SourcePartition
            END,
            @WatermarkStart = COALESCE(@WatermarkStart, [WatermarkStart]),
            @WatermarkEnd = COALESCE(@WatermarkEnd, [WatermarkEnd])
        FROM [audit].[PipelineRun]
        WHERE [PipelineRunId] = @ReplayOfPipelineRunId
          AND [PipelineName] = @PipelineName
          AND [Status] IN ('Succeeded', 'Failed', 'Cancelled');

        IF @@ROWCOUNT = 0
            THROW 51014, N'The replay parent is not complete, does not exist, or belongs to another pipeline.', 1;
    END
    ELSE IF @ReplayOfPipelineRunId IS NOT NULL
        THROW 51015, N'ReplayOfPipelineRunId is allowed only for Replay mode.', 1;

    IF @LoadMode IN ('Watermark', 'ChangeTracking', 'CDC')
       AND
       (
           NULLIF(LTRIM(RTRIM(@SourceSystem)), N'') IS NULL
           OR NULLIF(LTRIM(RTRIM(@SourceObject)), N'') IS NULL
           OR @WatermarkEnd IS NULL
       )
        THROW 51016, N'Incremental modes require SourceSystem, SourceObject, and WatermarkEnd.', 1;

    INSERT INTO [audit].[PipelineRun]
    (
        [ReplayOfPipelineRunId],
        [PipelineName],
        [PipelineVersion],
        [SourceSystem],
        [SourceObject],
        [SourcePartition],
        [LoadMode],
        [Status],
        [WatermarkStart],
        [WatermarkEnd]
    )
    VALUES
    (
        @ReplayOfPipelineRunId,
        @PipelineName,
        @PipelineVersion,
        @SourceSystem,
        @SourceObject,
        @SourcePartition,
        @LoadMode,
        'Started',
        @WatermarkStart,
        @WatermarkEnd
    );

    SET @PipelineRunId = CONVERT(BIGINT, SCOPE_IDENTITY());
END;
