# Memory dump targets.
#
#   memory-dumps  Disk Cleanup's own items "System error memory dump files"
#                 (*.dmp directly in %WINDIR%, such as MEMORY.DMP) and
#                 "System error minidump files" (*.dmp in %WINDIR%\Minidump),
#                 run through DiskCleanup.ps1. Windows writes them when it
#                 stops with a blue screen. Needs administrator rights;
#                 without them the target is report-only. Resik measures the
#                 *.dmp files directly in those two folders.
#   crash-dumps   App crash dumps Windows Error Reporting keeps in the user's
#                 %LOCALAPPDATA%\CrashDumps, its documented default LocalDumps
#                 folder (https://learn.microsoft.com/windows/win32/wer/collecting-user-mode-dumps).
#                 There is no command for them, so Resik deletes the *.dmp
#                 files directly in that folder; no administrator rights are
#                 needed. A DumpFolder configured elsewhere is not cleaned.

function Get-ResikMemoryDumpRoot {
    # %WINDIR%, as a function so tests can point it at TestDrive.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $env:WINDIR
}

function Get-ResikMemoryDumpHandlerName { 'System error memory dump files', 'System error minidump files' }

function Get-ResikMemoryDumpFile {
    # The *.dmp files directly in %WINDIR% and in a real %WINDIR%\Minidump;
    # links are left out.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $root = Get-ResikMemoryDumpRoot
    $reparse = [System.IO.FileAttributes]::ReparsePoint
    foreach ($folder in @($root, (Join-Path $root 'Minidump'))) {
        if (-not (Test-ResikRealFolder -Path $folder -Base $root)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter '*.dmp' -File -Force -ErrorAction SilentlyContinue)) {
            if (-not ($file.Attributes -band $reparse)) { $file.FullName }
        }
    }
}

function New-ResikMemoryDumpTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    $clean = if (Test-ResikAdministrator) {
        {
            Invoke-ResikDiskCleanupItem -Name @(Get-ResikMemoryDumpHandlerName) -Label 'system memory dump' `
                -MeasurePath @(Get-ResikMemoryDumpFile)
        }
    }
    else { $null }
    New-ResikTarget -Id 'memory-dumps' -Name 'System memory dump files' -Category Windows -RiskLevel Low `
        -Description ('Deletes the memory dumps Windows writes when it stops with a blue screen (MEMORY.DMP and ' +
            'the Minidump folder in %WINDIR%), with Disk Cleanup''s own items, by running "cleanmgr.exe /sagerun". ' +
            'They are only needed to find out why Windows crashed. Disk Cleanup shows a small progress window. ' +
            'Needs administrator rights.') `
        -Detect { Invoke-ResikDiskCleanupDetection -Name @(Get-ResikMemoryDumpHandlerName) -Label 'system memory dump' } `
        -Analyze {
            Invoke-ResikDiskCleanupAnalysis -Name @(Get-ResikMemoryDumpHandlerName) -MeasurePath @(Get-ResikMemoryDumpFile) `
                -EmptyDetails 'There are no system memory dumps.'
        } `
        -Clean $clean
}

function Get-ResikCrashDumpPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Get-ResikLocalAppDataPath) 'CrashDumps'
}

function Get-ResikCheckedCrashDumpPath {
    # The CrashDumps folder after the safety checks; $null when it does not
    # exist, and an error when it is a link.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $path = Get-ResikCrashDumpPath
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $null }
    $issue = Get-ResikPathSafetyIssue -Path $path
    if ($issue) { throw "Refusing to clean app crash dumps: $issue" }
    if (-not (Test-ResikRealFolder -Path $path -Base (Split-Path -Parent $path))) {
        throw "Refusing to clean app crash dumps: $path is a link."
    }
    $path
}

function Invoke-ResikCrashDumpAnalysis {
    $path = Get-ResikCheckedCrashDumpPath
    if ($null -eq $path) { return [pscustomobject]@{ EstimatedBytes = [long]0; Details = 'There are no app crash dumps.' } }
    $size = Measure-ResikDirectoryContent -Path $path -Filter '*.dmp'
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = "$(Join-Path $path '*.dmp') ($($size.Files) files)" }
}

function Invoke-ResikCrashDumpCleanup {
    $path = Get-ResikCheckedCrashDumpPath
    if ($null -eq $path -or (Measure-ResikDirectoryContent -Path $path -Filter '*.dmp').Files -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'There are no app crash dumps; nothing to clean.' }
    }
    Invoke-ResikMeasuredDeletion -Path $path -Filter '*.dmp' -InUseHint 'A dump that is still being written is kept.'
}

function New-ResikCrashDumpTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'crash-dumps' -Name 'App crash dumps' -Category Windows -RiskLevel Low `
        -Description ('Deletes the crash dumps of apps that Windows Error Reporting saved in ' +
            '%LOCALAPPDATA%\CrashDumps (*.dmp files). They are only needed to find out why an app crashed.') `
        -Detect {
            $path = Get-ResikCrashDumpPath
            if (Test-Path -LiteralPath $path -PathType Container) { [pscustomobject]@{ Available = $true; Details = $path } }
            else { [pscustomobject]@{ Available = $false; Details = "No crash dump folder at $path." } }
        } `
        -Analyze { Invoke-ResikCrashDumpAnalysis } `
        -Clean { Invoke-ResikCrashDumpCleanup }
}
