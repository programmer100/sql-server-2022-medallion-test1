SET NOCOUNT ON;

DECLARE @MissingSchemas NVARCHAR(4000);

SELECT @MissingSchemas = STRING_AGG([required].[SchemaName], N', ')
FROM
(
    VALUES (N'audit'), (N'bronze'), (N'silver'), (N'gold')
) AS [required] ([SchemaName])
WHERE SCHEMA_ID([required].[SchemaName]) IS NULL;

IF @MissingSchemas IS NOT NULL
BEGIN
    DECLARE @ErrorMessage NVARCHAR(2048) =
        CONCAT(N'Missing required schemas: ', @MissingSchemas);

    THROW 51000, @ErrorMessage, 1;
END;

PRINT N'Required Medallion schemas exist.';
