# Microsoft Defender Antivirus target.
#
# Defender protects its own folders, and it has no command that deletes its
# leftover files, so Resik runs Disk Cleanup's "Microsoft Defender Antivirus"
# item (the "Windows Defender" key, whose Folder value lists LocalCopy and
# Support under %ProgramData%\Microsoft\Windows Defender) through
# DiskCleanup.ps1. Needs administrator rights; without them the target is
# report-only. Definitions, the engine (Platform), scan history, and
# quarantine are not touched; Defender manages those itself.

function Get-ResikDefenderDataRoot {
    # %ProgramData%\Microsoft\Windows Defender, as a function so tests can
    # point it at TestDrive.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path $env:ProgramData 'Microsoft\Windows Defender'
}

function Get-ResikDefenderHandlerName {
    'Windows Defender'
}

function Invoke-ResikDefenderDetection {
    Invoke-ResikDiskCleanupDetection -Name (Get-ResikDefenderHandlerName) -Label 'Microsoft Defender Antivirus'
}

function Invoke-ResikDefenderAnalysis {
    Invoke-ResikDiskCleanupAnalysis -Name (Get-ResikDefenderHandlerName) -Root (Get-ResikDefenderDataRoot) `
        -EmptyDetails 'Defender has no support files or local copies to clean.'
}

function Invoke-ResikDefenderCleanup {
    Invoke-ResikDiskCleanupItem -Name (Get-ResikDefenderHandlerName) -Label 'Microsoft Defender Antivirus' `
        -Root (Get-ResikDefenderDataRoot)
}

function New-ResikDefenderTarget {
    # Without administrator rights the target has no Clean, so it is shown as
    # report-only with the reason instead of failing during cleanup.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    $clean = if (Test-ResikAdministrator) { { Invoke-ResikDefenderCleanup } } else { $null }
    New-ResikTarget -Id 'defender' -Name 'Microsoft Defender Antivirus files' -Category Windows -RiskLevel Low `
        -Description ('Deletes the non-critical files Microsoft Defender Antivirus keeps (its Support and LocalCopy ' +
            'folders) with Disk Cleanup''s own item, by running "cleanmgr.exe /sagerun". Definitions, scan history, ' +
            'and quarantine are kept. Disk Cleanup shows a small progress window. Needs administrator rights.') `
        -Detect { Invoke-ResikDefenderDetection } `
        -Analyze { Invoke-ResikDefenderAnalysis } `
        -Clean $clean
}
