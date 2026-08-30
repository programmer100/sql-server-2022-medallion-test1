CREATE TABLE [audit].[LineageEvent]
(
    [LineageEventId] BIGINT IDENTITY(1, 1) NOT NULL,
    [PipelineRunId] BIGINT NOT NULL,
    [SourceLayer] VARCHAR(10) NOT NULL,
    [SourceObject] NVARCHAR(261) NOT NULL,
    [TargetLayer] VARCHAR(10) NOT NULL,
    [TargetObject] NVARCHAR(261) NOT NULL,
    [TransformationName] NVARCHAR(128) NOT NULL,
    [TransformationVersion] NVARCHAR(64) NOT NULL,
    [RowsAffected] BIGINT NULL,
    [Details] NVARCHAR(4000) NULL,
    [RecordedAtUtc] DATETIME2(7) NOT NULL
        CONSTRAINT [DF_audit_LineageEvent_RecordedAtUtc] DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT [PK_audit_LineageEvent]
        PRIMARY KEY CLUSTERED ([LineageEventId]),
    CONSTRAINT [FK_audit_LineageEvent_PipelineRun]
        FOREIGN KEY ([PipelineRunId])
        REFERENCES [audit].[PipelineRun] ([PipelineRunId]),
    CONSTRAINT [CK_audit_LineageEvent_SourceLayer]
        CHECK ([SourceLayer] IN ('Source', 'Bronze', 'Silver', 'Gold')),
    CONSTRAINT [CK_audit_LineageEvent_TargetLayer]
        CHECK ([TargetLayer] IN ('Bronze', 'Silver', 'Gold')),
    CONSTRAINT [CK_audit_LineageEvent_LayerFlow]
        CHECK
        (
            ([SourceLayer] = 'Source' AND [TargetLayer] = 'Bronze')
            OR ([SourceLayer] = 'Bronze' AND [TargetLayer] IN ('Bronze', 'Silver'))
            OR ([SourceLayer] = 'Silver' AND [TargetLayer] IN ('Silver', 'Gold'))
            OR ([SourceLayer] = 'Gold' AND [TargetLayer] = 'Gold')
        ),
    CONSTRAINT [CK_audit_LineageEvent_RowsAffected]
        CHECK ([RowsAffected] IS NULL OR [RowsAffected] >= 0)
);

GO

CREATE NONCLUSTERED INDEX [IX_audit_LineageEvent_PipelineRunId]
    ON [audit].[LineageEvent] ([PipelineRunId]);
