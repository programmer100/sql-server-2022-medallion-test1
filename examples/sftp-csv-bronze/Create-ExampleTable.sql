IF OBJECT_ID(N'[bronze].[SampleSalesTransactionRaw]', N'U') IS NULL
BEGIN
    CREATE TABLE [bronze].[SampleSalesTransactionRaw]
    (
        [TxnId] NVARCHAR(4000) NULL,
        [TxnDate] NVARCHAR(4000) NULL,
        [CustomerCode] NVARCHAR(4000) NULL,
        [ProductSku] NVARCHAR(4000) NULL,
        [Quantity] NVARCHAR(4000) NULL,
        [UnitPriceCad] NVARCHAR(4000) NULL,
        [StoreCode] NVARCHAR(4000) NULL,
        [PromoCode] NVARCHAR(4000) NULL,
        [Notes] NVARCHAR(4000) NULL,
        [FileLoadId] BIGINT NOT NULL,
        [FileLoadAttemptId] BIGINT NOT NULL,
        [SourceRecordNumber] BIGINT NOT NULL,
        [SourceFileName] NVARCHAR(260) NOT NULL,
        [IngestedAtUtc] DATETIME2(7) NOT NULL
    );
END;
