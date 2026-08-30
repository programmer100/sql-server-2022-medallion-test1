SET NOCOUNT ON;

DECLARE @MissingObjects NVARCHAR(4000);

WITH [RequiredObjects] AS
(
    SELECT [ObjectType], [SchemaName], [ObjectName]
    FROM
    (
        VALUES
            ('U', N'audit', N'PipelineRun'),
            ('U', N'audit', N'PipelineCheckpoint'),
            ('U', N'audit', N'DataQualityResult'),
            ('U', N'audit', N'LineageEvent'),
            ('P', N'audit', N'usp_StartPipelineRun'),
            ('P', N'audit', N'usp_CompletePipelineRun'),
            ('P', N'audit', N'usp_RecordDataQualityResult'),
            ('P', N'audit', N'usp_RecordLineageEvent')
    ) AS [Objects] ([ObjectType], [SchemaName], [ObjectName])
)
SELECT @MissingObjects = STRING_AGG(
    CONCAT([required].[SchemaName], N'.', [required].[ObjectName]),
    N', '
)
FROM [RequiredObjects] AS [required]
WHERE NOT EXISTS
(
    SELECT 1
    FROM sys.objects AS [actual]
    INNER JOIN sys.schemas AS [schemas]
        ON [schemas].[schema_id] = [actual].[schema_id]
    WHERE [actual].[type] = [required].[ObjectType]
      AND [schemas].[name] = [required].[SchemaName]
      AND [actual].[name] = [required].[ObjectName]
);

IF @MissingObjects IS NOT NULL
BEGIN
    DECLARE @MissingObjectMessage NVARCHAR(2048) =
        CONCAT(N'Missing control-plane objects: ', @MissingObjects);
    THROW 51010, @MissingObjectMessage, 1;
END;

DECLARE @MissingRoles NVARCHAR(4000);

SELECT @MissingRoles = STRING_AGG([required].[RoleName], N', ')
FROM
(
    VALUES
        (N'medallion_bronze_loader'),
        (N'medallion_silver_loader'),
        (N'medallion_gold_loader'),
        (N'medallion_gold_reader')
) AS [required] ([RoleName])
WHERE NOT EXISTS
(
    SELECT 1
    FROM sys.database_principals AS [principal]
    WHERE [principal].[type] = 'R'
      AND [principal].[name] = [required].[RoleName]
);

IF @MissingRoles IS NOT NULL
BEGIN
    DECLARE @MissingRoleMessage NVARCHAR(2048) =
        CONCAT(N'Missing Medallion database roles: ', @MissingRoles);
    THROW 51011, @MissingRoleMessage, 1;
END;

PRINT N'Required control-plane objects and database roles exist.';
