# Source contract: <source-system> / <source-object>

Copy this file to a source-specific design document and replace every placeholder.
Do not implement its Bronze, Silver, or Gold objects until the required decisions
are approved.

## Ownership and service objectives

- Business owner:
- Technical owner:
- Source-system owner:
- Data classification and PII fields:
- Refresh cadence and allowed processing window:
- Freshness SLA:
- Expected and peak row volume:
- Recovery point objective:
- Recovery time objective:
- Source and warehouse retention requirements:

## Source contract

- Source platform and version:
- Source object or endpoint:
- Extraction interface and authentication method:
- Source row/event grain:
- Durable natural key:
- Source change timestamp/version/LSN, if available:
- Source time zone and timestamp precision:
- Update behavior:
- Delete or tombstone behavior:
- Schema-evolution notification and compatibility policy:

## Capture and incremental semantics

- Load mode: full, watermark, Change Tracking, CDC, or snapshot:
- Checkpoint value and serialized `WatermarkType`:
- Lower-bound predicate and inclusivity:
- Upper-bound predicate and inclusivity:
- How a stable upper bound is captured before extraction:
- Deterministic tie-breaker for duplicate watermark values:
- Initial-load boundary:
- Late-arriving or backdated lookback window:
- Overlap deduplication rule:
- Missing/deleted-row detection:
- Source throttling and pagination behavior:
- Retry and replay behavior:

## Bronze contract

- Proposed table and row grain:
- Source-faithful columns or retained raw payload:
- Source record locator:
- Deterministic ingestion identity and unique constraint:
- Required metadata: `PipelineRunId`, source identity, source change value,
  extraction time, and `IngestedAtUtc datetime2(7)`:
- Append-only, snapshot, CDC-history, temporal, or current-plus-history strategy:
- Invalid-input retention and disposition:
- Replay and retention behavior:

Bronze must preserve source values before business transformation. It may add
technical metadata, hashes, and parsing diagnostics.

## Silver contract

- Proposed table and row grain:
- Target types, precision, scale, collation, and UTC conversion rules:
- Required-field and domain validations:
- Deduplication partition and deterministic ordering:
- Survivorship and conformance rules:
- Bronze row/run lineage columns:
- Quarantine table and rejected-row identity:
- Warning, quarantine, and load-failure thresholds:
- Current-state or history strategy:
- Idempotent `UPDATE` plus `INSERT` key:

Silver must remain consumer-neutral: typed, validated, deduplicated, conformed,
and traceable to Bronze.

## Gold contract

Leave this section unimplemented until a real consumer requirement exists.

- Consumer and business process:
- Fact table and declared grain:
- Dimension natural and surrogate keys:
- Slowly changing dimension type by attribute:
- Late-arriving fact and dimension behavior:
- Unknown-member policy:
- Metric names, formulas, units, and additive behavior:
- Reconciliation rules back to Silver:
- Query patterns and indexing expectations:

## Operational workflow

- Pipeline names and code versions:
- Dependency order:
- Transaction boundary for target changes and checkpoint commitment:
- Row-count reconciliation:
- Quality rules, versions, severity, and disposition:
- Lineage events:
- Alerting and operator runbook:
- Service identities and database roles:
- Backup, restore, and replay validation:

## Required tests

- Initial load and empty source
- Duplicate input and deterministic survivorship
- Invalid types and required fields
- Quarantine and load-failure thresholds
- Repeated-run idempotency
- Interrupted-run restart without checkpoint advancement
- Watermark boundary ties and overlapping lookback
- Late-arriving update
- Source deletion or tombstone
- Bronze-to-Silver row lineage
- Silver-to-Gold referential integrity and reconciliation, when Gold exists

## Approval

- Source owner:
- Data owner:
- Platform owner:
- Security/privacy reviewer:
- Decision date:
