CREATE TABLE [audit].[FileLoadAttempt]
(
    [FileLoadAttemptId] BIGINT IDENTITY(1, 1) NOT NULL,
    [FileLoadId] BIGINT NOT NULL,
    [PipelineRunId] BIGINT NOT NULL,
    [AttemptNumber] INT NOT NULL,
    [Status] VARCHAR(20) NOT NULL
        CONSTRAINT [DF_audit_FileLoadAttempt_Status] DEFAULT ('Started'),
    [HostName] NVARCHAR(128) NOT NULL,
    [ProcessId] INT NOT NULL,
    [RowsParsed] BIGINT NULL,
    [RowsStaged] BIGINT NULL,
    [RowsRejected] BIGINT NULL,
    [DurationSeconds] DECIMAL(18, 3) NULL,
    [ErrorMessage] NVARCHAR(MAX) NULL,
    [StartedAtUtc] DATETIME2(7) NOT NULL
        CONSTRAINT [DF_audit_FileLoadAttempt_StartedAtUtc] DEFAULT (SYSUTCDATETIME()),
    [CompletedAtUtc] DATETIME2(7) NULL,
    CONSTRAINT [PK_audit_FileLoadAttempt]
        PRIMARY KEY CLUSTERED ([FileLoadAttemptId]),
    CONSTRAINT [FK_audit_FileLoadAttempt_FileLoad]
        FOREIGN KEY ([FileLoadId])
        REFERENCES [audit].[FileLoad] ([FileLoadId]),
    CONSTRAINT [FK_audit_FileLoadAttempt_PipelineRun]
        FOREIGN KEY ([PipelineRunId])
        REFERENCES [audit].[PipelineRun] ([PipelineRunId]),
    CONSTRAINT [UQ_audit_FileLoadAttempt_FileLoad_AttemptNumber]
        UNIQUE NONCLUSTERED ([FileLoadId], [AttemptNumber]),
    CONSTRAINT [UQ_audit_FileLoadAttempt_PipelineRunId]
        UNIQUE NONCLUSTERED ([PipelineRunId]),
    CONSTRAINT [CK_audit_FileLoadAttempt_AttemptNumber]
        CHECK ([AttemptNumber] > 0),
    CONSTRAINT [CK_audit_FileLoadAttempt_ProcessId]
        CHECK ([ProcessId] > 0),
    CONSTRAINT [CK_audit_FileLoadAttempt_Status]
        CHECK ([Status] IN ('Started', 'Succeeded', 'Failed', 'Abandoned')),
    CONSTRAINT [CK_audit_FileLoadAttempt_RowsParsed]
        CHECK ([RowsParsed] IS NULL OR [RowsParsed] >= 0),
    CONSTRAINT [CK_audit_FileLoadAttempt_RowsStaged]
        CHECK ([RowsStaged] IS NULL OR [RowsStaged] >= 0),
    CONSTRAINT [CK_audit_FileLoadAttempt_RowsRejected]
        CHECK ([RowsRejected] IS NULL OR [RowsRejected] >= 0),
    CONSTRAINT [CK_audit_FileLoadAttempt_DurationSeconds]
        CHECK ([DurationSeconds] IS NULL OR [DurationSeconds] >= 0),
    CONSTRAINT [CK_audit_FileLoadAttempt_StatusCompletion]
        CHECK
        (
            ([Status] = 'Started' AND [CompletedAtUtc] IS NULL)
            OR ([Status] IN ('Succeeded', 'Failed', 'Abandoned') AND [CompletedAtUtc] IS NOT NULL)
        ),
    CONSTRAINT [CK_audit_FileLoadAttempt_RowReconciliation]
        CHECK
        (
            [Status] <> 'Succeeded'
            OR
            (
                [RowsParsed] IS NOT NULL
                AND [RowsStaged] IS NOT NULL
                AND [RowsRejected] IS NOT NULL
                AND [RowsParsed] = [RowsStaged] + [RowsRejected]
            )
        )
);
