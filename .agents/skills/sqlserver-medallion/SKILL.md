---
name: sqlserver-medallion
description: Design, assess, and implement Bronze, Silver, and Gold data layers on Microsoft SQL Server 2022. Use for medallion layer contracts, T-SQL database projects, ingestion and refinement pipelines, dimensional models, data quality, lineage, replay, incremental loads, or architecture reviews. Keep SQL Server as the physical platform; do not infer Databricks, Spark, Delta Lake, Fabric, or dbt unless the user or repository requires them.
---

# SQL Server Medallion

Apply medallion as a logical data-refinement architecture implemented with SQL Server 2022.

## Route the Work

This repository includes two complementary skills beside this one:

- For layer boundaries, modeling, governance, lineage, or platform decisions, read `../architecting-data/SKILL.md`. Read only its references relevant to the request, especially `references/medallion-pattern.md`, `references/modeling-approaches.md`, and `references/governance-patterns.md`.
- For T-SQL, schema objects, stored procedures, indexes, transactions, security, or performance, read `../sql-expert/SKILL.md` and only the references needed for the task.
- For end-to-end medallion work, use both. Treat cloud and lakehouse recommendations in `architecting-data` as comparative options, not as platform requirements.

The user's request and the repository's documented constraints take precedence over defaults in either supporting skill.

## Layer Contracts

### Bronze

Preserve source fidelity and enough history and metadata to replay or reproduce downstream state.

- Retain source values before business transformation.
- Capture source identity, ingestion time in UTC, batch or run identity, and a deterministic record identity where practical.
- Make ingestion restartable and idempotent.
- Append-only storage is a useful default, not an absolute rule. Snapshots, CDC history, temporal history, or current-plus-history designs are valid when they preserve replay semantics.
- Do not hide rejected input. Retain it with an explicit disposition or quarantine path.

### Silver

Produce typed, validated, deduplicated, and conformed records.

- Make validation and survivorship rules explicit and testable.
- Resolve source-system differences without embedding reporting-specific business calculations.
- Preserve traceability to Bronze records and pipeline runs.
- Record failed quality rules and choose deliberately between quarantine, warning, and load failure.

### Gold

Expose stable, business-oriented models for analytics and reporting.

- Prefer dimensional models when the primary consumers are BI and analytical queries.
- Define grain before facts, measures, and joins.
- Keep metric logic consistent and document slowly changing dimension behavior.
- Optimize for consumer semantics without bypassing Silver validation.

## SQL Server 2022 Defaults

- The starter repository uses separate `bronze`, `silver`, `gold`, and `audit` schemas in one database. Recommend separate databases only when workload isolation, security, ownership, backup and recovery, or deployment boundaries justify them.
- Target `Microsoft.Data.Tools.Schema.Sql.Sql160DatabaseSchemaProvider`.
- Use UTC audit timestamps with `datetime2(7)` unless a source contract requires another representation.
- Match parameter types to columns, keep predicates SARGable, and use explicit column lists.
- Prefer deterministic `UPDATE` plus `INSERT` patterns inside a transaction for upserts. Use `MERGE` only after its concurrency, duplicate-match, error-handling, and test requirements are deliberately addressed.
- Choose full loads, watermarks, Change Tracking, CDC, or temporal history from source capabilities and recovery requirements. Document watermark inclusivity and late-arriving-data handling.
- Keep secrets and environment-specific connection strings out of source control.

## Workflow

1. Inspect the repository, database project, source contracts, expected volumes, refresh cadence, SLAs, and recovery needs. State unknowns that materially affect the design.
2. Map every existing and proposed object or process to Bronze, Silver, Gold, or cross-cutting audit/control responsibility. Flag layer leakage.
3. Define grain, keys, replay and history behavior, incremental-load semantics, quality gates, lineage, security, and failure recovery before generating substantial T-SQL.
4. Implement the smallest coherent change. Preserve established naming and deployment conventions unless the user asks to change them.
5. Validate the SQL project build when tooling is available. Add focused tests for layer contracts, idempotency, duplicate handling, referential integrity, and restart behavior as applicable.
6. Report assumptions, files changed, verification performed, and any production decisions still required.

For an assessment-only request, stop after findings and recommendations. Do not modify files unless the user asks for implementation.
