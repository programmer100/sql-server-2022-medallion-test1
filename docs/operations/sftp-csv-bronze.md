# Secure SFTP ZIP and large-CSV Bronze ingestion

This repository includes a source-neutral PowerShell 7 pipeline for daily ZIP
files delivered over SFTP and CSV files around 2 GB or larger. It does not invent
a real feed schema: copy the example, approve a source contract, and add the
source-specific Bronze heap to the SQL project before production use.

## Implemented flow

```text
SFTP provider
  -> pinned SSH host key + credential from a secret vault
  -> stable-size/mtime check and *.partial download
  -> original ZIP SHA-256 and immutable Bronze archive
  -> path/size/ratio/free-space checks
  -> one CSV extracted and hashed while streaming to local work disk
  -> artifact manifest
  -> streaming CSV IDataReader
  -> SqlBulkCopy (TABLOCK + KeepNulls + per-batch transaction)
  -> source-specific bronze.* heap with file/load/attempt lineage
  -> later TRY_CONVERT, quality, deduplication, and conformance in Silver
```

The acquisition and SQL load remain separate so an archived artifact can be
replayed without reconnecting to SFTP and SFTP can be tested without modifying
SQL Server.

## Files

| File | Purpose |
| --- | --- |
| `pipelines/bronze/Invoke-SftpZipAcquisition.ps1` | SFTP or local ZIP acquisition, archive, safe extraction, hashes, and manifest |
| `pipelines/bronze/Invoke-CsvToSqlBulkLoad.ps1` | Mapping/table validation, streaming parse, retry-safe bulk load, reconciliation, and audit |
| `pipelines/bronze/Invoke-SftpCsvToBronze.ps1` | End-to-end wrapper |
| `pipelines/bronze/CsvDataReader.cs` | Constant-memory quoted CSV reader used by `SqlBulkCopy` |
| `pipelines/bronze/contracts/*.schema.json` | Versioned config contracts |
| `examples/sftp-csv-bronze` | Non-deployed sample feed, landing table, mapping, and local test data |

## Prerequisites

- PowerShell 7.4 or newer.
- The SQL project deployed to SQL Server 2022.
- For SFTP, the WinSCP automation package. PowerShell 7 must load the
  `netstandard2.0/WinSCPnet.dll` build, and the matching `WinSCP.exe` must be
  available. The script derives the executable from the automation-package
  layout when possible.
- A registered PowerShell SecretManagement vault for saved credentials, or a
  runtime `PSCredential` supplied by the scheduler.

WinSCP documents that PowerShell 6/7 requires its .NET Standard assembly and
that `WinSCPnet.dll` and `WinSCP.exe` must be deployed together:
<https://winscp.net/eng/docs/library_install>.

## Store the SFTP credential

Install and register a vault once for the Windows identity that will run the
pipeline. This local example uses SecretStore; production schedulers can use any
registered SecretManagement vault appropriate for the service identity.

```powershell
Install-Module Microsoft.PowerShell.SecretManagement -Scope CurrentUser
Install-Module Microsoft.PowerShell.SecretStore -Scope CurrentUser

Register-SecretVault `
    -Name LocalStore `
    -ModuleName Microsoft.PowerShell.SecretStore `
    -DefaultVault

$sftpCredential = Get-Credential -Message 'SFTP user and password or private-key passphrase'
Set-Secret `
    -Name 'sql-medallion-sample-pos-sftp' `
    -Secret $sftpCredential `
    -Vault LocalStore
```

`Get-Secret` returns a `PSCredential` object without using `-AsPlainText`. Do not
put the password, passphrase, connection URL, private-key content, or a serialized
credential in JSON, environment files, logs, scheduled-task arguments, or Git.
For unattended work, configure a vault that the service identity can unlock
non-interactively according to your security policy; do not weaken an interactive
vault merely to avoid a prompt.

PowerShell SecretManagement usage is documented at
<https://learn.microsoft.com/powershell/module/microsoft.powershell.secretmanagement/get-secret>.

## Pin the SSH host key

Obtain the server SHA-256 host-key fingerprint through a second trusted channel
from the SFTP owner. Put only that public fingerprint in the local acquisition
config. The scripts reject `*`, `acceptnew`, and accept-any behavior. If the host
key changes, stop and re-verify it out of band before updating configuration.

