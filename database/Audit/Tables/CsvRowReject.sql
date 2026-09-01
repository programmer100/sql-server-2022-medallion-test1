CREATE TABLE [audit].[CsvRowReject]
(
    [CsvRowRejectId] BIGINT IDENTITY(1, 1) NOT NULL,
    [FileLoadAttemptId] BIGINT NOT NULL,
    [SourceRecordNumber] BIGINT NOT NULL,
    [Reason] NVARCHAR(500) NOT NULL,
    [RawFragment] NVARCHAR(MAX) NULL,
    [RejectedAtUtc] DATETIME2(7) NOT NULL
        CONSTRAINT [DF_audit_CsvRowReject_RejectedAtUtc] DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT [PK_audit_CsvRowReject]
        PRIMARY KEY CLUSTERED ([CsvRowRejectId]),
    CONSTRAINT [FK_audit_CsvRowReject_FileLoadAttempt]
        FOREIGN KEY ([FileLoadAttemptId])
        REFERENCES [audit].[FileLoadAttempt] ([FileLoadAttemptId]),
    CONSTRAINT [CK_audit_CsvRowReject_SourceRecordNumber]
        CHECK ([SourceRecordNumber] > 0)
);

GO

CREATE NONCLUSTERED INDEX [IX_audit_CsvRowReject_FileLoadAttemptId]
    ON [audit].[CsvRowReject] ([FileLoadAttemptId], [SourceRecordNumber]);
