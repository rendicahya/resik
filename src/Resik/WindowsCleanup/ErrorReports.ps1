# Windows error reports target.
#
# Runs Disk Cleanup's "Windows error reports and feedback diagnostics" item
# (the "Windows Error Reporting Files" key, whose Folder value is
# %ProgramData%\Microsoft\Windows\WER; Disk Cleanup runs its
# "wermgr.exe -purgestores" first) through DiskCleanup.ps1. These are crash
# and problem reports Windows keeps to send to Microsoft or for
# troubleshooting. Needs administrator rights; without them the target is
# report-only. System memory dumps and the Feedback Hub archive are separate
# Disk Cleanup items and are not touched.

function Get-ResikErrorReportRoot {
    # %ProgramData%\Microsoft\Windows\WER, as a function so tests can point
    # it at TestDrive.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path $env:ProgramData 'Microsoft\Windows\WER'
}

function Get-ResikErrorReportHandlerName {
    'Windows Error Reporting Files'
}

function Get-ResikErrorReportLabel {
    'Windows error reports and feedback diagnostics'
}

function New-ResikErrorReportTarget {
    # Without administrator rights the target has no Clean, so it is shown as
    # report-only with the reason instead of failing during cleanup.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    $clean = if (Test-ResikAdministrator) {
        {
            Invoke-ResikDiskCleanupItem -Name (Get-ResikErrorReportHandlerName) -Label (Get-ResikErrorReportLabel) `
                -Root (Get-ResikErrorReportRoot)
        }
    }
    else { $null }
    New-ResikTarget -Id 'error-reports' -Name 'Windows error reports and feedback diagnostics' -Category Windows `
        -RiskLevel Low `
        -Description ('Deletes the crash and problem reports Windows keeps in %ProgramData%\Microsoft\Windows\WER, ' +
            'with Disk Cleanup''s own item, by running "cleanmgr.exe /sagerun". Reports that were not sent ' +
            'cannot be sent afterwards. Disk Cleanup shows a small progress window. Needs administrator rights.') `
        -Detect { Invoke-ResikDiskCleanupDetection -Name (Get-ResikErrorReportHandlerName) -Label (Get-ResikErrorReportLabel) } `
        -Analyze {
            Invoke-ResikDiskCleanupAnalysis -Name (Get-ResikErrorReportHandlerName) -Root (Get-ResikErrorReportRoot) `
                -EmptyDetails 'There are no Windows error reports to clean.'
        } `
        -Clean $clean
}
