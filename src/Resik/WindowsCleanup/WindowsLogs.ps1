# Windows log files target (windows-logs).
#
# Windows has no command for removing its old logs, so Resik deletes files
# itself, only these, all in %WINDIR%\Logs:
#   CBS\CbsPersist_*.log, CbsPersist_*.cab   CBS.log after Windows rotated it
#                                             (older than 1 day); the current
#                                             CBS.log is kept
#   DISM\*.log, *.bak                         older than 7 days
#   WindowsUpdate\*.etl                       older than 7 days
# These are only diagnostic history; Windows writes new ones. Other folders
# (MeasuredBoot, which Windows uses for device health checks, among them) are
# not touched. Deleting needs administrator rights: without them the target is
# report-only, like windows-update, and Resik never elevates itself.

function Get-ResikWindowsLogRoot {
    # %WINDIR%\Logs, as a function so tests can point it at TestDrive.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path ([Environment]::GetFolderPath('Windows')) 'Logs'
}

function Get-ResikWindowsLogLocation {
    [CmdletBinding()]
    param()
    $root = Get-ResikWindowsLogRoot
    $issue = Get-ResikPathSafetyIssue -Path $root
    if ($issue) { throw "Refusing to clean Windows logs: $issue" }
    $now = Get-Date
    $places = @(
        [pscustomobject]@{ Name = 'CBS'; Include = @('CbsPersist_*.log', 'CbsPersist_*.cab'); Before = $now.AddDays(-1) }
        [pscustomobject]@{ Name = 'DISM'; Include = @('*.log', '*.bak'); Before = $now.AddDays(-7) }
        [pscustomobject]@{ Name = 'WindowsUpdate'; Include = @('*.etl'); Before = $now.AddDays(-7) }
    )
    foreach ($place in $places) {
        $path = Join-Path $root $place.Name
        if (Test-ResikRealFolder -Path $path -Base $root) {
            New-ResikAgedFileLocation -Path $path -Before $place.Before -Include $place.Include
        }
    }
}

function Invoke-ResikWindowsLogDetection {
    $root = Get-ResikWindowsLogRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return [pscustomobject]@{ Available = $false; Details = "No Windows log folder at $root." }
    }
    [pscustomobject]@{ Available = $true; Details = $root }
}

function Invoke-ResikWindowsLogAnalysis {
    $locations = @(Get-ResikWindowsLogLocation)
    if ($locations.Count -eq 0) {
        return [pscustomobject]@{ EstimatedBytes = 0; Details = "No old logs in $(Get-ResikWindowsLogRoot)." }
    }
    $size = Measure-ResikAgedFileLocation -Location $locations
    $details = "$($size.Files) old log file(s) in $(Get-ResikWindowsLogRoot) (CBS, DISM, WindowsUpdate)"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    if (-not (Test-ResikAdministrator)) {
        $details += '. Needs administrator rights. To clean it, run Resik in a terminal opened with "Run as administrator"'
    }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikWindowsLogCleanup {
    if (-not (Test-ResikAdministrator)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'Needs administrator rights; nothing was changed.' }
    }
    $locations = @(Get-ResikWindowsLogLocation)
    if ($locations.Count -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'No old Windows logs; nothing to clean.' }
    }
    Invoke-ResikMeasuredAgedDeletion -Location $locations -Label 'the Windows logs' `
        -InUseHint 'Windows was still writing them.'
}

function New-ResikWindowsLogTarget {
    # Without administrator rights the target has no Clean, so it is shown as
    # report-only with the reason instead of failing during cleanup.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    $clean = if (Test-ResikAdministrator) { { Invoke-ResikWindowsLogCleanup } } else { $null }
    New-ResikTarget -Id 'windows-logs' -Name 'Windows log files' -Category Windows -RiskLevel Low `
        -Description ('Deletes old Windows servicing and update logs in %WINDIR%\Logs: rotated CBS logs ' +
            '(CbsPersist_*), and DISM logs and Windows Update traces older than 7 days. They are only ' +
            'troubleshooting history; current logs are kept. Needs administrator rights.') `
        -Detect { Invoke-ResikWindowsLogDetection } `
        -Analyze { Invoke-ResikWindowsLogAnalysis } `
        -Clean $clean
}
