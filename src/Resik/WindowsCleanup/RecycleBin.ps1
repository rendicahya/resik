# Recycle Bin target.
#
# Empties the Recycle Bin with PowerShell's own Clear-RecycleBin cmdlet
# (Microsoft.PowerShell.Management, in Windows PowerShell 5.1 and PowerShell 7
# on Windows), which asks Windows to empty the bin of every drive. Analysis
# reads each drive's <drive>:\$Recycle.Bin\<your SID> folder: deleted items are
# stored there as $R... files or folders, each with a $I... file holding its
# original name, so only names starting with "$" are counted (not desktop.ini).
# Only your own Recycle Bin is measured and emptied.
# Deleted files cannot be recovered afterwards, so the target is High risk and
# is never chosen by --all or "select all".

function Get-ResikRecycleBinFolder {
    # Emits <drive>:\$Recycle.Bin\<SID> for each ready local or removable
    # drive that has one.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -notin @([System.IO.DriveType]::Fixed, [System.IO.DriveType]::Removable)) { continue }
        if (-not $drive.IsReady) { continue }
        $folder = Join-Path $drive.RootDirectory.FullName "`$Recycle.Bin\$sid"
        if (Test-Path -LiteralPath $folder -PathType Container) { $folder }
    }
}

function Measure-ResikRecycleBin {
    [CmdletBinding()]
    param()

    $bytes = [long]0
    $files = 0
    $unreadable = 0
    foreach ($folder in @(Get-ResikRecycleBinFolder)) {
        $size = Measure-ResikDirectoryContent -Path $folder -Filter '$*'
        $bytes += $size.Bytes
        $files += $size.Files
        $unreadable += $size.Unreadable
    }
    [pscustomobject]@{ Bytes = $bytes; Files = $files; Unreadable = $unreadable }
}

function Clear-ResikRecycleBin {
    # Empties the Recycle Bin of every drive without Windows' own prompt;
    # Resik has already asked.
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('Recycle Bin', 'Empty')) {
        Clear-RecycleBin -Force -ErrorAction Stop
    }
}

function Invoke-ResikRecycleBinAnalysis {
    $size = Measure-ResikRecycleBin
    $details = "$($size.Files) file(s) in your Recycle Bin; they cannot be recovered after cleaning"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikRecycleBinCleanup {
    $before = Measure-ResikRecycleBin
    if ($before.Files -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'The Recycle Bin is already empty.' }
    }
    $freeAt = $env:SystemDrive + '\'
    $freeBefore = Get-ResikFreeSpace -Path $freeAt
    Write-Host 'Running: Clear-RecycleBin -Force'

    $failure = $null
    $spinner = Start-ResikSpinner -Message 'Emptying the Recycle Bin'
    try {
        try { Clear-ResikRecycleBin -Confirm:$false }
        catch { $failure = $_.Exception.Message }
        Set-ResikSpinnerMessage -Spinner $spinner -Message 'Measuring what was removed'
        $after = Measure-ResikRecycleBin
        $freeAfter = Get-ResikFreeSpace -Path $freeAt
    }
    finally {
        Stop-ResikSpinner -Spinner $spinner
    }

    $measured = if ($before.Unreadable -eq 0 -and $after.Unreadable -eq 0) { $before.Bytes - $after.Bytes } else { $null }
    # Free space is read on the system drive only; items on other drives are
    # counted in the measured reduction.
    $freeChange = if ($null -ne $freeBefore -and $null -ne $freeAfter) { $freeAfter - $freeBefore } else { $null }

    if ($after.Files -eq 0) {
        $status = 'Success'
        $details = 'Emptied the Recycle Bin.'
    }
    else {
        $status = if ($after.Files -lt $before.Files) { 'PartialSuccess' } else { 'Failed' }
        $details = "$($after.Files) file(s) are still in the Recycle Bin"
        if ($failure) { $details += ": $failure" }
    }
    [pscustomobject]@{
        Status               = $status
        Details              = $details
        MeasuredBytes        = $measured
        FreeSpaceChangeBytes = $freeChange
    }
}

function New-ResikRecycleBinTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'recycle-bin' -Name 'Recycle Bin' -Category Windows -RiskLevel High -ExplicitOnly `
        -Description ('Empties your Recycle Bin on every drive with Clear-RecycleBin. The deleted files in it ' +
            'are gone for good and cannot be restored. Never chosen by --all or "select all".') `
        -Detect { [pscustomobject]@{ Available = $true; Details = 'Recycle Bin' } } `
        -Analyze { Invoke-ResikRecycleBinAnalysis } `
        -Clean { Invoke-ResikRecycleBinCleanup }
}
