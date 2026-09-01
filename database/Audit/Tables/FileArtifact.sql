CREATE TABLE [audit].[FileArtifact]
(
    [FileArtifactId] BIGINT IDENTITY(1, 1) NOT NULL,
    [FeedName] NVARCHAR(128) NOT NULL,
    [RemoteDirectory] NVARCHAR(1024) NOT NULL,
    [RemoteFileName] NVARCHAR(260) NOT NULL,
    [RemoteSizeBytes] BIGINT NOT NULL,
    [RemoteModifiedAtUtc] DATETIME2(7) NULL,
    [ArchiveRelativePath] NVARCHAR(1024) NOT NULL,
    [ArchiveSha256] BINARY(32) NOT NULL,
    [ArchiveSizeBytes] BIGINT NOT NULL,
    [AcquiredAtUtc] DATETIME2(7) NOT NULL
        CONSTRAINT [DF_audit_FileArtifact_AcquiredAtUtc] DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT [PK_audit_FileArtifact]
        PRIMARY KEY CLUSTERED ([FileArtifactId]),
    CONSTRAINT [UQ_audit_FileArtifact_FeedName_ArchiveSha256]
        UNIQUE NONCLUSTERED ([FeedName], [ArchiveSha256]),
    CONSTRAINT [CK_audit_FileArtifact_RemoteSizeBytes]
        CHECK ([RemoteSizeBytes] >= 0),
    CONSTRAINT [CK_audit_FileArtifact_ArchiveSizeBytes]
        CHECK ([ArchiveSizeBytes] >= 0),
    CONSTRAINT [CK_audit_FileArtifact_ArchiveSizeMatchesRemote]
        CHECK ([ArchiveSizeBytes] = [RemoteSizeBytes])
);
