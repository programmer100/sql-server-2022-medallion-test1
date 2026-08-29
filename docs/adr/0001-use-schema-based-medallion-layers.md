# ADR 0001: Use schema-based Medallion layers initially

- Status: Accepted for the starter
- Date: 2026-08-29

## Decision

Use `bronze`, `silver`, `gold`, and `audit` schemas in one SQL Server 2022 database for the initial project.

## Rationale

The repository has no source volumes, security boundaries, operational owners, or recovery requirements yet. Separate schemas provide clear logical contracts with the smallest deployable footprint. The database project can validate cross-layer dependencies in one build.

## Revisit when

Move one or more layers to separate databases only when workload isolation, permissions, ownership, independent deployment, backup/recovery, availability, storage, or scaling requirements justify the added operational complexity.
