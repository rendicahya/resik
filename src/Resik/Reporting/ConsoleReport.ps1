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

function Format-ResikCount {
    # "1 target", "3 targets".
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $Count, [string] $Noun = 'target')
    if ($Count -eq 1) { "1 $Noun" } else { "$Count ${Noun}s" }
}

function ConvertTo-ResikDisplayText {
    # Shortens the user profile folder at the start of a path to "~".
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text,

        [string] $UserProfile = [Environment]::GetFolderPath('UserProfile')
    )

    if (-not $Text) { return '' }
    if (-not $UserProfile) { return $Text }
    $pattern = '(?i)(?<![\w\\])' + [regex]::Escape($UserProfile.TrimEnd('\')) + '(?=\\|$|[\s),;])'
    [regex]::Replace($Text, $pattern, '~')
}

function Limit-ResikText {
    # Cuts text to Width characters, ending with "..." when cut. A Width of 0
    # means no limit.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text,

        [int] $Width = 0
    )

    if (-not $Text) { return '' }
    if ($Width -le 0 -or $Text.Length -le $Width) { return $Text }
    if ($Width -le 3) { return $Text.Substring(0, $Width) }
    $Text.Substring(0, $Width - 3) + '...'
}

function Split-ResikText {
    # Wraps text at spaces into lines of at most Width characters, each
    # starting with Indent. A Width of 0 means no wrapping.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text,

        [int] $Width = 0,

        [string] $Indent = ''
    )

    if (-not $Text) { return }
    $room = $Width - $Indent.Length
    if ($Width -le 0 -or $room -lt 10) { return $Indent + $Text }

    $line = ''
    foreach ($word in ($Text -split ' ' | Where-Object { $_ })) {
        while ($word.Length -gt $room) {
            if ($line) { $Indent + $line; $line = '' }
            $Indent + $word.Substring(0, $room)
            $word = $word.Substring($room)
        }
        if (-not $line) { $line = $word }
        elseif ($line.Length + 1 + $word.Length -le $room) { $line += " $word" }
        else { $Indent + $line; $line = $word }
    }
    if ($line) { $Indent + $line }
}

function Get-ResikAnalysisGroup {
    # Sorts an analysis result into the section it is shown in: Ready (can be
    # cleaned), ReportOnly (Resik only reports its size), NotFound, Skipped,
    # or Problem.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Result,

        [object] $Target
    )

    switch ($Result.Status) {
        'AnalysisOnly' {
            if ($null -ne $Target -and $null -eq $Target.Clean) { return 'ReportOnly' }
            return 'Ready'
        }
        'Skipped' {
            if ("$($Result.Message)" -like 'Not detected:*') { return 'NotFound' }
            return 'Skipped'
        }
    }
    'Problem'
}

