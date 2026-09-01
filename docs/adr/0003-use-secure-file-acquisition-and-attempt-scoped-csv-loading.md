# ADR 0003: Use secure file acquisition and attempt-scoped CSV loading

- Status: Accepted
- Date: 2026-08-31

## Context

Daily source extracts can arrive as ZIP archives over SFTP and expand to CSV
files around 2 GB or larger. The pipeline must retain the inbound evidence,
handle quoted delimiters and embedded newlines, keep memory use bounded, avoid
duplicate rows after partial batch commits, and keep credentials out of Git.

`SqlBulkCopy` with `UseInternalTransaction` commits each configured batch as a
separate transaction. Retrying the complete file against the same target without
cleanup can therefore duplicate every batch committed before a transient error.

## Decision

Use two separate components:

1. PowerShell 7 and WinSCP acquire a stable ZIP over SFTP. The connection must
   pin an out-of-band-verified SSH host-key fingerprint. A `PSCredential` is
   injected directly or retrieved from a registered PowerShell SecretManagement
   vault; JSON never contains a password, passphrase, or private-key content.
2. The original ZIP is the immutable Bronze file artifact. Acquisition verifies
   the remote byte count, computes SHA-256, archives the original bytes, rejects
   unsafe ZIP paths and expansion limits, extracts exactly one expected CSV, and
   computes the CSV SHA-256 while writing it to the work area.
3. A custom streaming `IDataReader` parses RFC-4180-style quoted fields and feeds
   `SqlBulkCopy`. Source columns land as nullable `NVARCHAR`; mapping
   `businessType` and `businessMaxLength` describe later Bronze-to-Silver rules
   and do not narrow the Bronze landing table.
4. `audit.FileLoad` identifies a logical load by feed, CSV content hash, exact
   mapping hash, and Bronze target. `audit.FileLoadAttempt` identifies each
   physical attempt and links it to `audit.PipelineRun`.
5. Before every physical attempt, delete only target rows with that logical
   `FileLoadId`. This makes full-file retry safe after prior `SqlBulkCopy` batches
   committed. A successful repeat of the same content/mapping/target is skipped.
6. Source-specific landing tables must exist in the database project. The loader
   validates every mapped and technical column and does not create or alter SQL
   objects dynamically.

## Consequences

- Original inbound evidence remains replayable independently of SQL retention.
- ZIP-byte identity and extracted-content identity are distinct and both are
  recorded.
- Structural CSV rejects can be quarantined up to a configured threshold; type
  and business-rule failures remain Bronze-to-Silver concerns.
- `TABLOCK`, a heap, and batching support high throughput, but production logging
  behavior still depends on recovery model, target shape, replication, and SQL
  Server bulk-load prerequisites. The local SIMPLE recovery setting is not a
  production recommendation.
- Reject fragments are disabled by default because they can contain sensitive
  source values.
- The local archive read-only flag is a guardrail, not a WORM guarantee. ACLs,
  backup, retention, and immutable storage controls remain deployment decisions.

## Migration and rollback

The database change is additive: four audit tables, four procedures, indexes,
constraints, and Bronze loader permissions. Existing Bronze/Silver/Gold objects
are not changed.

Reverting Git alone does not remove deployed controls because local publishing
uses `DropObjectsNotInSource=False`. A rollback must first stop loaders, export
required audit history, verify that no source-specific tables reference
`FileLoadId`/`FileLoadAttemptId`, then drop dependent reject rows, attempts,
logical loads, artifacts, procedures, and tables in foreign-key order. Archived
ZIPs are independent evidence and must follow the approved retention policy; do
not delete them as part of a code rollback.
