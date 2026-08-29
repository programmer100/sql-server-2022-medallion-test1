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
