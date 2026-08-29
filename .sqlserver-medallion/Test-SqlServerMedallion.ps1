[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RepoPath = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $RepoPath).Path
$errors = [System.Collections.Generic.List[string]]::new()

$skillChecks = @(
    @{ Path = '.agents\skills\architecting-data\SKILL.md'; Name = 'architecting-data' },
    @{ Path = '.agents\skills\sql-expert\SKILL.md'; Name = 'sql-expert' },
    @{ Path = '.agents\skills\sqlserver-medallion\SKILL.md'; Name = 'sqlserver-medallion' },
    @{ Path = '.claude\skills\architecting-data\SKILL.md'; Name = 'architecting-data' },
    @{ Path = '.claude\skills\sql-expert\SKILL.md'; Name = 'sql-expert' },
    @{ Path = '.claude\skills\sqlserver-medallion\SKILL.md'; Name = 'sqlserver-medallion' }
)

foreach ($check in $skillChecks) {
    $path = Join-Path $root $check.Path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $errors.Add("Missing skill entry point: $($check.Path)")
        continue
    }

    $content = Get-Content -Raw -LiteralPath $path
    $expectedName = [regex]::Escape($check.Name)
    if ($content -notmatch "(?m)^name:\s*$expectedName\s*$") {
        $errors.Add("Unexpected or missing skill name in $($check.Path)")
    }
}

$manifestPath = Join-Path $root '.sqlserver-medallion\manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    $errors.Add('Missing .sqlserver-medallion\manifest.json')
}
else {
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    if ($manifest.upstream.architectingData.ref -ne 'd6b36cd8f6ecd0c886c5c12c316adb16014b40de') {
        $errors.Add('Unexpected architecting-data revision in manifest.json')
    }
    if ($manifest.upstream.sqlExpert.ref -ne '23dae0738ba6f7e70fc66d8df57cee9464cfd355') {
        $errors.Add('Unexpected sql-expert revision in manifest.json')
    }
}

$projectPath = Join-Path $root 'database\SqlServerMedallion.sqlproj'
if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    $errors.Add('Missing database\SqlServerMedallion.sqlproj')
}
elseif ((Get-Content -Raw -LiteralPath $projectPath) -notmatch 'Sql160DatabaseSchemaProvider') {
    $errors.Add('The database project does not target SQL Server 2022 (Sql160)')
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ }
    throw "SQL Server Medallion validation failed with $($errors.Count) error(s)."
}

Write-Host 'SQL Server Medallion validation passed.' -ForegroundColor Green
Write-Host "Validated $($skillChecks.Count) skill entry points and the SQL Server 2022 project target."
