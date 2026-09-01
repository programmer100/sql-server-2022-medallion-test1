# Repository agent guidance

This repository is a Microsoft SQL Server 2022 medallion data platform. Use the repo-local `sqlserver-medallion` skill for Bronze, Silver, Gold, ingestion, transformation, data-quality, lineage, or warehouse work. Use `architecting-data` for architecture decisions and `sql-expert` for T-SQL implementation details.

## Platform contract

- Keep Microsoft SQL Server 2022 as the physical target unless the user explicitly changes it.
- Treat Medallion as logical refinement; do not introduce Databricks, Spark, Delta Lake, Microsoft Fabric, or dbt by inference.
- The database project is `database/SqlServerMedallion.sqlproj` and targets the SQL Server 2022 (`Sql160`) schema provider.
- The initial implementation uses the `bronze`, `silver`, `gold`, and `audit` schemas in one database.

## Layer contract

- Bronze is source-faithful, auditable, and replayable. Technical metadata is allowed; business transformations are not.
- Silver is typed, validated, deduplicated, conformed, and traceable to Bronze.
- Gold is business-oriented and consumer-ready. Define dimensional grain and metric semantics explicitly.
- Cross-cutting run, quality, and lineage metadata belongs in `audit`.

## Engineering rules

- Use UTC `datetime2(7)` audit timestamps and explicit constraint names.
- Use explicit column lists, matching parameter types, SARGable predicates, and transactional error handling.
- Make loads deterministic, idempotent, restartable, and observable.
- Never commit credentials or environment-specific connection strings.
- For SFTP file feeds, require an out-of-band-verified SSH host-key fingerprint,
  retrieve `PSCredential` from a secret vault or runtime injection, retain and
  hash the original ZIP, and reject unsafe ZIP paths/expansion.
- For batched `SqlBulkCopy`, preserve separate logical load and physical attempt
  identities and delete only that logical load's partial Bronze rows before a
  complete-file retry.
- Keep Bronze landing widths separate from Silver business widths. Validate the
  mapping against a source-specific heap in the database project; do not create
  or alter landing tables dynamically.
- The local baseline is `localhost` with Windows authentication. Its 8 GB memory cap, SIMPLE recovery, and trusted local certificate are not production defaults.
- Do not make destructive schema or data changes without explaining migration, validation, and rollback implications.
- Build the SQL project and run relevant tests after implementation when the required tooling is available.

See `SQLSERVER_MEDALLION.md` for invocation examples and `docs/architecture/medallion.md` for the repository design.
