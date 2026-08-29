CREATE TABLE [audit].[DataQualityResult]
(
    [DataQualityResultId] BIGINT IDENTITY(1, 1) NOT NULL,
    [PipelineRunId] BIGINT NOT NULL,
    [LayerName] VARCHAR(10) NOT NULL,
    [ObjectName] NVARCHAR(261) NOT NULL,
    [RuleName] NVARCHAR(128) NOT NULL,
    [Passed] BIT NOT NULL,
    [FailedRowCount] BIGINT NULL,
    [Details] NVARCHAR(4000) NULL,
    [EvaluatedAtUtc] DATETIME2(7) NOT NULL
        CONSTRAINT [DF_audit_DataQualityResult_EvaluatedAtUtc] DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT [PK_audit_DataQualityResult]
        PRIMARY KEY CLUSTERED ([DataQualityResultId]),
    CONSTRAINT [FK_audit_DataQualityResult_PipelineRun]
        FOREIGN KEY ([PipelineRunId])
        REFERENCES [audit].[PipelineRun] ([PipelineRunId]),
    CONSTRAINT [CK_audit_DataQualityResult_LayerName]
        CHECK ([LayerName] IN ('Bronze', 'Silver', 'Gold')),
    CONSTRAINT [CK_audit_DataQualityResult_FailedRowCount]
        CHECK ([FailedRowCount] IS NULL OR [FailedRowCount] >= 0)
);
