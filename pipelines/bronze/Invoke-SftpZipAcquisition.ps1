#requires -Version 7.4

<#
.SYNOPSIS
    Acquires stable ZIP files over SFTP, archives the original bytes, safely
    extracts one CSV, and emits a hash-backed artifact manifest.

.DESCRIPTION
    SFTP credentials are accepted as PSCredential objects or retrieved as a
    PSCredential from Microsoft.PowerShell.SecretManagement. The configuration
    must pin the SSH host key. Passwords, passphrases, and private-key contents
    are never accepted in JSON.

    Use -LocalZipPath to exercise the same archive, ZIP-safety, hash, and
    manifest path without an SFTP connection.
#>
[CmdletBinding(DefaultParameterSetName = 'Sftp')]
param(
    [Parameter(Mandatory)]
    [string]$ConfigPath,

    [Parameter(ParameterSetName = 'Sftp')]
    [pscredential]$SftpCredential,

    [Parameter(Mandatory, ParameterSetName = 'Local')]
    [string]$LocalZipPath,

    [Parameter()]
    [string]$ArchiveRoot,

    [Parameter()]
    [string]$WorkRoot,

    [Parameter(ParameterSetName = 'Sftp')]
    [string]$WinScpAssemblyPath,

    [Parameter(ParameterSetName = 'Sftp')]
    [ValidateRange(1, 1000)]
    [int]$MaxFiles = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$configFile = Get-Item -LiteralPath $ConfigPath
$config = Get-Content -LiteralPath $configFile.FullName -Raw | ConvertFrom-Json

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Context
    )

    if (-not $Object.PSObject.Properties.Name.Contains($Name)) {
        throw "$Context is missing required property '$Name'."
    }
    $value = $Object.$Name
    if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
        throw "$Context property '$Name' cannot be empty."
    }
    return $value
}

