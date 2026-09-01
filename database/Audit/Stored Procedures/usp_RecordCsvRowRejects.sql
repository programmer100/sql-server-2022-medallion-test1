CREATE PROCEDURE [audit].[usp_RecordCsvRowRejects]
    @FileLoadAttemptId BIGINT,
    @RejectsJson NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISJSON(@RejectsJson) <> 1
        THROW 51120, N'RejectsJson must be valid JSON.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM [audit].[FileLoadAttempt]
        WHERE [FileLoadAttemptId] = @FileLoadAttemptId
          AND [Status] = 'Started'
    )
        THROW 51121, N'Rejects can be recorded only for an active file-load attempt.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM OPENJSON(@RejectsJson)
        WITH
        (
            [SourceRecordNumber] BIGINT '$.sourceRecordNumber',
            [Reason] NVARCHAR(500) '$.reason'
        ) AS [j]
        WHERE [j].[SourceRecordNumber] IS NULL
           OR [j].[SourceRecordNumber] <= 0
           OR NULLIF(LTRIM(RTRIM([j].[Reason])), N'') IS NULL
    )
        THROW 51122, N'Every rejected record requires a positive source record number and a reason.', 1;

    INSERT INTO [audit].[CsvRowReject]
    (
        [FileLoadAttemptId],
        [SourceRecordNumber],
        [Reason],
        [RawFragment]
    )
    SELECT
        @FileLoadAttemptId,
        [j].[SourceRecordNumber],
        [j].[Reason],
        [j].[RawFragment]
    FROM OPENJSON(@RejectsJson)
    WITH
    (
        [SourceRecordNumber] BIGINT '$.sourceRecordNumber',
        [Reason] NVARCHAR(500) '$.reason',
        [RawFragment] NVARCHAR(MAX) '$.rawFragment'
    ) AS [j];
END;
