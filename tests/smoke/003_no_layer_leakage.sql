SET NOCOUNT ON;

DECLARE @InvalidDependencies NVARCHAR(4000);

SELECT @InvalidDependencies = STRING_AGG(
    CONCAT(
        QUOTENAME([referencing_schema].[name]),
        N'.',
        QUOTENAME([referencing_object].[name]),
        N' -> ',
        QUOTENAME([referenced_schema].[name]),
        N'.',
        QUOTENAME([referenced_object].[name])
    ),
    N'; '
)
FROM sys.sql_expression_dependencies AS [dependency]
INNER JOIN sys.objects AS [referencing_object]
    ON [referencing_object].[object_id] = [dependency].[referencing_id]
INNER JOIN sys.schemas AS [referencing_schema]
    ON [referencing_schema].[schema_id] = [referencing_object].[schema_id]
INNER JOIN sys.objects AS [referenced_object]
    ON [referenced_object].[object_id] = [dependency].[referenced_id]
INNER JOIN sys.schemas AS [referenced_schema]
    ON [referenced_schema].[schema_id] = [referenced_object].[schema_id]
WHERE
    ([referencing_schema].[name] = N'bronze' AND [referenced_schema].[name] IN (N'silver', N'gold'))
    OR ([referencing_schema].[name] = N'silver' AND [referenced_schema].[name] = N'gold')
    OR ([referencing_schema].[name] = N'gold' AND [referenced_schema].[name] = N'bronze');

IF @InvalidDependencies IS NOT NULL
BEGIN
    DECLARE @DependencyMessage NVARCHAR(2048) =
        CONCAT(N'Prohibited Medallion layer dependencies: ', @InvalidDependencies);
    THROW 51020, @DependencyMessage, 1;
END;

PRINT N'No discoverable Medallion layer leakage exists.';
