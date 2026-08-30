CREATE TABLE [audit].[DataQualityResult]
(
    [DataQualityResultId] BIGINT IDENTITY(1, 1) NOT NULL,
    [PipelineRunId] BIGINT NOT NULL,
    [LayerName] VARCHAR(10) NOT NULL,
    [ObjectName] NVARCHAR(261) NOT NULL,
    [RuleName] NVARCHAR(128) NOT NULL,
    [RuleVersion] NVARCHAR(32) NOT NULL
        CONSTRAINT [DF_audit_DataQualityResult_RuleVersion] DEFAULT (N'1'),
    [Severity] VARCHAR(10) NOT NULL
        CONSTRAINT [DF_audit_DataQualityResult_Severity] DEFAULT ('Error'),
    [Passed] BIT NOT NULL,
    [FailedRowCount] BIGINT NULL,
    [Disposition] VARCHAR(20) NOT NULL
        CONSTRAINT [DF_audit_DataQualityResult_Disposition] DEFAULT ('Observed'),
    [ThresholdDescription] NVARCHAR(4000) NULL,
    [Details] NVARCHAR(4000) NULL,
    [EvaluatedAtUtc] DATETIME2(7) NOT NULL
        CONSTRAINT [DF_audit_DataQualityResult_EvaluatedAtUtc] DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT [PK_audit_DataQualityResult]
        PRIMARY KEY CLUSTERED ([DataQualityResultId]),
    CONSTRAINT [FK_audit_DataQualityResult_PipelineRun]
        FOREIGN KEY ([PipelineRunId])
        REFERENCES [audit].[PipelineRun] ([PipelineRunId]),
    CONSTRAINT [UQ_audit_DataQualityResult_RunObjectRule]
        UNIQUE
        (
            [PipelineRunId],
            [LayerName],
            [ObjectName],
            [RuleName],
            [RuleVersion]
        ),
    CONSTRAINT [CK_audit_DataQualityResult_LayerName]
        CHECK ([LayerName] IN ('Bronze', 'Silver', 'Gold')),
    CONSTRAINT [CK_audit_DataQualityResult_Severity]
        CHECK ([Severity] IN ('Info', 'Warning', 'Error')),
    CONSTRAINT [CK_audit_DataQualityResult_Disposition]
        CHECK ([Disposition] IN ('Observed', 'Quarantined', 'LoadFailed')),
    CONSTRAINT [CK_audit_DataQualityResult_FailedRowCount]
        CHECK
        (
            ([Passed] = 1 AND ([FailedRowCount] IS NULL OR [FailedRowCount] = 0))
            OR ([Passed] = 0 AND ([FailedRowCount] IS NULL OR [FailedRowCount] > 0))
        ),
    CONSTRAINT [CK_audit_DataQualityResult_PassedDisposition]
        CHECK ([Passed] = 0 OR [Disposition] = 'Observed')
);
