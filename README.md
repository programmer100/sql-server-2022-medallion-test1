# SQL Server 2022 Medallion

A repo-local starter for building Bronze, Silver, and Gold data layers with Microsoft SQL Server 2022, VS Code, Claude Code, and Codex.

## Included

- An SDK-style SQL database project targeting the SQL Server 2022 (`Sql160`) schema provider.
- `bronze`, `silver`, `gold`, and `audit` schemas with starter audit/control tables.
- Repo-local `architecting-data`, `sql-expert`, and `sqlserver-medallion` skills for both Codex and Claude Code.
- Layer, pipeline, testing, and architecture-documentation folders.
- PowerShell 7 validation, build, local deployment, and smoke-test helpers.
- A working local SQL Server 2022 Developer database at `localhost` for the initial scaffold.

## Start here

1. Open this folder in VS Code and install the recommended SQL and PowerShell extensions when prompted. The workspace selects PowerShell 7 as its default terminal.
2. Open a new terminal and verify the local toolchain:

   ```powershell
   pwsh --version
   dotnet --list-sdks
   sqlcmd --version
   sqlpackage /Version
   ```

3. Build, deploy, configure, and test the local database:

   ```powershell
   & .\scripts\Initialize-LocalSqlServer.ps1
   & .\scripts\Test-LocalSqlServer.ps1
   ```

4. Validate the skill setup:

   ```powershell
   & .\.sqlserver-medallion\Test-SqlServerMedallion.ps1 -RepoPath .
   ```

5. Reload VS Code, then start a new Claude Code or Codex conversation so repo-local skills are rediscovered.

6. For a build without deployment:

   ```powershell
   & .\scripts\Build.ps1
   ```

7. Read `SQLSERVER_MEDALLION.md` and begin with an assessment prompt before implementing source-specific objects.

See `docs/local-development.md` for installed versions, VS Code connection settings, reproduction commands, and the boundary between local and production configuration.

The scaffold intentionally contains no source-system tables or business model. Add those only after source contracts, grains, keys, history, refresh cadence, and data-quality rules are known.
