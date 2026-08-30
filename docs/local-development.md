# Local development environment

This repository's initial runtime is a local, non-production SQL Server 2022 Developer instance. It deliberately avoids cloud services and preserves the same logical Bronze, Silver, and Gold contracts that a later production platform must implement.

## Installed baseline

| Component | Installed version | Purpose |
| --- | --- | --- |
| PowerShell | 7.6.5 | Repository automation and VS Code terminal |
| .NET SDK | 8.0.424 | Microsoft.Build.Sql project builds |
| Microsoft.Build.Sql | 2.2.0 | SQL project SDK pinned in the `.sqlproj` |
| SQL Server | 2022 Developer CU26, 16.0.4265.3 | Local database engine; development/test only |
| sqlcmd | 1.10.0 | Live T-SQL and smoke tests |
| SqlPackage | 170.4.83.3 | DACPAC deployment |

The repository's `global.json` selects the latest installed .NET 8 patch in the 8.0.4xx feature band. SQL Server cumulative updates continue after this scaffold; check Microsoft's SQL Server 2022 build history before reproducing the environment later.

## Connection

Use these settings in the VS Code MSSQL extension:

| Setting | Value |
| --- | --- |
| Server | `localhost` |
| Database | `SqlServerMedallion` |
| Authentication | Windows / Integrated |
| Encrypt | Enabled |
| Trust server certificate | Enabled for this local instance only |

No SQL login, password, remote firewall rule, or production credential is stored in this repository.

## Build, deploy, and test

Open a new PowerShell 7 terminal after installing prerequisites.

```powershell
pwsh --version
dotnet --list-sdks
sqlcmd --version
sqlpackage /Version

& .\scripts\Initialize-LocalSqlServer.ps1
& .\scripts\Test-LocalSqlServer.ps1
```

### Refreshing PATH in an older VS Code window

VS Code terminals inherit their environment from the VS Code process. If VS
Code was open while `sqlcmd` or `SqlPackage` was installed, even a new terminal
can initially inherit the older PATH. The workspace settings add both installed
tool locations to new terminals. Either run **Developer: Reload Window** and
open a new terminal, or refresh the current terminal without restarting it:

```powershell
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$env:Path = "$machinePath;$userPath;$env:Path"

sqlcmd --version
sqlpackage /Version
```

`Initialize-LocalSqlServer.ps1` is idempotent for the scaffold: it rebuilds and republishes the DACPAC without dropping objects that are absent from the project, applies the documented local settings, and runs every ordered SQL test in `tests/smoke`.

Because local publication uses `DropObjectsNotInSource=False`, an object removed
from the project can remain in an existing local database. This protects local
data from accidental drops but means the database can drift from the DACPAC.
Use a disposable database or review a SqlPackage deployment report when exact
schema equivalence matters.

## Local-only settings

- The default instance is `MSSQLSERVER`, addressed as `localhost`.
- Windows authentication is used; the installing Windows account is the local SQL administrator.
- SQL Server max memory is capped at 8,192 MB on this 32 GB workstation.
- `SqlServerMedallion` uses compatibility level 160, SIMPLE recovery, and Query Store.
- Developer edition is licensed for development and test, not production.

Do not copy the 8 GB memory cap, SIMPLE recovery model, certificate trust, administrator access, or local connection assumptions into production. Production requires explicit capacity planning, backup and restore objectives, TLS and certificate management, service identities, least privilege, network controls, monitoring, retention, high availability, and patch-management decisions.

## Reinstall prerequisites

From an elevated Windows terminal, WinGet package identifiers are:

```powershell
winget install --id Microsoft.PowerShell --exact --source winget
winget install --id Microsoft.DotNet.SDK.8 --exact --source winget
winget install --id Microsoft.Sqlcmd --exact --source winget
winget install --id Microsoft.SqlPackage --exact --source winget
winget install --id Microsoft.SQLServer.2022.Developer --exact --source winget
```

The SQL Server bootstrap package can install the RTM engine. Apply Microsoft's latest SQL Server 2022 cumulative update before using the instance, then verify the live build with `SERVERPROPERTY('ProductVersion')`.
