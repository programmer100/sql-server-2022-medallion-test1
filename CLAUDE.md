# SQL Server 2022 Medallion project

Use `/sqlserver-medallion` for Bronze, Silver, Gold, ingestion, data-quality, lineage, dimensional-modeling, and T-SQL implementation work in this repository.

Keep SQL Server 2022 as the implementation platform. Medallion is a logical refinement model here; do not infer Databricks, Spark, Delta Lake, Microsoft Fabric, or dbt. Follow the layer contracts and engineering rules in `AGENTS.md`, the usage guide in `SQLSERVER_MEDALLION.md`, and the design in `docs/architecture/medallion.md`.
