# Using the SQL Server Medallion orchestration

The orchestration skill keeps architecture and SQL implementation separate while coordinating both:

- `architecting-data` decides layer responsibilities, modeling, governance, and lineage.
- `sql-expert` applies SQL Server 2022 and T-SQL implementation practices.
- `sqlserver-medallion` enforces this repository's platform and layer contracts.

## Invoke it

In Codex, start the prompt with:

```text
$sqlserver-medallion
```

In Claude Code, start with:

```text
/sqlserver-medallion
```

After installing or changing skills, reload the VS Code window and start a new conversation.

## Local runtime

The initial development target is `localhost`, database `SqlServerMedallion`, using Windows authentication. Build, deploy, and validate it from PowerShell 7 with:

```powershell
& .\scripts\Initialize-LocalSqlServer.ps1
& .\scripts\Test-LocalSqlServer.ps1
```

See `docs/local-development.md` for versions, connection settings, local-only limits, and production boundaries.

## Recommended first prompt

```text
$sqlserver-medallion assess this repository before changing anything.
Map the current data flow to Bronze, Silver, and Gold for SQL Server 2022.
Identify layer leakage, missing replay/history semantics, data-quality gaps,
incremental-load risks, and the smallest recommended target-state changes.
Do not modify files yet.
```

For Claude Code, replace the first token with `/sqlserver-medallion`.

## Useful follow-up prompts

Plan one source:

```text
$sqlserver-medallion design the Bronze-to-Silver flow for <source>.
Define grain, keys, source fidelity, history, replay, idempotency, late-arriving
data, validation, quarantine, lineage, indexes, and operational metrics.
Return a file-by-file plan before implementation.
```

Implement an approved slice:

```text
$sqlserver-medallion implement the approved <source> slice in the SQL project.
Keep the change minimal, use SQL Server 2022 T-SQL, add focused tests, build
the project, and report assumptions and unresolved production decisions.
```

Review a change:

```text
$sqlserver-medallion review the current changes for layer leakage, loss of
source fidelity, non-idempotent loads, duplicate-match behavior, transaction
safety, SARGability, security, observability, and missing tests. Do not edit.
```

## Repository layer map

| Responsibility | Schema | Project folder | Pipeline folder |
| --- | --- | --- | --- |
| Source-faithful, replayable landing | `bronze` | `database/Bronze` | `pipelines/bronze` |
| Typed, validated, conformed data | `silver` | `database/Silver` | `pipelines/silver` |
| Business-ready analytical models | `gold` | `database/Gold` | `pipelines/gold` |
| Runs, quality, lineage, operations | `audit` | `database/Audit` | Cross-cutting |

This starter uses schemas in one database. A move to separate databases should be an explicit architecture decision based on isolation, security, ownership, backup/recovery, deployment, and workload needs.

## Implemented source-neutral controls

The `audit` schema now contains run attempts, committed checkpoints, versioned
data-quality results, object-level lineage, and procedures that keep successful
target changes and checkpoint advancement in one transaction. Layer-specific
roles and smoke tests enforce the intended Bronze-to-Silver-to-Gold dependency
direction where SQL Server dependency metadata can observe it.

Before adding the first source-specific object, copy
`docs/templates/source-contract.md` and approve its source keys, capture and
watermark semantics, replay/history behavior, quality policy, and target grain.
