CREATE PROCEDURE [audit].[usp_RegisterFileArtifact]
    @FeedName NVARCHAR(128),
    @RemoteDirectory NVARCHAR(1024),
    @RemoteFileName NVARCHAR(260),
    @RemoteSizeBytes BIGINT,
    @RemoteModifiedAtUtc DATETIME2(7) = NULL,
    @ArchiveRelativePath NVARCHAR(1024),
    @ArchiveSha256 BINARY(32),
    @ArchiveSizeBytes BIGINT,
    @AcquiredAtUtc DATETIME2(7),
    @FileArtifactId BIGINT OUTPUT,
    @WasInserted BIT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF NULLIF(LTRIM(RTRIM(@FeedName)), N'') IS NULL
        THROW 51100, N'FeedName is required.', 1;

    IF NULLIF(LTRIM(RTRIM(@RemoteDirectory)), N'') IS NULL
        THROW 51101, N'RemoteDirectory is required.', 1;

    IF NULLIF(LTRIM(RTRIM(@RemoteFileName)), N'') IS NULL
        THROW 51102, N'RemoteFileName is required.', 1;

    IF NULLIF(LTRIM(RTRIM(@ArchiveRelativePath)), N'') IS NULL
        THROW 51103, N'ArchiveRelativePath is required.', 1;

    IF @RemoteSizeBytes < 0 OR @ArchiveSizeBytes < 0
        THROW 51104, N'Artifact sizes cannot be negative.', 1;

    IF @RemoteSizeBytes <> @ArchiveSizeBytes
        THROW 51105, N'The archived byte count does not match the acquired artifact.', 1;

    DECLARE @InitialTransactionCount INT = @@TRANCOUNT;

    BEGIN TRY
        IF @InitialTransactionCount = 0
            BEGIN TRANSACTION;
        ELSE
            SAVE TRANSACTION [RegisterFileArtifact];

        SELECT @FileArtifactId = [FileArtifactId]
        FROM [audit].[FileArtifact] WITH (UPDLOCK, HOLDLOCK)
        WHERE [FeedName] = @FeedName
          AND [ArchiveSha256] = @ArchiveSha256;

        IF @FileArtifactId IS NULL
        BEGIN
            INSERT INTO [audit].[FileArtifact]
            (
                [FeedName],
                [RemoteDirectory],
                [RemoteFileName],
                [RemoteSizeBytes],
                [RemoteModifiedAtUtc],
                [ArchiveRelativePath],
                [ArchiveSha256],
                [ArchiveSizeBytes],
                [AcquiredAtUtc]
            )
            VALUES
            (
                @FeedName,
                @RemoteDirectory,
                @RemoteFileName,
                @RemoteSizeBytes,
                @RemoteModifiedAtUtc,
                @ArchiveRelativePath,
                @ArchiveSha256,
                @ArchiveSizeBytes,
                @AcquiredAtUtc
            );

            SET @FileArtifactId = CONVERT(BIGINT, SCOPE_IDENTITY());
            SET @WasInserted = 1;
        END
        ELSE
            SET @WasInserted = 0;

        IF @InitialTransactionCount = 0
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @InitialTransactionCount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @InitialTransactionCount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION [RegisterFileArtifact];

        THROW;
    END CATCH;
END;