function Get-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$Parent
    )

    $candidatePath = (Get-FullPath -Path $Candidate).TrimEnd('\')
    $parentPath = (Get-FullPath -Path $Parent).TrimEnd('\')
    return $candidatePath.Equals($parentPath, [StringComparison]::OrdinalIgnoreCase) -or
        $candidatePath.StartsWith($parentPath + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Convert-HexToByteArray {
    param([Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$Hex)
    $bytes = [byte[]]::new(32)
    for ($index = 0; $index -lt 32; $index++) {
        $bytes[$index] = [Convert]::ToByte($Hex.Substring($index * 2, 2), 16)
    }
    return ,$bytes
}

function Get-Sha256Hex {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)
    $leaf = [System.IO.Path]::GetFileName($Name)
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        throw "File name '$Name' is invalid."
    }
    return ($leaf -replace '[^A-Za-z0-9._-]', '_')
}

$schemaVersion = [int](Get-RequiredProperty -Object $config -Name 'schemaVersion' -Context 'Acquisition config')
if ($schemaVersion -ne 1) {
    throw "Unsupported acquisition config schemaVersion '$schemaVersion'."
}
$feedName = [string](Get-RequiredProperty -Object $config -Name 'feedName' -Context 'Acquisition config')
if ($feedName -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,127}$') {
    throw 'feedName must begin with a letter and contain only letters, digits, dot, underscore, or hyphen.'
}
$acquisition = Get-RequiredProperty -Object $config -Name 'acquisition' -Context 'Acquisition config'

if (-not $PSBoundParameters.ContainsKey('ArchiveRoot')) {
    $ArchiveRoot = [string](Get-RequiredProperty -Object $acquisition -Name 'archiveRoot' -Context 'acquisition')
}
if (-not $PSBoundParameters.ContainsKey('WorkRoot')) {
    $WorkRoot = [string](Get-RequiredProperty -Object $acquisition -Name 'workRoot' -Context 'acquisition')
}

$archiveRootFull = Get-FullPath -Path $ArchiveRoot
$workRootFull = Get-FullPath -Path $WorkRoot
if (Test-PathWithin -Candidate $archiveRootFull -Parent $repoRoot) {
    throw 'archiveRoot must be outside the Git repository so inbound data cannot be committed accidentally.'
}
if (Test-PathWithin -Candidate $workRootFull -Parent $repoRoot) {
    throw 'workRoot must be outside the Git repository so extracted data and logs cannot be committed accidentally.'
}
if ((Test-PathWithin -Candidate $archiveRootFull -Parent $workRootFull) -or
    (Test-PathWithin -Candidate $workRootFull -Parent $archiveRootFull)) {
    throw 'archiveRoot and workRoot must be separate, non-nested directories.'
}

$maxArchiveBytes = [long](Get-RequiredProperty -Object $acquisition -Name 'maxArchiveBytes' -Context 'acquisition')
$maxExpandedBytes = [long](Get-RequiredProperty -Object $acquisition -Name 'maxExpandedBytes' -Context 'acquisition')
$maxCompressionRatio = [double](Get-RequiredProperty -Object $acquisition -Name 'maxCompressionRatio' -Context 'acquisition')
$minimumFreeBytes = [long](Get-RequiredProperty -Object $acquisition -Name 'minimumFreeBytes' -Context 'acquisition')
$csvEntryMask = [string](Get-RequiredProperty -Object $acquisition -Name 'csvEntryMask' -Context 'acquisition')
if ($maxArchiveBytes -le 0 -or $maxExpandedBytes -le 0 -or $maxCompressionRatio -le 0 -or $minimumFreeBytes -lt 0) {
    throw 'Acquisition size, expansion, compression-ratio, and free-space limits are invalid.'
}

New-Item -ItemType Directory -Force -Path $archiveRootFull, $workRootFull | Out-Null
$downloadRoot = Join-Path $workRootFull 'downloads'
$extractRoot = Join-Path $workRootFull 'extracted'
$logRoot = Join-Path $workRootFull 'logs'
New-Item -ItemType Directory -Force -Path $downloadRoot, $extractRoot, $logRoot | Out-Null
$logPath = Join-Path $logRoot ('acquisition-{0:yyyyMMdd-HHmmss}-{1}.jsonl' -f [DateTime]::UtcNow, ([guid]::NewGuid().ToString('N').Substring(0, 8)))

function Write-AcquisitionEvent {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info',
        [hashtable]$Data
    )

    $event = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        level = $Level
        feedName = $feedName
        message = $Message
        host = [Environment]::MachineName
        processId = $PID
        data = $Data
    }
    ($event | ConvertTo-Json -Depth 6 -Compress) | Add-Content -LiteralPath $logPath -Encoding utf8NoBOM
    $color = if ($Level -eq 'Error') { 'Red' } elseif ($Level -eq 'Warn') { 'Yellow' } else { 'Gray' }
    Write-Host ('{0:HH:mm:ss} [{1,-5}] {2}' -f [DateTime]::Now, $Level.ToUpperInvariant(), $Message) -ForegroundColor $color
}

