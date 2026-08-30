# Bronze database objects

Place source-faithful, replayable landing tables and ingestion procedures here. Capture source identity, ingestion UTC time, pipeline run ID, and enough source history to reproduce downstream state. Do not add business transformations.

Each table must implement the approved `docs/templates/source-contract.md`,
including a deterministic ingestion identity, explicit retention/history mode,
and retained invalid input. Bronze procedures are append-oriented and must not
advance checkpoints independently of successful target transactions.
