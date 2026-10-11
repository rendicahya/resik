# Console summaries. These functions return strings so they can be tested
# without capturing host output.

function Format-ResikSize {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Nullable[long]] $Bytes
    )

    # $null means "not measured", which must never be shown as zero.
    if ($null -eq $Bytes) { return 'n/a' }

    # Measured changes can be negative, for example when free space shrinks.
    $sign = if ($Bytes -lt 0) { '-' } else { '' }
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $value = [math]::Abs([double]$Bytes)
    $unit = 0
    while ($value -ge 1024 -and $unit -lt $units.Count - 1) {
        $value /= 1024
        $unit++
    }
    if ($unit -eq 0) {
        return '{0}{1} B' -f $sign, $value
    }
    $sign + [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.0} {1}', $value, $units[$unit])
}

function Format-ResikCleanupPlan {
    # Describes what is about to be cleaned, shown before confirmation.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object[]] $Targets,

        [Parameter(Mandatory)]
        [object[]] $AnalysisResults
    )

    'The following targets will be cleaned:'
    foreach ($target in $Targets) {
        $analysis = $AnalysisResults | Where-Object { $_.TargetId -eq $target.Id } | Select-Object -First 1
        $estimate = if ($null -ne $analysis) { Format-ResikSize $analysis.EstimatedBytes } else { 'n/a' }
        ''
        "  $($target.Id) - $($target.Name) ($($target.Category), $($target.RiskLevel) risk), estimated $estimate"
        if ($null -ne $analysis -and $analysis.Message) { "    Location: $($analysis.Message)" }
        "    $($target.Description)"
    }
}

function Format-ResikCleanupSummary {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Results = @()
    )

    if ($Results.Count -eq 0) {
        return 'No results.'
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $format = '{0,-16} {1,-14} {2,12} {3,12}  {4}'
    $lines.Add(($format -f 'Target', 'Status', 'Removed', 'Free space', 'Details'))
    $lines.Add(($format -f '------', '------', '-------', '----------', '-------'))

    $measuredTotal = [long]0
    $freeTotal = [long]0
    $unmeasured = 0
    $freeUnmeasured = 0
    $cleaned = 0
    foreach ($result in $Results) {
        $lines.Add(($format -f $result.TargetId, $result.Status, (Format-ResikSize $result.MeasuredBytes),
                (Format-ResikSize $result.FreeSpaceChangeBytes), $result.Message))
        if ($result.Operation -ne 'Clean' -or @('Success', 'PartialSuccess', 'Failed') -notcontains $result.Status) {
            continue
        }
        $cleaned++
        if ($null -eq $result.MeasuredBytes) { $unmeasured++ } else { $measuredTotal += $result.MeasuredBytes }
        if ($null -eq $result.FreeSpaceChangeBytes) { $freeUnmeasured++ } else { $freeTotal += $result.FreeSpaceChangeBytes }
    }

    $lines.Add('')
    if ($cleaned -eq 0) {
        $lines.Add('Nothing was cleaned.')
        return $lines.ToArray()
    }
    $total = "Measured cache reduction: $(Format-ResikSize $measuredTotal)"
    if ($unmeasured -gt 0) { $total += " ($unmeasured target(s) could not be measured)" }
    $lines.Add($total)
    $free = "Change in free disk space: $(Format-ResikSize $freeTotal)"
    if ($freeUnmeasured -gt 0) { $free += " ($freeUnmeasured target(s) could not be measured)" }
    $lines.Add($free)
    $lines.Add('Free space can differ from the cache reduction: files hard-linked into environments stay on disk, and other programs also write to the disk.')
    $lines.ToArray()
}

function Format-ResikSummary {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Results = @(),

        # The targets analyzed. Those without a Clean operation are reported
        # but left out of the reclaimable total, because Resik never cleans
        # them.
        [AllowEmptyCollection()]
        [object[]] $Targets = @()
    )

    if ($Results.Count -eq 0) {
        return 'No results.'
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $reportOnly = @($Targets | Where-Object { $null -eq $_.Clean } | ForEach-Object { $_.Id })

    $format = '{0,-24} {1,-14} {2,12}  {3}'
    $lines.Add(($format -f 'Target', 'Status', 'Estimated', 'Details'))
    $lines.Add(($format -f '------', '------', '---------', '-------'))

    $estimatedTotal = [long]0
    $unmeasured = 0
    $notCleaned = New-Object System.Collections.Generic.List[string]
    foreach ($result in $Results) {
        $lines.Add(($format -f $result.TargetId, $result.Status, (Format-ResikSize $result.EstimatedBytes), $result.Message))
        if ($result.Status -ne 'AnalysisOnly') { continue }
        if ($reportOnly -contains $result.TargetId) { $notCleaned.Add($result.TargetId); continue }
        if ($null -eq $result.EstimatedBytes) { $unmeasured++ } else { $estimatedTotal += $result.EstimatedBytes }
    }

    $lines.Add('')
    $total = "Estimated reclaimable space: $(Format-ResikSize $estimatedTotal) (estimate only; nothing was removed)"
    if ($unmeasured -gt 0) {
        $total += "; $unmeasured target(s) could not be measured"
    }
    $lines.Add($total)
    if ($notCleaned.Count -gt 0) {
        $lines.Add("Not included, because Resik only reports their size: $($notCleaned -join ', ')")
    }

    $lines.ToArray()
}