WinSCP's host-key procedure is documented at
<https://winscp.net/eng/docs/faq_hostkey>.

For private-key authentication, set `sftp.authMode` to `privateKey`, set
`privateKeyPath` to an ACL-protected local key file, and store a `PSCredential`
whose username is the SFTP user and whose secure password is the key passphrase.

## Protect archive and work roots

Use absolute directories outside the Git checkout. The scripts refuse archive
or work roots inside the repository and refuse nested archive/work roots.

```powershell
New-Item -ItemType Directory -Force `
    D:\SqlServerMedallion\bronze-archive, `
    D:\SqlServerMedallion\work
```

Grant the pipeline service identity, administrators, backup service, and SYSTEM
only the permissions they require. Validate the final ACLs with your security
team. The archived ZIP is marked read-only after verification, but Windows
read-only is not immutable storage. Production retention, backup, ransomware
protection, and WORM requirements need infrastructure controls beyond this repo.

The work area contains extracted source data and JSONL logs. Treat it as
sensitive, apply retention, and securely clean completed work files according to
the source contract. The pipeline never deletes or renames the provider's remote
file.

## Create a feed

1. Copy `docs/templates/source-contract.md` and approve ownership, classification,
   archive retention, expected ZIP/CSV sizes, cadence, schema evolution, replay,
   and Bronze-to-Silver rules.
2. Copy the two example JSON files to
   `pipelines/bronze/config/<feed>.local.json`. Files matching
   `pipelines/bronze/config/*.local.json` are ignored by Git because paths and
   vault names are environment-specific.
3. Add a source-specific `bronze.*` heap to `database/Bronze/Tables` and the SQL
   project. Every source column must be nullable `NVARCHAR(n)` or
   `NVARCHAR(MAX)`. Add these exact technical columns:

   ```sql
   [FileLoadId] BIGINT NOT NULL,
   [FileLoadAttemptId] BIGINT NOT NULL,
   [SourceRecordNumber] BIGINT NOT NULL,
   [SourceFileName] NVARCHAR(260) NOT NULL,
   [IngestedAtUtc] DATETIME2(7) NOT NULL
   ```

4. Set each mapping column's `landingMaxLength` to the Bronze capacity. Use `-1`
   only with `NVARCHAR(MAX)`. Put the intended Silver type in `businessType` and
   the business length in `businessMaxLength`. A 400-character upstream value
   must be able to land in Bronze even when Silver later rejects it against a
   20-character business rule.
5. Build, publish, and test the database before running the feed.

The loader does not auto-create or auto-alter a table. It fails before reading
the CSV if a mapped column is absent, too narrow, typed incorrectly, computed,
identity, or non-nullable. With `requireHeap=true`, it also fails if an index is
present. Required source headers are enforced; extra headers fail when
`strictHeader=true`.

## Run the local example

The example table is intentionally not part of the DACPAC. Install it only in a
disposable local database:

```powershell
sqlcmd `
    -S localhost `
    -d SqlServerMedallion `
    -E -C -b `
    -i .\examples\sftp-csv-bronze\Create-ExampleTable.sql

$demoRoot = Join-Path $env:TEMP ('SqlServerMedallion-Demo-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $demoRoot | Out-Null

$zipPath = Join-Path $demoRoot 'sample-sales.zip'
Compress-Archive `
    -LiteralPath .\examples\sftp-csv-bronze\sample-sales.csv `
    -DestinationPath $zipPath

& .\pipelines\bronze\Invoke-SftpCsvToBronze.ps1 `
    -ConfigPath .\examples\sftp-csv-bronze\sftp-feed.example.json `
    -MappingPath .\examples\sftp-csv-bronze\mapping.example.json `
    -LocalZipPath $zipPath `
    -ArchiveRoot (Join-Path $demoRoot 'archive') `
    -WorkRoot (Join-Path $demoRoot 'work') `
    -SqlInstance localhost `
    -Database SqlServerMedallion `
    -TrustServerCertificate
```

The sample proves that quoted commas and embedded newlines remain one logical
record and that `not-a-date` lands unchanged in Bronze. The local trusted
certificate switch is not a production setting.

## Run an SFTP feed

