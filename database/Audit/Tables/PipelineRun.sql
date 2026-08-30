CREATE TABLE [audit].[PipelineRun]
(
    [PipelineRunId] BIGINT IDENTITY(1, 1) NOT NULL,
    [ReplayOfPipelineRunId] BIGINT NULL,
    [PipelineName] NVARCHAR(128) NOT NULL,
    [PipelineVersion] NVARCHAR(64) NOT NULL
        CONSTRAINT [DF_audit_PipelineRun_PipelineVersion] DEFAULT (N'1'),
    [SourceSystem] NVARCHAR(128) NULL,
    [SourceObject] NVARCHAR(261) NULL,
    [SourcePartition] NVARCHAR(256) NOT NULL
        CONSTRAINT [DF_audit_PipelineRun_SourcePartition] DEFAULT (N''),
    [LoadMode] VARCHAR(20) NOT NULL
        CONSTRAINT [DF_audit_PipelineRun_LoadMode] DEFAULT ('Full'),
    [StartedAtUtc] DATETIME2(7) NOT NULL
        CONSTRAINT [DF_audit_PipelineRun_StartedAtUtc] DEFAULT (SYSUTCDATETIME()),
    [CompletedAtUtc] DATETIME2(7) NULL,
    [Status] VARCHAR(20) NOT NULL
        CONSTRAINT [DF_audit_PipelineRun_Status] DEFAULT ('Started'),
    [WatermarkStart] NVARCHAR(4000) NULL,
    [WatermarkEnd] NVARCHAR(4000) NULL,
    -- Retained for non-destructive compatibility. New pipelines use WatermarkStart/WatermarkEnd.
    [SourceWatermark] NVARCHAR(4000) NULL,
    [RowsRead] BIGINT NULL,
    [RowsWritten] BIGINT NULL,
    [RowsRejected] BIGINT NULL,
    [ErrorMessage] NVARCHAR(MAX) NULL,
    CONSTRAINT [PK_audit_PipelineRun]
        PRIMARY KEY CLUSTERED ([PipelineRunId]),
    CONSTRAINT [FK_audit_PipelineRun_ReplayOfPipelineRun]
        FOREIGN KEY ([ReplayOfPipelineRunId])
        REFERENCES [audit].[PipelineRun] ([PipelineRunId]),
    CONSTRAINT [CK_audit_PipelineRun_Status]
        CHECK ([Status] IN ('Started', 'Succeeded', 'Failed', 'Cancelled')),
    CONSTRAINT [CK_audit_PipelineRun_LoadMode]
        CHECK ([LoadMode] IN ('Full', 'Watermark', 'ChangeTracking', 'CDC', 'Replay')),
    CONSTRAINT [CK_audit_PipelineRun_Replay]
        CHECK
        (
            ([LoadMode] = 'Replay' AND [ReplayOfPipelineRunId] IS NOT NULL)
            OR ([LoadMode] <> 'Replay' AND [ReplayOfPipelineRunId] IS NULL)
        ),
    CONSTRAINT [CK_audit_PipelineRun_CompletedAtUtc]
        CHECK ([CompletedAtUtc] IS NULL OR [CompletedAtUtc] >= [StartedAtUtc]),
    CONSTRAINT [CK_audit_PipelineRun_StatusCompletion]
        CHECK
        (
            ([Status] = 'Started' AND [CompletedAtUtc] IS NULL)
            OR ([Status] IN ('Succeeded', 'Failed', 'Cancelled') AND [CompletedAtUtc] IS NOT NULL)
        ),
    CONSTRAINT [CK_audit_PipelineRun_RowsRead]
        CHECK ([RowsRead] IS NULL OR [RowsRead] >= 0),
    CONSTRAINT [CK_audit_PipelineRun_RowsWritten]
        CHECK ([RowsWritten] IS NULL OR [RowsWritten] >= 0),
    CONSTRAINT [CK_audit_PipelineRun_RowsRejected]
        CHECK ([RowsRejected] IS NULL OR [RowsRejected] >= 0)
);

GO

CREATE NONCLUSTERED INDEX [IX_audit_PipelineRun_ReplayOfPipelineRunId]
    ON [audit].[PipelineRun] ([ReplayOfPipelineRunId])
    WHERE [ReplayOfPipelineRunId] IS NOT NULL;
