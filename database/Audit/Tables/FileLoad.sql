CREATE TABLE [audit].[FileLoad]
(
    [FileLoadId] BIGINT IDENTITY(1, 1) NOT NULL,
    [FileArtifactId] BIGINT NOT NULL,
    [FeedName] NVARCHAR(128) NOT NULL,
    [CsvFileName] NVARCHAR(260) NOT NULL,
    [CsvSha256] BINARY(32) NOT NULL,
    [CsvSizeBytes] BIGINT NOT NULL,
    [MappingName] NVARCHAR(128) NOT NULL,
    [MappingVersion] NVARCHAR(64) NOT NULL,
    [MappingSha256] BINARY(32) NOT NULL,
    [TargetSchema] NVARCHAR(128) NOT NULL,
    [TargetTable] NVARCHAR(128) NOT NULL,
    [Status] VARCHAR(20) NOT NULL
        CONSTRAINT [DF_audit_FileLoad_Status] DEFAULT ('Started'),
    [RowsParsed] BIGINT NULL,
    [RowsStaged] BIGINT NULL,
    [RowsRejected] BIGINT NULL,
    [DurationSeconds] DECIMAL(18, 3) NULL,
    [ErrorMessage] NVARCHAR(MAX) NULL,
    [FirstSeenAtUtc] DATETIME2(7) NOT NULL
        CONSTRAINT [DF_audit_FileLoad_FirstSeenAtUtc] DEFAULT (SYSUTCDATETIME()),
    [CompletedAtUtc] DATETIME2(7) NULL,
    CONSTRAINT [PK_audit_FileLoad]
        PRIMARY KEY CLUSTERED ([FileLoadId]),
    CONSTRAINT [FK_audit_FileLoad_FileArtifact]
        FOREIGN KEY ([FileArtifactId])
        REFERENCES [audit].[FileArtifact] ([FileArtifactId]),
    CONSTRAINT [UQ_audit_FileLoad_ContentMappingTarget]
        UNIQUE NONCLUSTERED
        (
            [FeedName],
            [CsvSha256],
            [TargetSchema],
            [TargetTable],
            [MappingSha256]
        ),
    CONSTRAINT [CK_audit_FileLoad_TargetSchema]
        CHECK ([TargetSchema] = N'bronze'),
    CONSTRAINT [CK_audit_FileLoad_Status]
        CHECK ([Status] IN ('Started', 'Succeeded', 'Failed')),
    CONSTRAINT [CK_audit_FileLoad_CsvSizeBytes]
        CHECK ([CsvSizeBytes] >= 0),
    CONSTRAINT [CK_audit_FileLoad_RowsParsed]
        CHECK ([RowsParsed] IS NULL OR [RowsParsed] >= 0),
    CONSTRAINT [CK_audit_FileLoad_RowsStaged]
        CHECK ([RowsStaged] IS NULL OR [RowsStaged] >= 0),
    CONSTRAINT [CK_audit_FileLoad_RowsRejected]
        CHECK ([RowsRejected] IS NULL OR [RowsRejected] >= 0),
    CONSTRAINT [CK_audit_FileLoad_DurationSeconds]
        CHECK ([DurationSeconds] IS NULL OR [DurationSeconds] >= 0),
    CONSTRAINT [CK_audit_FileLoad_StatusCompletion]
        CHECK
        (
            ([Status] = 'Started' AND [CompletedAtUtc] IS NULL)
            OR ([Status] IN ('Succeeded', 'Failed') AND [CompletedAtUtc] IS NOT NULL)
        ),
    CONSTRAINT [CK_audit_FileLoad_RowReconciliation]
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
