# SQL Server 2022 Medallion architecture

## Context

This repository starts with a single SQL Server 2022 database and four schemas. The logical layers remain explicit even though they share a database. This keeps the initial operational footprint small while preserving a migration path to separate databases if isolation requirements emerge.

## Data flow

```text
Source systems
      |
      v
bronze  -- source-faithful, auditable, replayable
      |
      v
silver  -- typed, validated, deduplicated, conformed
      |
      v
gold    -- business-ready dimensions, facts, aggregates, views

audit records runs, quality results, lineage, and operational state
```

## Implemented control plane

The repository implements source-neutral operational controls in `audit`; it
does not yet implement a source-specific data flow.

| Object | Responsibility |
| --- | --- |
| `audit.PipelineRun` | Records each attempt, its code version, source identity, attempted watermark range, outcome, counters, and replay parent. |
| `audit.PipelineCheckpoint` | Stores only the last successfully committed source watermark for a pipeline/source/partition. |
| `audit.DataQualityResult` | Records versioned quality rules, severity, threshold, outcome, and failure disposition. |
| `audit.LineageEvent` | Records run-scoped object-level movement through allowed layer transitions. |
| `audit.usp_StartPipelineRun` | Creates a validated run attempt and copies extraction boundaries from a replay parent when appropriate. |
| `audit.usp_CompletePipelineRun` | Completes an active run and optionally advances its checkpoint in the same transaction. |
| `audit.usp_RecordDataQualityResult` | Records a quality evaluation for an active run. |
| `audit.usp_RecordLineageEvent` | Records an allowed lineage edge for an active run. |

`PipelineRun.SourceWatermark` is retained only to avoid a destructive migration
for databases created from the initial scaffold. New pipelines must use
`WatermarkStart` and `WatermarkEnd`.

### Transaction and checkpoint contract

An incremental pipeline must capture a stable upper boundary before reading the
source and record both attempted boundaries on its run. Its source-specific
design must state whether each boundary is inclusive or exclusive and how ties,
late arrivals, updates, and deletes are handled.

Target data changes, quality and lineage records, and
`audit.usp_CompletePipelineRun` should execute inside one caller-owned
transaction. The completion procedure participates in an existing transaction;
it does not commit it. A checkpoint is advanced only for a successful run and is
rolled back with the target changes when the caller rolls back. Full extraction
or remote source reads should occur before the short target transaction.

### Layer boundaries and access

Static smoke tests reject schema-bound dependencies that bypass refinement:
Bronze cannot reference Silver or Gold, Silver cannot reference Gold, and Gold
cannot reference Bronze. Dynamic SQL cannot be discovered through SQL Server's
dependency metadata and therefore requires review.

The project defines these least-privilege roles without assigning users:

- `medallion_bronze_loader`: execute Bronze and audit procedures.
- `medallion_silver_loader`: read Bronze and execute Silver and audit procedures.
- `medallion_gold_loader`: read Silver and execute Gold and audit procedures.
- `medallion_gold_reader`: read Gold only.

Production identities and role membership remain environment-specific and must
not be committed to this repository.

## Source implementation gate

Complete `docs/templates/source-contract.md` and approve it before adding the
associated source-specific tables or load procedures. Implement one narrow
Bronze-to-Silver slice first; add Gold only after its consumer, grain, history,
and metrics are approved.

## Decisions still required per source

- Source ownership and contract
- Batch, micro-batch, or streaming cadence
- Full load, watermark, Change Tracking, CDC, or another capture strategy
- Natural and durable record keys
- Snapshot and history retention
- Duplicate and late-arriving-data behavior
- Quarantine and load-failure thresholds
- Silver survivorship and conformance rules
- Gold grain, SCD strategy, and metric definitions
- Recovery point, recovery time, security, and retention requirements

Do not invent these decisions silently. Capture them in an ADR or source-specific design before implementing the associated pipeline.