function Format-ResikSummary {
    # The analysis report: cleanable targets sorted by size, then targets Resik
    # only reports, skipped targets, and problems. Tools that are not installed
    # are left out, unless ShowNotFound is set (the user named them with
    # --only), which adds one line naming them. Width (0 for no limit) keeps
    # rows on one line.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Results = @(),

        # The targets analyzed. Those without a Clean operation are reported
        # but left out of the reclaimable total, because Resik never cleans
        # them.
        [AllowEmptyCollection()]
        [object[]] $Targets = @(),

        [int] $Width = 0,

        [switch] $ShowNotFound
    )

    if ($Results.Count -eq 0) {
        return 'No results.'
    }

    $entries = foreach ($result in $Results) {
        $target = $Targets | Where-Object { $_.Id -eq $result.TargetId } | Select-Object -First 1
        [pscustomobject]@{
            Id      = $result.TargetId
            Name    = $(if ($null -ne $target) { $target.Name } else { '' })
            Risk    = $(if ($null -ne $target) { "$($target.RiskLevel)" } else { '' })
            Bytes   = $result.EstimatedBytes
            Size    = $(if ($null -eq $result.EstimatedBytes) { '?' } else { Format-ResikSize $result.EstimatedBytes })
            Status  = "$($result.Status)"
            Message = ConvertTo-ResikDisplayText $result.Message
            Group   = Get-ResikAnalysisGroup -Result $result -Target $target
        }
    }
    $entries = @($entries)

    # Known sizes first, largest first; unknown sizes last.
    $ready = @($entries | Where-Object { $_.Group -eq 'Ready' } |
            Sort-Object -Property @{ Expression = { $null -eq $_.Bytes } }, @{ Expression = { $_.Bytes }; Descending = $true })
    $reportOnly = @($entries | Where-Object { $_.Group -eq 'ReportOnly' })
    $skipped = @($entries | Where-Object { $_.Group -eq 'Skipped' })
    $problems = @($entries | Where-Object { $_.Group -eq 'Problem' })
    $notFound = @($entries | Where-Object { $_.Group -eq 'NotFound' })

    $sized = @($ready) + @($reportOnly)
    $shown = @($sized) + @($skipped) + @($problems)
    $idWidth = [int][Math]::Max(2, (@($shown | ForEach-Object { $_.Id.Length }) | Measure-Object -Maximum).Maximum)
    $nameWidth = 0
    $sizeWidth = 4
    $riskWidth = 4
    foreach ($entry in $sized) {
        $nameWidth = [Math]::Max($nameWidth, $entry.Name.Length)
        $sizeWidth = [Math]::Max($sizeWidth, $entry.Size.Length)
        $riskWidth = [Math]::Max($riskWidth, $entry.Risk.Length)
    }
    $nameWidth = [Math]::Min($nameWidth, 30)
    $nameColumn = if ($nameWidth -gt 0) { '  ' + ''.PadRight($nameWidth) } else { '' }
    $detailsAt = 2 + $idWidth + $nameColumn.Length + 2 + $sizeWidth + 2 + $riskWidth + 2
    $detailsWidth = if ($Width -gt 0) { [Math]::Max(0, $Width - 1 - $detailsAt) } else { 0 }

    $lines = New-Object System.Collections.Generic.List[string]
    $addRow = {
        param($Entry, [bool] $WithDetails)
        $name = if ($nameWidth -gt 0) { '  ' + (Limit-ResikText $Entry.Name $nameWidth).PadRight($nameWidth) } else { '' }
        $row = '  ' + $Entry.Id.PadRight($idWidth) + $name + '  ' + $Entry.Size.PadLeft($sizeWidth) + '  ' + $Entry.Risk.PadRight($riskWidth)
        if ($WithDetails -and $Entry.Message -and ($Width -le 0 -or $detailsWidth -ge 10)) {
            $row += '  ' + (Limit-ResikText $Entry.Message $detailsWidth)
        }
        $lines.Add($row.TrimEnd())
    }
    $addHeading = {
        param([string] $Title)
        if ($lines.Count -gt 0) { $lines.Add('') }
        $left = $Title.PadRight(2 + $idWidth + $nameColumn.Length)
        $lines.Add(($left + '  ' + 'Size'.PadLeft($sizeWidth) + '  ' + 'Risk').TrimEnd())
    }

    if ($ready.Count -gt 0) {
        & $addHeading 'Ready to clean'
        foreach ($entry in $ready) { & $addRow $entry $true }
    }

    if ($reportOnly.Count -gt 0) {
        & $addHeading 'Report only'
        foreach ($entry in $reportOnly) {
            & $addRow $entry $false
            foreach ($line in @(Split-ResikText $entry.Message -Width ($Width - 1) -Indent '    ')) { $lines.Add($line) }
        }
    }

    foreach ($section in @(
            [pscustomobject]@{ Title = 'Skipped'; Entries = $skipped },
            [pscustomobject]@{ Title = 'Problems'; Entries = $problems })) {
        if ($section.Entries.Count -eq 0) { continue }
        if ($lines.Count -gt 0) { $lines.Add('') }
        $lines.Add($section.Title)
        foreach ($entry in $section.Entries) {
            $label = if ($section.Title -eq 'Problems') { "$($entry.Id) ($($entry.Status))" } else { $entry.Id }
            $lines.Add("  $label")
            foreach ($line in @(Split-ResikText $entry.Message -Width ($Width - 1) -Indent '    ')) { $lines.Add($line) }
        }
    }

    if ($ShowNotFound -and $notFound.Count -gt 0) {
        if ($lines.Count -gt 0) { $lines.Add('') }
        $text = 'Not found: ' + (($notFound | ForEach-Object { $_.Id }) -join ', ')
        foreach ($line in @(Split-ResikText $text -Width ($Width - 1))) { $lines.Add($line) }
    }

    $estimatedTotal = [long]0
    $unmeasured = 0
    foreach ($entry in $ready) {
        if ($null -eq $entry.Bytes) { $unmeasured++ } else { $estimatedTotal += $entry.Bytes }
    }
    $lines.Add('')
    if ($ready.Count -eq 0) {
        $lines.Add('Nothing to clean.')
    }
    else {
        foreach ($line in @(Split-ResikText "Total you can reclaim: about $(Format-ResikSize $estimatedTotal) (estimate only; nothing was removed)" -Width ($Width - 1))) {
            $lines.Add($line)
        }
        if ($unmeasured -gt 0) {
            $lines.Add("$(Format-ResikCount $unmeasured) could not be measured in advance (shown as ?).")
        }
    }

    $lines.ToArray()
}

