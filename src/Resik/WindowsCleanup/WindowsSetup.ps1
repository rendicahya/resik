# Previous Windows installation and Windows setup leftovers.
#
# Both run Disk Cleanup's own items through DiskCleanup.ps1 (handler
# setupcln.dll, Windows 10 and 11):
#   windows-old          "Previous Installations", shown as "Previous Windows
#                        installation(s)": the Windows.old folder a feature
#                        update or reinstall leaves on the system drive.
#                        Afterwards Windows can no longer go back to the
#                        previous version, and files left in Windows.old are
#                        gone, so the target is High risk and -ExplicitOnly.
#                        Resik measures %SystemDrive%\Windows.old only.
#   windows-setup-files  "Temporary Setup Files", shown as "Temporary Windows
#                        installation files", and "Windows Upgrade Log Files".
#                        Windows does not say which folders these items clean,
#                        so no estimate is shown; the result is the change in
#                        free space on the system drive.
# Both need administrator rights; without them the targets are report-only.

function Get-ResikPreviousWindowsPath {
    # %SystemDrive%\Windows.old, as a function so tests can point it at
    # TestDrive.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path ($env:SystemDrive + '\') 'Windows.old'
}

function Get-ResikPreviousWindowsHandlerName { 'Previous Installations' }

function Get-ResikPreviousWindowsMeasurePath {
    # Windows.old when it is a real folder (not a link), else nothing.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $path = Get-ResikPreviousWindowsPath
    if (Test-ResikRealFolder -Path $path -Base (Split-Path -Parent $path)) { $path }
}

function New-ResikPreviousWindowsTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    $clean = if (Test-ResikAdministrator) {
        {
            Invoke-ResikDiskCleanupItem -Name (Get-ResikPreviousWindowsHandlerName) -Label 'previous Windows installation' `
                -MeasurePath @(Get-ResikPreviousWindowsMeasurePath)
        }
    }
    else { $null }
    New-ResikTarget -Id 'windows-old' -Name 'Previous Windows installation (Windows.old)' -Category Windows `
        -RiskLevel High -ExplicitOnly `
        -Description ('Deletes the previous Windows installation that a feature update or reinstall kept in ' +
            'Windows.old, with Disk Cleanup''s own item, by running "cleanmgr.exe /sagerun". Afterwards you can ' +
            'no longer go back to the previous version of Windows, and any of your files still in Windows.old ' +
            'are deleted. Never chosen by --all or "select all". Needs administrator rights.') `
        -Detect { Invoke-ResikDiskCleanupDetection -Name (Get-ResikPreviousWindowsHandlerName) -Label 'previous Windows installation' } `
        -Analyze {
            Invoke-ResikDiskCleanupAnalysis -Name (Get-ResikPreviousWindowsHandlerName) `
                -MeasurePath @(Get-ResikPreviousWindowsMeasurePath) -EmptyDetails 'There is no previous Windows installation.'
        } `
        -Clean $clean
}

function Get-ResikWindowsSetupHandlerName { 'Temporary Setup Files', 'Windows Upgrade Log Files' }

function New-ResikWindowsSetupTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    $clean = if (Test-ResikAdministrator) {
        { Invoke-ResikDiskCleanupItem -Name @(Get-ResikWindowsSetupHandlerName) -Label 'Windows setup files' }
    }
    else { $null }
    New-ResikTarget -Id 'windows-setup-files' -Name 'Temporary Windows installation files and upgrade logs' `
        -Category Windows -RiskLevel Low `
        -Description ('Deletes the files Windows setup left after installing or upgrading Windows, and the upgrade ' +
            'logs, with Disk Cleanup''s own items, by running "cleanmgr.exe /sagerun". The logs only help when ' +
            'troubleshooting a failed upgrade. Windows does not say which files these items delete, so the result ' +
            'is the change in free space. Disk Cleanup shows a small progress window. Needs administrator rights.') `
        -Detect { Invoke-ResikDiskCleanupDetection -Name @(Get-ResikWindowsSetupHandlerName) -Label 'Windows setup files' } `
        -Analyze {
            Invoke-ResikDiskCleanupAnalysis -Name @(Get-ResikWindowsSetupHandlerName) -Unmeasured `
                -EmptyDetails 'There are no Windows setup files to clean.' `
                -UnmeasuredDetails 'Windows does not say which files these items delete, so the size is shown only after cleaning, as the change in free space'
        } `
        -Clean $clean
}
