# Cleanup orchestration.
#
# Cleanup runs only after analysis and confirmation (see Invoke-ResikCli). Each
# target's Clean scriptblock runs in isolation: a failure in one target produces
# a Failed result for that target and never stops the rest.

function Measure-ResikPathSet {
    # Total size of several directories; a missing directory counts as zero.
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]] $Path = @()
    )

    $bytes = [long]0
    $files = 0
    $unreadable = 0
    foreach ($item in $Path) {
        if (-not (Test-Path -LiteralPath $item -PathType Container)) { continue }
        $size = Measure-ResikDirectory -Path $item
        $bytes += $size.Bytes
        $files += $size.Files
        $unreadable += $size.Unreadable
    }
    [pscustomobject]@{ Bytes = $bytes; Files = $files; Unreadable = $unreadable }
}

function Invoke-ResikMeasuredCommand {
    <#
    .SYNOPSIS
        Runs a tool's own cleanup command and measures its effect.
    .DESCRIPTION
        Measures MeasurePath before and after the command, and the free space
        on the drive of the first MeasurePath (or FreeSpacePath). Returns an
        outcome for a target's Clean scriptblock. A failed command that still
        removed something is PartialSuccess. Tools that report success but
        leave files behind (Scoop ignores files it cannot delete) are also
        PartialSuccess when ExpectEmpty is set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [AllowEmptyCollection()]
        [string[]] $ArgumentList = @(),

        [AllowEmptyCollection()]
        [string[]] $MeasurePath = @(),

        [string] $FreeSpacePath = '',

        [int] $TimeoutSeconds = 1800,

        [switch] $ExpectEmpty
    )

    $freeSpaceAt = if ($FreeSpacePath) { $FreeSpacePath } elseif ($MeasurePath.Count -gt 0) { $MeasurePath[0] } else { '' }
    $canMeasure = $MeasurePath.Count -gt 0
    $display = (@((Split-Path -Leaf $FilePath)) + @($ArgumentList)) -join ' '
    Write-Host "Running: $display (press Ctrl+C to stop)"

    # Nothing may write to the console while the spinner runs.
    $spinner = Start-ResikSpinner -Message 'Measuring before cleaning'
    try {
        $before = if ($canMeasure) { Measure-ResikPathSet -Path $MeasurePath } else { $null }
        $freeBefore = if ($freeSpaceAt) { Get-ResikFreeSpace -Path $freeSpaceAt } else { $null }

        Set-ResikSpinnerMessage -Spinner $spinner -Message "Waiting for $display"
        $run = Invoke-ResikNativeCommand -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds

        Set-ResikSpinnerMessage -Spinner $spinner -Message 'Measuring what was removed'
        $after = if ($canMeasure) { Measure-ResikPathSet -Path $MeasurePath } else { $null }
        $freeAfter = if ($freeSpaceAt) { Get-ResikFreeSpace -Path $freeSpaceAt } else { $null }
    }
    finally {
        Stop-ResikSpinner -Spinner $spinner
    }

    $measured = $null
    if ($canMeasure -and $before.Unreadable -eq 0 -and $after.Unreadable -eq 0) {
        $measured = $before.Bytes - $after.Bytes
    }
    $freeChange = if ($null -ne $freeBefore -and $null -ne $freeAfter) { $freeAfter - $freeBefore } else { $null }

    if ($run.Status -eq 'Success') {
        $status = 'Success'
        $details = "Ran: $($run.Command)"
        if ($ExpectEmpty -and $canMeasure -and $after.Files -gt 0) {
            $status = 'PartialSuccess'
            $details += "; $($after.Files) file(s) could not be removed, possibly because they are in use"
        }
    }
    else {
        $status = if ($null -ne $measured -and $measured -gt 0) { 'PartialSuccess' } else { 'Failed' }
        $details = Get-ResikNativeCommandFailure $run
    }

    [pscustomobject]@{
        Status               = $status
        Details              = $details
        MeasuredBytes        = $measured
        FreeSpaceChangeBytes = $freeChange
    }
}

function Invoke-ResikTargetCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Target,

        # The estimate from analysis, carried into the result for comparison.
        [Nullable[long]] $EstimatedBytes = $null
    )

    $ErrorActionPreference = 'Stop'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($null -eq $Target.Clean) {
        return New-ResikResult -TargetId $Target.Id -Operation Clean -Status Unsupported `
            -Message 'This target supports analysis only.' -EstimatedBytes $EstimatedBytes
    }

    try {
        $outcome = & $Target.Clean
        $status = [string](Get-ResikOptionalProperty $outcome 'Status')
        if (@('Success', 'PartialSuccess', 'Failed', 'Skipped') -cnotcontains $status) {
            throw "Cleanup returned an invalid status '$status'."
        }

        $measured = Get-ResikOptionalProperty $outcome 'MeasuredBytes'
        $freeSpace = Get-ResikOptionalProperty $outcome 'FreeSpaceChangeBytes'
        New-ResikResult -TargetId $Target.Id -Operation Clean -Status $status `
            -Message ([string](Get-ResikOptionalProperty $outcome 'Details')) `
            -EstimatedBytes $EstimatedBytes -MeasuredBytes $measured -FreeSpaceChangeBytes $freeSpace `
            -Duration $stopwatch.Elapsed
    }
    catch {
        New-ResikResult -TargetId $Target.Id -Operation Clean -Status Failed `
            -Message "Cleanup failed: $($_.Exception.Message)" -EstimatedBytes $EstimatedBytes `
            -Duration $stopwatch.Elapsed
    }
}