function Format-ResikCleanupPlan {
    # Describes what is about to be cleaned, shown before confirmation.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object[]] $Targets,

        [Parameter(Mandatory)]
        [object[]] $AnalysisResults,

        [int] $Width = 0
    )

    $total = [long]0
    $unmeasured = 0
    $blocks = foreach ($target in $Targets) {
        $analysis = $AnalysisResults | Where-Object { $_.TargetId -eq $target.Id } | Select-Object -First 1
        $bytes = if ($null -ne $analysis) { $analysis.EstimatedBytes } else { $null }
        if ($null -eq $bytes) { $unmeasured++ } else { $total += $bytes }
        $size = if ($null -eq $bytes) { 'size unknown' } else { Format-ResikSize $bytes }
        [pscustomobject]@{
            Heading     = "  $($target.Name) ($($target.Id)) - $size, $($target.RiskLevel) risk"
            Location    = $(if ($null -ne $analysis) { ConvertTo-ResikDisplayText $analysis.Message } else { '' })
            Description = $target.Description
        }
    }

    $about = "about $(Format-ResikSize $total)"
    if ($unmeasured -gt 0) { $about += ", plus $(Format-ResikCount $unmeasured) of unknown size" }
    "Resik will clean $(Format-ResikCount $Targets.Count) ($about):"
    foreach ($block in @($blocks)) {
        ''
        $block.Heading
        Split-ResikText $block.Location -Width ($Width - 1) -Indent '    '
        Split-ResikText $block.Description -Width ($Width - 1) -Indent '    '
    }
}

function Test-ResikRoutineDetail {
    # True for cleanup details that only repeat what Resik printed while
    # cleaning (the command it ran, the folder it emptied), so the report can
    # leave them out for targets that were cleaned without problems.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()] [AllowNull()] [string] $Text)
    "$Text" -match '^(Ran: |Deleted \d+ file\(s\) in [^;]*$|Emptied the Recycle Bin\.$)'
}

