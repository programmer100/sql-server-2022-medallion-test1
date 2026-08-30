# ADR 0002: Use run-scoped checkpoints and enforced layer flow

- Status: Accepted
- Date: 2026-08-30

## Context

The starter recorded runs and quality outcomes but did not distinguish attempted
watermark ranges from committed operational state. It also documented lineage
and Bronze-to-Silver-to-Gold flow without implementing either control.

Source systems and business grains are not yet known, so source-specific capture,
history, conformance, and dimensional decisions cannot be inferred safely.

## Decision

- Record every attempt in `audit.PipelineRun`, including pipeline version,
  source identity, attempted low/high boundaries, and replay ancestry.
- Store the last successful boundary separately in
  `audit.PipelineCheckpoint`, keyed by pipeline, source object, and partition.
- Advance a checkpoint only through successful run completion in the same
  transaction as target changes.
- Record versioned quality outcomes and run-scoped object lineage in `audit`.
- Reject discoverable dependencies that bypass Bronze-to-Silver-to-Gold
  refinement and expose layer-specific least-privilege database roles.
- Require an approved source contract before source-specific layer objects are
  implemented. Require an approved consumer grain before Gold is implemented.

## Consequences

Retries and replays are observable without treating an attempted watermark as a
committed checkpoint. Target writes and checkpoint changes can roll back
together. Quality and lineage have consistent run identity.

Watermark values remain generic serialized text in the source-neutral control
plane. Each source contract must define its real source type, serialization,
comparison semantics, and matching T-SQL parameter types. Dependency inspection
cannot detect dynamic SQL, so review and tests remain necessary.

The original `PipelineRun.SourceWatermark` column remains temporarily for a
non-destructive DACPAC migration, but new code must not populate it.
