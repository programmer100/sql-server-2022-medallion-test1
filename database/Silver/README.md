# Silver database objects

Place typed, validated, deduplicated, and conformed tables and procedures here. Preserve traceability to Bronze and make quality failures explicit.

Use deterministic tie-breakers and `UPDATE` plus `INSERT` patterns inside a
transaction. Store Bronze row/run lineage and route invalid rows according to the
approved warning, quarantine, or load-failure policy.