function Format-ResikCleanupSummary {
    # The cleanup report, laid out like the analysis report: cleaned targets
    # sorted by what was removed, then partly cleaned, failed, and skipped
    # targets with their details. Width (0 for no limit) wraps details.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Results = @(),

        # The targets cleaned, for their names. Optional.
        [AllowEmptyCollection()]
        [object[]] $Targets = @(),

        [int] $Width = 0
    )

    if ($Results.Count -eq 0) {
        return 'No results.'
    }

    $entries = @(foreach ($result in $Results) {
            $target = $Targets | Where-Object { $_.Id -eq $result.TargetId } | Select-Object -First 1
            $message = ConvertTo-ResikDisplayText $result.Message
            if ($result.Status -eq 'Success' -and (Test-ResikRoutineDetail $result.Message)) { $message = '' }
            [pscustomobject]@{
                Id      = "$($result.TargetId)"
                Name    = $(if ($null -ne $target) { "$($target.Name)" } else { '' })
                Bytes   = $result.MeasuredBytes
                Removed = $(if ($null -eq $result.MeasuredBytes) { '?' } else { Format-ResikSize $result.MeasuredBytes })
                Free    = $(if ($null -eq $result.FreeSpaceChangeBytes) { '?' } else { Format-ResikSize $result.FreeSpaceChangeBytes })
                Status  = "$($result.Status)"
                Message = $message
                Counted = $result.Operation -eq 'Clean' -and @('Success', 'PartialSuccess', 'Failed') -contains $result.Status
                Result  = $result
            }
        })

    $bySize = @{ Expression = { $null -eq $_.Bytes } }, @{ Expression = { $_.Bytes }; Descending = $true }
    $cleaned = @($entries | Where-Object { $_.Status -eq 'Success' } | Sort-Object -Property $bySize)
    $partly = @($entries | Where-Object { $_.Status -eq 'PartialSuccess' } | Sort-Object -Property $bySize)
    $failed = @($entries | Where-Object { $_.Status -eq 'Failed' })
    $other = @($entries | Where-Object { @('Success', 'PartialSuccess', 'Failed') -notcontains $_.Status })

    $idWidth = [int](@($entries | ForEach-Object { $_.Id.Length }) | Measure-Object -Maximum).Maximum
    $nameWidth = [Math]::Min(30, [int](@($entries | ForEach-Object { $_.Name.Length }) | Measure-Object -Maximum).Maximum)
    $removedWidth = 'Removed'.Length
    $freeWidth = 'Free space'.Length
    foreach ($entry in @($cleaned) + @($partly)) {
        $removedWidth = [Math]::Max($removedWidth, $entry.Removed.Length)
        $freeWidth = [Math]::Max($freeWidth, $entry.Free.Length)
    }
    $label = {
        param($Entry)
        $name = if ($nameWidth -gt 0) { '  ' + (Limit-ResikText $Entry.Name $nameWidth).PadRight($nameWidth) } else { '' }
        '  ' + $Entry.Id.PadRight($idWidth) + $name
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $addDetails = {
        param($Entry)
        foreach ($line in @(Split-ResikText $Entry.Message -Width ($Width - 1) -Indent '    ')) { $lines.Add($line) }
    }

    foreach ($section in @(
            [pscustomobject]@{ Title = 'Cleaned'; Entries = $cleaned },
            [pscustomobject]@{ Title = 'Partly cleaned'; Entries = $partly })) {
        if ($section.Entries.Count -eq 0) { continue }
        if ($lines.Count -gt 0) { $lines.Add('') }
        $left = $section.Title.PadRight(2 + $idWidth + $(if ($nameWidth -gt 0) { 2 + $nameWidth } else { 0 }))
        $lines.Add($left + '  ' + 'Removed'.PadLeft($removedWidth) + '  ' + 'Free space'.PadLeft($freeWidth))
        foreach ($entry in $section.Entries) {
            $lines.Add((& $label $entry) + '  ' + $entry.Removed.PadLeft($removedWidth) + '  ' + $entry.Free.PadLeft($freeWidth))
            & $addDetails $entry
        }
    }

    foreach ($section in @(
            [pscustomobject]@{ Title = 'Failed'; Entries = $failed },
            [pscustomobject]@{ Title = 'Not cleaned'; Entries = $other })) {
        if ($section.Entries.Count -eq 0) { continue }
        if ($lines.Count -gt 0) { $lines.Add('') }
        $lines.Add($section.Title)
        foreach ($entry in $section.Entries) {
            $lines.Add((& $label $entry).TrimEnd())
            & $addDetails $entry
        }
    }

    $counted = @($entries | Where-Object { $_.Counted })
    $lines.Add('')
    if (@($cleaned).Count + @($partly).Count -eq 0) {
        $lines.Add('Nothing was cleaned.')
        return $lines.ToArray()
    }

    $measuredTotal = [long]0
    $freeTotal = [long]0
    $unmeasured = 0
    $freeUnmeasured = 0
    foreach ($entry in $counted) {
        if ($null -eq $entry.Result.MeasuredBytes) { $unmeasured++ } else { $measuredTotal += $entry.Result.MeasuredBytes }
        if ($null -eq $entry.Result.FreeSpaceChangeBytes) { $freeUnmeasured++ } else { $freeTotal += $entry.Result.FreeSpaceChangeBytes }
    }
    $total = "Measured cache reduction:  $(Format-ResikSize $measuredTotal)"
    if ($unmeasured -gt 0) { $total += " ($(Format-ResikCount $unmeasured) not measured)" }
    $lines.Add($total)
    $free = "Change in free disk space: $(Format-ResikSize $freeTotal)"
    if ($freeUnmeasured -gt 0) { $free += " ($(Format-ResikCount $freeUnmeasured) not measured)" }
    $lines.Add($free)
    foreach ($line in @(Split-ResikText 'The two can differ: other programs also write to the disk, and hard-linked files stay on it.' -Width ($Width - 1))) {
        $lines.Add($line)
    }
    $lines.ToArray()
}
