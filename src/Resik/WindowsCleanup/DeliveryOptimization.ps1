# Delivery Optimization cache target
# (https://learn.microsoft.com/windows/deployment/do/waas-delivery-optimization-monitor).
#
# Delivery Optimization keeps the Windows Update, Microsoft Store and Office
# files it downloaded so it can share them with other PCs. Windows' own
# DeliveryOptimization module (Windows 10 1903 and later; checked against
# module version 1.0.3.0) provides:
#   Get-DeliveryOptimizationStatus      lists the cached files (read-only)
#   Delete-DeliveryOptimizationCache -Force
# The delete cmdlet keeps pinned files unless -IncludePinnedFiles is passed,
# which Resik never does, so the estimate counts only files that are not
# pinned. Cleanup is skipped while a file is still downloading, so an update
# in progress is not interrupted. Neither cmdlet needs administrator rights.
# The delete cmdlet prints its own messages with Write-Host; they are
# discarded so they cannot garble the spinner.

function Test-ResikDeliveryOptimizationAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $null -ne (Get-Command -Name 'Get-DeliveryOptimizationStatus' -ErrorAction SilentlyContinue) -and
    $null -ne (Get-Command -Name 'Delete-DeliveryOptimizationCache' -ErrorAction SilentlyContinue)
}

function Get-ResikDeliveryOptimizationFile {
    # Emits one record per file in the cache.
    [CmdletBinding()]
    param()
    foreach ($file in @(Get-DeliveryOptimizationStatus -ErrorAction Stop)) {
        [pscustomobject]@{
            Bytes       = [long](Get-ResikOptionalProperty $file 'FileSizeInCache')
            Pinned      = [bool](Get-ResikOptionalProperty $file 'IsPinned')
            Downloading = "$(Get-ResikOptionalProperty $file 'Status')" -eq 'Downloading'
        }
    }
}

function Get-ResikDeliveryOptimizationDrive {
    # The root of the drive that holds the cache, for the free-space reading;
    # the system drive when Windows does not say.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $folder = $null
    try { $folder = (Get-DOConfig -Verbose -ErrorAction Stop 4>$null).WorkingDirectory } catch { $folder = $null }
    if ($folder -and [IO.Path]::IsPathRooted("$folder")) { return [IO.Path]::GetPathRoot("$folder") }
    $env:SystemDrive + '\'
}

function Clear-ResikDeliveryOptimizationCache {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('Delivery Optimization cache', 'Delete')) {
        Delete-DeliveryOptimizationCache -Force -ErrorAction Stop 6>$null
    }
}

function Measure-ResikDeliveryOptimizationCache {
    param([object[]] $Files)
    $removable = @($Files | Where-Object { -not $_.Pinned })
    $bytes = [long]0
    foreach ($file in $removable) { $bytes += $file.Bytes }
    [pscustomobject]@{
        Bytes       = $bytes
        Files       = $removable.Count
        Pinned      = @($Files | Where-Object { $_.Pinned }).Count
        Downloading = @($removable | Where-Object { $_.Downloading }).Count
    }
}

function Invoke-ResikDeliveryOptimizationDetection {
    if (-not (Test-ResikDeliveryOptimizationAvailable)) {
        return [pscustomobject]@{ Available = $false; Details = 'The DeliveryOptimization PowerShell module was not found.' }
    }
    [pscustomobject]@{ Available = $true; Details = 'Delivery Optimization' }
}

function Invoke-ResikDeliveryOptimizationAnalysis {
    $cache = Measure-ResikDeliveryOptimizationCache -Files @(Get-ResikDeliveryOptimizationFile)
    $details = "$($cache.Files) file(s) in the Delivery Optimization cache"
    if ($cache.Pinned -gt 0) { $details += "; $($cache.Pinned) pinned file(s) are kept" }
    if ($cache.Downloading -gt 0) { $details += "; $($cache.Downloading) file(s) are still downloading, so cleanup will wait" }
    [pscustomobject]@{ EstimatedBytes = $cache.Bytes; Details = $details }
}

function Invoke-ResikDeliveryOptimizationCleanup {
    $before = Measure-ResikDeliveryOptimizationCache -Files @(Get-ResikDeliveryOptimizationFile)
    if ($before.Files -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'The Delivery Optimization cache is already empty.' }
    }
    if ($before.Downloading -gt 0) {
        return [pscustomobject]@{
            Status  = 'Skipped'
            Details = 'Windows is still downloading through Delivery Optimization; try again when the download finishes.'
        }
    }

    $freeAt = Get-ResikDeliveryOptimizationDrive
    $freeBefore = Get-ResikFreeSpace -Path $freeAt
    Write-Host 'Running: Delete-DeliveryOptimizationCache -Force'

    $failure = $null
    $spinner = Start-ResikSpinner -Message 'Clearing the Delivery Optimization cache'
    try {
        try { Clear-ResikDeliveryOptimizationCache -Confirm:$false }
        catch { $failure = $_.Exception.Message }
        Set-ResikSpinnerMessage -Spinner $spinner -Message 'Measuring what was removed'
        $after = Measure-ResikDeliveryOptimizationCache -Files @(Get-ResikDeliveryOptimizationFile)
        $freeAfter = Get-ResikFreeSpace -Path $freeAt
    }
    finally {
        Stop-ResikSpinner -Spinner $spinner
    }

    $freeChange = if ($null -ne $freeBefore -and $null -ne $freeAfter) { $freeAfter - $freeBefore } else { $null }
    if ($after.Files -eq 0) {
        $status = 'Success'
        $details = "Deleted $($before.Files) file(s) from the Delivery Optimization cache."
        if ($after.Pinned -gt 0) { $details += " Kept $($after.Pinned) pinned file(s)." }
    }
    else {
        $status = if ($after.Files -lt $before.Files) { 'PartialSuccess' } else { 'Failed' }
        $details = "$($after.Files) file(s) are still in the Delivery Optimization cache"
        if ($failure) { $details += ": $failure" }
    }
    [pscustomobject]@{
        Status               = $status
        Details              = $details
        MeasuredBytes        = $before.Bytes - $after.Bytes
        FreeSpaceChangeBytes = $freeChange
    }
}

function New-ResikDeliveryOptimizationTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'delivery-optimization' -Name 'Delivery Optimization cache' -Category Windows -RiskLevel Low `
        -Description ('Deletes the Windows Update, Microsoft Store, and Office downloads that Delivery Optimization ' +
            'keeps to share with other PCs, by running "Delete-DeliveryOptimizationCache -Force". Pinned files ' +
            'are kept. Windows downloads files again if it needs them.') `
        -Detect { Invoke-ResikDeliveryOptimizationDetection } `
        -Analyze { Invoke-ResikDeliveryOptimizationAnalysis } `
        -Clean { Invoke-ResikDeliveryOptimizationCleanup }
}
