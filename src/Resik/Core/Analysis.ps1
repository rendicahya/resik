# Non-destructive analysis orchestration.
#
# Each target's Detect and Analyze scriptblocks run in isolation: a failure in
# one target produces a Failed result for that target and never stops the rest.

function Get-ResikOptionalProperty {
    # Reads a property that may be absent without tripping strict mode.
    param($InputObject, [string] $Name)
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $property.Value
}

function Invoke-ResikTargetAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Target
    )

    $ErrorActionPreference = 'Stop'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $detection = & $Target.Detect
        if ((Get-ResikOptionalProperty $detection 'Available') -ne $true) {
            $details = Get-ResikOptionalProperty $detection 'Details'
            $message = if ($details) { "Not detected: $details" } else { 'Not detected.' }
            return New-ResikResult -TargetId $Target.Id -Operation Analyze -Status Skipped `
                -Message $message -Duration $stopwatch.Elapsed
        }

        $analysis = & $Target.Analyze
        $estimate = Get-ResikOptionalProperty $analysis 'EstimatedBytes'
        if ($null -ne $estimate) {
            $estimate = [long]$estimate
            if ($estimate -lt 0) {
                throw "Analysis returned a negative size estimate ($estimate)."
            }
        }

        New-ResikResult -TargetId $Target.Id -Operation Analyze -Status AnalysisOnly `
            -Message ([string](Get-ResikOptionalProperty $analysis 'Details')) `
            -EstimatedBytes $estimate -Duration $stopwatch.Elapsed
    }
    catch {
        New-ResikResult -TargetId $Target.Id -Operation Analyze -Status Failed `
            -Message "Analysis failed: $($_.Exception.Message)" -Duration $stopwatch.Elapsed
    }
}

function Invoke-ResikAnalysis {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]] $Targets = @(),

        # A running spinner (Start-ResikSpinner) that shows the current target.
        [AllowNull()]
        [object] $Spinner = $null
    )

    $number = 0
    foreach ($target in $Targets) {
        $number++
        Set-ResikSpinnerMessage -Spinner $Spinner -Message "Analyzing $($target.Name) ($number of $($Targets.Count))"
        Invoke-ResikTargetAnalysis -Target $target
    }
}
