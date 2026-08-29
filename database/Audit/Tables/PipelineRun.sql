CREATE TABLE [audit].[PipelineRun]
(
    [PipelineRunId] BIGINT IDENTITY(1, 1) NOT NULL,
    [PipelineName] NVARCHAR(128) NOT NULL,
    [StartedAtUtc] DATETIME2(7) NOT NULL
        CONSTRAINT [DF_audit_PipelineRun_StartedAtUtc] DEFAULT (SYSUTCDATETIME()),
    [CompletedAtUtc] DATETIME2(7) NULL,
    [Status] VARCHAR(20) NOT NULL,
    [SourceWatermark] NVARCHAR(4000) NULL,
    [RowsRead] BIGINT NULL,
    [RowsWritten] BIGINT NULL,
    [RowsRejected] BIGINT NULL,
    [ErrorMessage] NVARCHAR(MAX) NULL,
    CONSTRAINT [PK_audit_PipelineRun]
        PRIMARY KEY CLUSTERED ([PipelineRunId]),
    CONSTRAINT [CK_audit_PipelineRun_Status]
        CHECK ([Status] IN ('Started', 'Succeeded', 'Failed', 'Cancelled')),
    CONSTRAINT [CK_audit_PipelineRun_CompletedAtUtc]
        CHECK ([CompletedAtUtc] IS NULL OR [CompletedAtUtc] >= [StartedAtUtc])
);
