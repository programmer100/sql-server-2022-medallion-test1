# Bronze pipelines

Document or implement source ingestion orchestration here. Each pipeline should define source contract, load mode, batch identity, watermark behavior, retry/replay behavior, and operational metrics.

Copy `docs/templates/source-contract.md` to a source-specific design and approve
it before implementation. Capture a stable attempted upper boundary in
`audit.PipelineRun`; commit `audit.PipelineCheckpoint` only with successful
target changes.

For daily ZIP files delivered over SFTP, use the reusable components in this
folder and follow `docs/operations/sftp-csv-bronze.md`. Do not store credentials
in JSON. Pin the SSH host key, retain the original ZIP, validate ZIP expansion,
land source values as text, and preserve the logical `FileLoadId` plus physical
`FileLoadAttemptId`. The loader validates a source-specific Bronze heap from the
database project; it does not create tables dynamically.