```powershell
& .\pipelines\bronze\Invoke-SftpCsvToBronze.ps1 `
    -ConfigPath .\pipelines\bronze\config\sales.local.json `
    -MappingPath .\pipelines\bronze\config\sales-mapping.local.json `
    -SqlInstance localhost `
    -Database SqlServerMedallion `
    -TrustServerCertificate
```

The wrapper hashes the ZIP and CSV during acquisition and passes the manifest
directly to the loader, so it skips a second hash pass by default. Use
`-ReverifyHashes` for a separated or higher-risk handoff. Use the standalone
loader without `-SkipHashVerification` when replaying an older manifest.

## Retry and idempotency behavior

Two identities are deliberate:

- `FileLoadId` is the logical CSV content + exact mapping + Bronze target load.
- `FileLoadAttemptId` is one physical bulk-copy attempt.

`UseInternalTransaction` makes each `BatchSize` batch independently committed.
Before any new attempt, the loader executes a parameterized delete scoped only
to `FileLoadId`, then starts from the beginning with a new attempt identity. A
successful repeat is skipped. A changed mapping file has a changed mapping hash
and is treated as an explicit reprocess even if its version string was not
changed; still update the version string for operators and lineage.

An abrupt process termination can leave an attempt `Started`. A subsequent run
fails rather than assuming it is abandoned. After confirming the old process is
not running, an operator can use `-AbandonStartedAfterMinutes <minutes>` to mark
only an older attempt abandoned and restart. Choosing the threshold without
checking the original host/process can create concurrent writers.

## Rejects and quality

CSV structure failures such as a field-count mismatch can be recorded in
`audit.CsvRowReject` up to `MaxRejects`. Unterminated quotes and unsafe parser
states fail the attempt rather than treating the rest of the file as one reject.
Raw reject fragments are null by default; `-CaptureRejectFragments` is opt-in
because fragments may contain PII.

Type conversion, business lengths, nullability, deduplication, and conformance
belong in the source-specific Bronze-to-Silver procedure using `TRY_CONVERT` and
documented quality dispositions. Bronze input values are not trimmed, cast, or
business-normalized by this loader.

## Performance validation

The path is `FileStream -> 1 MB StreamReader -> IDataReader -> SqlBulkCopy ->
Bronze heap`. Memory is bounded by the current record plus driver buffers. The
default batch size is 100,000; benchmark representative files before changing
it or adding per-file parallelism.

Record CSV bytes, row counts, elapsed seconds, rows/second, MB/second, loader CPU,
SQL CPU, network throughput, data/log write latency, and log growth. A single
loader core at 100% with idle SQL/network/disk points to parser CPU; `WRITELOG`
or storage saturation points elsewhere. Parallel loads into the same heap while
using `TABLOCK` can block one another and increase log pressure.

Microsoft documents that `SqlBulkCopy` supports `IDataReader`, that
`UseInternalTransaction` transacts each batch separately, and that `TABLOCK`
uses a bulk-update lock:

- <https://learn.microsoft.com/dotnet/api/microsoft.data.sqlclient.sqlbulkcopy>
- <https://learn.microsoft.com/dotnet/api/microsoft.data.sqlclient.sqlbulkcopy.batchsize>
- <https://learn.microsoft.com/dotnet/api/system.data.sqlclient.sqlbulkcopyoptions>
- <https://learn.microsoft.com/sql/relational-databases/sql-server-transaction-locking-and-row-versioning-guide>

## Operations and recovery

- `audit.FileArtifact` records original archive evidence and SFTP metadata.
- `audit.FileLoad` records logical idempotency and reconciled outcome.
- `audit.FileLoadAttempt` retains every failed, abandoned, and successful physical
  attempt and its `PipelineRunId`.
- `audit.CsvRowReject` retains structural reject identity and reason.
- JSONL logs are written under the work area and contain paths, counts, hashes,
  and errors but no credential values. They can still be sensitive.

Do not delete a failed archive: fix the mapping/code or upstream contract, then
replay the retained artifact. Do not edit an archived ZIP in place. If upstream
redelivers different ZIP bytes containing identical CSV content, the archive is
registered as distinct evidence while the already-successful CSV/mapping/target
load is skipped.

The database migration is additive. Reverting source control does not remove
deployed objects because local publishing keeps objects not present in the
DACPAC. Follow ADR 0003 before any manual rollback or audit-history deletion.
