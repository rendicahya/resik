# Windows Update cleanup target
# (https://learn.microsoft.com/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder).
#
# Uses Windows' own servicing tool:
#   Dism.exe /Online /Cleanup-Image /StartComponentCleanup
# which removes the component-store copies of updates that newer updates have
# replaced; Disk Cleanup's "Windows Update Cleanup" does the same. /ResetBase
# is never passed, so installed updates can still be uninstalled. DISM needs
# administrator rights and Resik never elevates, so without them the target
# is report-only. DISM has no preview of what it will remove (the read-only
# /AnalyzeComponentStore takes minutes and its output is localized), so no
# estimate is shown; the result is measured as the change in free space on the
# system drive. SoftwareDistribution\Download is not touched.

function Test-ResikAdministrator {
    # True when Resik runs elevated.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ResikDismPath {
    # The 64-bit Dism.exe, also from a 32-bit PowerShell on 64-bit Windows.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $system = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        Join-Path $env:SystemRoot 'Sysnative'
    }
    else {
        [Environment]::SystemDirectory
    }
    Join-Path $system 'Dism.exe'
}

function Get-ResikWindowsUpdateArgument {
    @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
}

function Invoke-ResikWindowsUpdateDetection {
    $dism = Get-ResikDismPath
    if (-not (Test-Path -LiteralPath $dism -PathType Leaf)) {
        return [pscustomobject]@{ Available = $false; Details = "Dism.exe was not found at $dism." }
    }
    [pscustomobject]@{ Available = $true; Details = $dism }
}

function Invoke-ResikWindowsUpdateAnalysis {
    if (-not (Test-ResikAdministrator)) {
        return [pscustomobject]@{
            EstimatedBytes = $null
            Details        = 'Needs administrator rights. To clean it, run Resik in a terminal opened with "Run as administrator".'
        }
    }
    [pscustomobject]@{
        EstimatedBytes = $null
        Details        = 'Windows decides what to remove, so the size cannot be previewed. It can take 10 minutes or more.'
    }
}

function Invoke-ResikWindowsUpdateCleanup {
    if (-not (Test-ResikAdministrator)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'Needs administrator rights; nothing was changed.' }
    }
    $dism = Get-ResikDismPath
    if (-not (Test-Path -LiteralPath $dism -PathType Leaf)) { throw "Dism.exe was not found at $dism." }
    Invoke-ResikMeasuredCommand -FilePath $dism -ArgumentList (Get-ResikWindowsUpdateArgument) `
        -FreeSpacePath ($env:SystemDrive + '\') -TimeoutSeconds 7200
}

function New-ResikWindowsUpdateTarget {
    # Without administrator rights the target has no Clean, so it is shown as
    # report-only with the reason instead of failing during cleanup.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    $clean = if (Test-ResikAdministrator) { { Invoke-ResikWindowsUpdateCleanup } } else { $null }
    New-ResikTarget -Id 'windows-update' -Name 'Windows Update cleanup' -Category Windows -RiskLevel Medium `
        -Description ('Removes old copies of Windows components that newer updates replaced, by running ' +
            '"Dism.exe /Online /Cleanup-Image /StartComponentCleanup". Installed updates can still be ' +
            'uninstalled. Needs administrator rights.') `
        -Detect { Invoke-ResikWindowsUpdateDetection } `
        -Analyze { Invoke-ResikWindowsUpdateAnalysis } `
        -Clean $clean
}
