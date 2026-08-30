CREATE TABLE [audit].[PipelineCheckpoint]
(
    [PipelineCheckpointId] BIGINT IDENTITY(1, 1) NOT NULL,
    [PipelineName] NVARCHAR(128) NOT NULL,
    [SourceSystem] NVARCHAR(128) NOT NULL,
    [SourceObject] NVARCHAR(261) NOT NULL,
    [SourcePartition] NVARCHAR(256) NOT NULL
        CONSTRAINT [DF_audit_PipelineCheckpoint_SourcePartition] DEFAULT (N''),
    [WatermarkValue] NVARCHAR(4000) NOT NULL,
    [WatermarkType] NVARCHAR(128) NOT NULL,
    [LastSuccessfulPipelineRunId] BIGINT NOT NULL,
    [UpdatedAtUtc] DATETIME2(7) NOT NULL
        CONSTRAINT [DF_audit_PipelineCheckpoint_UpdatedAtUtc] DEFAULT (SYSUTCDATETIME()),
    [ConcurrencyVersion] ROWVERSION NOT NULL,
    CONSTRAINT [PK_audit_PipelineCheckpoint]
        PRIMARY KEY CLUSTERED ([PipelineCheckpointId]),
    CONSTRAINT [FK_audit_PipelineCheckpoint_LastSuccessfulPipelineRun]
        FOREIGN KEY ([LastSuccessfulPipelineRunId])
        REFERENCES [audit].[PipelineRun] ([PipelineRunId]),
    CONSTRAINT [UQ_audit_PipelineCheckpoint_Source]
        UNIQUE
        (
            [PipelineName],
            [SourceSystem],
            [SourceObject],
            [SourcePartition]
        )
);
