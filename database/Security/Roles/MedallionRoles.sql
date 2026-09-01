CREATE ROLE [medallion_bronze_loader]
    AUTHORIZATION [dbo];

GO

CREATE ROLE [medallion_silver_loader]
    AUTHORIZATION [dbo];

GO

CREATE ROLE [medallion_gold_loader]
    AUTHORIZATION [dbo];

GO

CREATE ROLE [medallion_gold_reader]
    AUTHORIZATION [dbo];

GO

GRANT EXECUTE ON SCHEMA::[audit] TO [medallion_bronze_loader];

GO

GRANT SELECT ON SCHEMA::[audit] TO [medallion_bronze_loader];

GO

GRANT EXECUTE ON SCHEMA::[bronze] TO [medallion_bronze_loader];

GO

GRANT SELECT, INSERT, DELETE ON SCHEMA::[bronze] TO [medallion_bronze_loader];

GO

GRANT EXECUTE ON SCHEMA::[audit] TO [medallion_silver_loader];

GO

GRANT SELECT ON SCHEMA::[audit] TO [medallion_silver_loader];

GO

GRANT SELECT ON SCHEMA::[bronze] TO [medallion_silver_loader];

GO

GRANT EXECUTE ON SCHEMA::[silver] TO [medallion_silver_loader];

GO

GRANT EXECUTE ON SCHEMA::[audit] TO [medallion_gold_loader];

GO

GRANT SELECT ON SCHEMA::[audit] TO [medallion_gold_loader];

GO

GRANT SELECT ON SCHEMA::[silver] TO [medallion_gold_loader];

GO

GRANT EXECUTE ON SCHEMA::[gold] TO [medallion_gold_loader];

GO

GRANT SELECT ON SCHEMA::[gold] TO [medallion_gold_reader];