function Expand-VerifiedZipArtifact {
    param(
        [Parameter(Mandatory)][string]$DownloadedPath,
        [Parameter(Mandatory)][string]$OriginalFileName,
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][long]$SourceSizeBytes,
        [Parameter(Mandatory)][datetime]$SourceModifiedAtUtc
    )

    $partialPath = $DownloadedPath
    try {
        $partialFile = Get-Item -LiteralPath $partialPath
        if ($partialFile.Length -ne $SourceSizeBytes) {
            throw "Downloaded byte count $($partialFile.Length) does not match source byte count $SourceSizeBytes."
        }
        if ($partialFile.Length -gt $maxArchiveBytes) {
            throw "Archive size $($partialFile.Length) exceeds maxArchiveBytes $maxArchiveBytes."
        }

        $archiveHash = Get-Sha256Hex -Path $partialFile.FullName
        $safeArchiveName = Get-SafeFileName -Name $OriginalFileName
        $datePath = '{0:yyyy}\{0:MM}\{0:dd}' -f $SourceModifiedAtUtc.ToUniversalTime()
        $archiveDirectory = Join-Path (Join-Path $archiveRootFull $feedName) $datePath
        New-Item -ItemType Directory -Force -Path $archiveDirectory | Out-Null
        $archiveFileName = "$archiveHash-$safeArchiveName"
        $archivePath = Join-Path $archiveDirectory $archiveFileName

        if (Test-Path -LiteralPath $archivePath) {
            $existing = Get-Item -LiteralPath $archivePath
            if ($existing.Length -ne $partialFile.Length -or (Get-Sha256Hex -Path $archivePath) -ne $archiveHash) {
                throw "Existing archive path '$archivePath' does not contain the expected immutable bytes."
            }
            Remove-Item -LiteralPath $partialPath -Force
        }
        else {
            Move-Item -LiteralPath $partialPath -Destination $archivePath
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            $fileEntries = @($zip.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
            foreach ($entry in $fileEntries) {
                $normalized = $entry.FullName.Replace('\', '/')
                $segments = $normalized.Split('/', [StringSplitOptions]::RemoveEmptyEntries)
                if ($normalized.StartsWith('/') -or $normalized -match '^[A-Za-z]:' -or $segments -contains '..') {
                    throw "ZIP entry '$($entry.FullName)' contains an unsafe path."
                }
                if ($entry.Length -gt $maxExpandedBytes) {
                    throw "ZIP entry '$($entry.FullName)' exceeds maxExpandedBytes $maxExpandedBytes."
                }
                $ratio = if ($entry.CompressedLength -eq 0) {
                    if ($entry.Length -eq 0) { 1.0 } else { [double]::PositiveInfinity }
                }
                else {
                    $entry.Length / [double]$entry.CompressedLength
                }
                if ($ratio -gt $maxCompressionRatio) {
                    throw "ZIP entry '$($entry.FullName)' exceeds maxCompressionRatio $maxCompressionRatio."
                }
            }

            $csvEntries = @($fileEntries | Where-Object { $_.Name -like $csvEntryMask })
            if ($fileEntries.Count -ne 1 -or $csvEntries.Count -ne 1) {
                throw "ZIP must contain exactly one file matching '$csvEntryMask'; found $($fileEntries.Count) file(s) and $($csvEntries.Count) match(es)."
            }
            $csvEntry = $csvEntries[0]

            $driveRoot = [System.IO.Path]::GetPathRoot($workRootFull)
            $drive = [System.IO.DriveInfo]::new($driveRoot)
            $requiredFreeBytes = $csvEntry.Length + $minimumFreeBytes
            if ($drive.AvailableFreeSpace -lt $requiredFreeBytes) {
                throw "Work drive has $($drive.AvailableFreeSpace) free bytes but $requiredFreeBytes are required."
            }

            $csvDirectory = Join-Path (Join-Path $extractRoot $feedName) $archiveHash
            New-Item -ItemType Directory -Force -Path $csvDirectory | Out-Null
            $csvPath = Join-Path $csvDirectory (Get-SafeFileName -Name $csvEntry.Name)
            $csvHashAlgorithm = [System.Security.Cryptography.IncrementalHash]::CreateHash([System.Security.Cryptography.HashAlgorithmName]::SHA256)
            try {
                if (Test-Path -LiteralPath $csvPath) {
                    $existingCsv = Get-Item -LiteralPath $csvPath
                    if ($existingCsv.Length -ne $csvEntry.Length) {
                        throw "Existing extracted file '$csvPath' has an unexpected byte count."
                    }
                    $csvHash = Get-Sha256Hex -Path $csvPath
                }
                else {
                    $input = $csvEntry.Open()
                    $output = [System.IO.FileStream]::new($csvPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1048576)
                    try {
                        $buffer = [byte[]]::new(1048576)
                        while (($bytesRead = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
                            $csvHashAlgorithm.AppendData($buffer, 0, $bytesRead)
                            $output.Write($buffer, 0, $bytesRead)
                        }
                        $output.Flush($true)
                        $csvHash = [Convert]::ToHexString($csvHashAlgorithm.GetHashAndReset()).ToLowerInvariant()
                    }
                    finally {
                        $output.Dispose()
                        $input.Dispose()
                    }
                }
            }
            finally {
                $csvHashAlgorithm.Dispose()
            }

            $archiveRelativePath = [System.IO.Path]::GetRelativePath($archiveRootFull, $archivePath).Replace('\', '/')
            $manifest = [ordered]@{
                schemaVersion = 1
                feedName = $feedName
                remoteDirectory = $SourceDirectory
                remoteFileName = $OriginalFileName
                remoteSizeBytes = $SourceSizeBytes
                remoteModifiedAtUtc = $SourceModifiedAtUtc.ToUniversalTime().ToString('o')
                acquiredAtUtc = [DateTime]::UtcNow.ToString('o')
                archivePath = $archivePath
                archiveRelativePath = $archiveRelativePath
                archiveSha256 = $archiveHash
                archiveSizeBytes = (Get-Item -LiteralPath $archivePath).Length
                csvPath = $csvPath
                csvFileName = [System.IO.Path]::GetFileName($csvPath)
                csvSha256 = $csvHash
                csvSizeBytes = (Get-Item -LiteralPath $csvPath).Length
            }
            $manifestPath = "$csvPath.manifest.json"
            $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM
            (Get-Item -LiteralPath $archivePath).IsReadOnly = $true

            Write-AcquisitionEvent -Message "Archived and extracted $OriginalFileName." -Data @{
                archiveSha256 = $archiveHash
                csvSha256 = $csvHash
                csvSizeBytes = $manifest.csvSizeBytes
                manifestPath = $manifestPath
            }
            return [pscustomobject]@{
                ManifestPath = $manifestPath
                ArchivePath = $archivePath
                CsvPath = $csvPath
                ArchiveSha256 = $archiveHash
                CsvSha256 = $csvHash
            }
        }
        finally {
            $zip.Dispose()
        }
    }
    finally {
        if (Test-Path -LiteralPath $partialPath) {
            Remove-Item -LiteralPath $partialPath -Force
        }
    }
}

Write-AcquisitionEvent -Message 'Acquisition started.' -Data @{ mode = $PSCmdlet.ParameterSetName; logPath = $logPath }

if ($PSCmdlet.ParameterSetName -eq 'Local') {
    $localFile = Get-Item -LiteralPath $LocalZipPath
    if ($localFile.Extension -ne '.zip') {
        throw 'LocalZipPath must identify a ZIP file.'
    }
    $partialPath = Join-Path $downloadRoot (([guid]::NewGuid().ToString('N')) + '.partial')
    Copy-Item -LiteralPath $localFile.FullName -Destination $partialPath
    Expand-VerifiedZipArtifact `
        -DownloadedPath $partialPath `
        -OriginalFileName $localFile.Name `
        -SourceDirectory 'local' `
        -SourceSizeBytes $localFile.Length `
        -SourceModifiedAtUtc $localFile.LastWriteTimeUtc
    return
}

$sftp = Get-RequiredProperty -Object $config -Name 'sftp' -Context 'Acquisition config'
$hostName = [string](Get-RequiredProperty -Object $sftp -Name 'hostName' -Context 'sftp')
$remoteDirectory = [string](Get-RequiredProperty -Object $sftp -Name 'remoteDirectory' -Context 'sftp')
$fileMask = [string](Get-RequiredProperty -Object $sftp -Name 'fileMask' -Context 'sftp')
$hostKeyFingerprint = [string](Get-RequiredProperty -Object $sftp -Name 'sshHostKeyFingerprint' -Context 'sftp')
$authMode = [string](Get-RequiredProperty -Object $sftp -Name 'authMode' -Context 'sftp')
$portNumber = if ($sftp.PSObject.Properties.Name.Contains('portNumber')) { [int]$sftp.portNumber } else { 22 }
$minimumFileAgeSeconds = if ($sftp.PSObject.Properties.Name.Contains('minimumFileAgeSeconds')) { [int]$sftp.minimumFileAgeSeconds } else { 120 }
$stabilityCheckSeconds = if ($sftp.PSObject.Properties.Name.Contains('stabilityCheckSeconds')) { [int]$sftp.stabilityCheckSeconds } else { 5 }
if ($portNumber -lt 1 -or $portNumber -gt 65535 -or $minimumFileAgeSeconds -lt 0 -or $stabilityCheckSeconds -lt 1 -or $stabilityCheckSeconds -gt 60) {
    throw 'SFTP port, file-age, or stability-check settings are invalid.'
}
if ($hostKeyFingerprint -in @('*', 'acceptnew') -or $hostKeyFingerprint -match 'GiveUpSecurity') {
    throw 'An explicit verified SSH host-key fingerprint is required; insecure accept-any/accept-new policies are prohibited.'
}
if ($authMode -notin @('password', 'privateKey')) {
    throw "Unsupported sftp.authMode '$authMode'."
}

if (-not $SftpCredential) {
    $secretName = [string](Get-RequiredProperty -Object $sftp -Name 'credentialSecretName' -Context 'sftp')
    $vaultName = if ($sftp.PSObject.Properties.Name.Contains('credentialVault')) { [string]$sftp.credentialVault } else { $null }
    if (-not (Get-Module -ListAvailable -Name Microsoft.PowerShell.SecretManagement)) {
        throw 'Microsoft.PowerShell.SecretManagement is required to retrieve the SFTP credential.'
    }
    Import-Module Microsoft.PowerShell.SecretManagement
    $SftpCredential = if ([string]::IsNullOrWhiteSpace($vaultName)) {
        Get-Secret -Name $secretName
    }
    else {
        Get-Secret -Name $secretName -Vault $vaultName
    }
    if ($SftpCredential -isnot [pscredential]) {
        throw "Secret '$secretName' must contain a PSCredential object."
    }
}

if (-not $PSBoundParameters.ContainsKey('WinScpAssemblyPath')) {
    if ($sftp.PSObject.Properties.Name.Contains('winScpAssemblyPath') -and -not [string]::IsNullOrWhiteSpace($sftp.winScpAssemblyPath)) {
        $WinScpAssemblyPath = [string]$sftp.winScpAssemblyPath
    }
    elseif ($env:WINSCP_PATH) {
        $WinScpAssemblyPath = Join-Path $env:WINSCP_PATH 'netstandard2.0\WinSCPnet.dll'
    }
}
if ([string]::IsNullOrWhiteSpace($WinScpAssemblyPath) -or -not (Test-Path -LiteralPath $WinScpAssemblyPath)) {
    throw 'WinSCP .NET Standard assembly was not found. Set sftp.winScpAssemblyPath or -WinScpAssemblyPath to netstandard2.0\WinSCPnet.dll.'
}
Add-Type -Path (Get-FullPath -Path $WinScpAssemblyPath)

$sessionOptions = [WinSCP.SessionOptions]::new()
$sessionOptions.Protocol = [WinSCP.Protocol]::Sftp
$sessionOptions.HostName = $hostName
$sessionOptions.PortNumber = $portNumber
$sessionOptions.UserName = $SftpCredential.UserName
$sessionOptions.SshHostKeyFingerprint = $hostKeyFingerprint
if ($authMode -eq 'password') {
    $sessionOptions.SecurePassword = $SftpCredential.Password
}
else {
    $privateKeyPath = [string](Get-RequiredProperty -Object $sftp -Name 'privateKeyPath' -Context 'sftp')
    if (-not (Test-Path -LiteralPath $privateKeyPath)) {
        throw "Configured private key '$privateKeyPath' does not exist."
    }
    $sessionOptions.SshPrivateKeyPath = Get-FullPath -Path $privateKeyPath
    $sessionOptions.SecurePrivateKeyPassphrase = $SftpCredential.Password
}

$session = [WinSCP.Session]::new()
try {
    $assemblyDirectory = Split-Path -Parent (Get-FullPath -Path $WinScpAssemblyPath)
    $candidateExecutable = Join-Path (Split-Path -Parent $assemblyDirectory) 'WinSCP.exe'
    if (Test-Path -LiteralPath $candidateExecutable) {
        $session.ExecutablePath = $candidateExecutable
    }
    $session.Open($sessionOptions)
    Write-AcquisitionEvent -Message "Connected to pinned SFTP host $hostName."

    $firstListing = $session.ListDirectory($remoteDirectory)
    $nowUtc = [DateTime]::UtcNow
    $firstCandidates = @($firstListing.Files | Where-Object {
        -not $_.IsDirectory -and
        $_.Name -like $fileMask -and
        ($nowUtc - $_.LastWriteTime.ToUniversalTime()).TotalSeconds -ge $minimumFileAgeSeconds
    } | Sort-Object LastWriteTime, Name | Select-Object -First $MaxFiles)

    if ($firstCandidates.Count -eq 0) {
        Write-AcquisitionEvent -Message "No stable-age files matched '$fileMask'." -Level Warn
        return
    }

    Start-Sleep -Seconds $stabilityCheckSeconds
    $secondListing = $session.ListDirectory($remoteDirectory)
    $secondByName = @{}
    foreach ($remoteFile in $secondListing.Files) {
        if (-not $remoteFile.IsDirectory) {
            $secondByName[$remoteFile.Name] = $remoteFile
        }
    }

    $transferOptions = [WinSCP.TransferOptions]::new()
    $transferOptions.TransferMode = [WinSCP.TransferMode]::Binary
    foreach ($firstFile in $firstCandidates) {
        if (-not $secondByName.ContainsKey($firstFile.Name)) {
            Write-AcquisitionEvent -Message "$($firstFile.Name) disappeared during the stability check; skipped." -Level Warn
            continue
        }
        $secondFile = $secondByName[$firstFile.Name]
        if ($firstFile.Length -ne $secondFile.Length -or $firstFile.LastWriteTime -ne $secondFile.LastWriteTime) {
            Write-AcquisitionEvent -Message "$($firstFile.Name) changed during the stability check; skipped." -Level Warn
            continue
        }
        if ([System.IO.Path]::GetExtension($secondFile.Name) -ne '.zip') {
            Write-AcquisitionEvent -Message "$($secondFile.Name) is not a ZIP file; skipped." -Level Warn
            continue
        }

        $partialPath = Join-Path $downloadRoot (([guid]::NewGuid().ToString('N')) + '.partial')
        $remotePath = [WinSCP.RemotePath]::Combine($remoteDirectory, $secondFile.Name)
        Write-AcquisitionEvent -Message "Downloading $remotePath as a partial file." -Data @{ sizeBytes = $secondFile.Length }
        $result = $session.GetFiles($remotePath, $partialPath, $false, $transferOptions)
        $result.Check()

        Expand-VerifiedZipArtifact `
            -DownloadedPath $partialPath `
            -OriginalFileName $secondFile.Name `
            -SourceDirectory $remoteDirectory `
            -SourceSizeBytes $secondFile.Length `
            -SourceModifiedAtUtc $secondFile.LastWriteTime.ToUniversalTime()
    }
}
finally {
    $session.Dispose()
    Write-AcquisitionEvent -Message 'Acquisition finished.' -Data @{ logPath = $logPath }
}
