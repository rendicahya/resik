# Memory dump target.
#
#   memory-dumps  Disk Cleanup's own items "System error memory dump files"
#                 (*.dmp directly in %WINDIR%, such as MEMORY.DMP) and
#                 "System error minidump files" (*.dmp in %WINDIR%\Minidump),
#                 run through DiskCleanup.ps1. Windows writes them when it
#                 stops with a blue screen. Needs administrator rights;
#                 without them the target is report-only. Resik measures the
#                 *.dmp files directly in those two folders.

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
