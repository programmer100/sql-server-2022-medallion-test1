# Bronze pipelines

Document or implement source ingestion orchestration here. Each pipeline should define source contract, load mode, batch identity, watermark behavior, retry/replay behavior, and operational metrics.

Copy `docs/templates/source-contract.md` to a source-specific design and approve
it before implementation. Capture a stable attempted upper boundary in
`audit.PipelineRun`; commit `audit.PipelineCheckpoint` only with successful
target changes.
