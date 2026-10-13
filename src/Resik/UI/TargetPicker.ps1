# Interactive target selection.
#
# The picker is split into testable parts: New-ResikPickerState builds the
# list, Invoke-ResikPickerKey applies a key, and Format-ResikPickerScreen
# returns the lines to draw. Only Show-ResikTargetPicker, Read-ResikPickerKey,
# and the small console wrappers touch the console.
#
# Keys: Up/Down move, Space toggles, A selects all, N selects none, Enter
# confirms, Q or Escape cancels. Terminals without key input get a numbered
# list instead (Read-ResikNumberedSelection).

function Get-ResikPickerMode {
    # 'Keys' for the full picker, 'Numbered' for the typed fallback, or 'None'
    # when nobody can answer (input redirected or no interactive session).
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { return 'None' }
    if ($Host.Name -ne 'ConsoleHost' -or [Console]::IsOutputRedirected) { return 'Numbered' }
    try {
        $null = [Console]::KeyAvailable
        $null = [Console]::WindowWidth
    }
    catch {
        return 'Numbered'
    }
    'Keys'
}

function New-ResikPickerState {
    # One item per target. Only targets that analyzed successfully and support
    # cleanup can be selected. Nothing is selected at first.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Targets,

        [AllowEmptyCollection()]
        [object[]] $Analysis = @()
    )

    $items = foreach ($target in $Targets) {
        $result = $Analysis | Where-Object { $_.TargetId -eq $target.Id } | Select-Object -First 1
        $selectable = $false
        $details = ''
        $estimate = $null
        if ($null -eq $result) {
            $note = 'not analyzed'
        }
        else {
            $details = $result.Message
            $estimate = $result.EstimatedBytes
            if ($result.Status -eq 'AnalysisOnly' -and $null -ne $target.Clean) {
                $selectable = $true
                $note = Format-ResikSize $estimate
            }
            elseif ($result.Status -eq 'AnalysisOnly') { $note = 'analysis only' }
            elseif ($result.Status -eq 'Skipped') { $note = 'not found' }
            elseif ($result.Status -eq 'Failed') { $note = 'analysis failed' }
            else { $note = $result.Status }
        }

        [pscustomobject]@{
            Target         = $target
            Selectable     = $selectable
            Selected       = $false
            Note           = $note
            Details        = $details
            EstimatedBytes = $estimate
        }
    }

    [pscustomobject]@{
        Items  = @($items)
        Cursor = 0
    }
}

function ConvertFrom-ResikConsoleKey {
    # Maps a key press to a picker command.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.ConsoleKey] $Key,

        [char] $Character = [char]0
    )

    switch ($Key) {
        'UpArrow' { return 'Up' }
        'DownArrow' { return 'Down' }
        'Spacebar' { return 'Toggle' }
        'Enter' { return 'Confirm' }
        'Escape' { return 'Cancel' }
    }
    switch ("$Character".ToLowerInvariant()) {
        'a' { return 'All' }
        'n' { return 'None' }
        'q' { return 'Cancel' }
    }
    'Other'
}

function Invoke-ResikPickerKey {
    # Applies a picker command to the state. Returns 'Continue', 'Confirm', or
    # 'Cancel'.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $State,

        [Parameter(Mandatory)]
        [string] $Command
    )

    $count = $State.Items.Count
    switch ($Command) {
        'Up' {
            if ($count -gt 0) { $State.Cursor = ($State.Cursor - 1 + $count) % $count }
            return 'Continue'
        }
        'Down' {
            if ($count -gt 0) { $State.Cursor = ($State.Cursor + 1) % $count }
            return 'Continue'
        }
        'Toggle' {
            if ($count -gt 0) {
                $item = $State.Items[$State.Cursor]
                if ($item.Selectable) { $item.Selected = -not $item.Selected }
            }
            return 'Continue'
        }
        'All' {
            foreach ($item in $State.Items) {
                if ($item.Selectable -and -not (Get-ResikOptionalProperty $item.Target 'ExplicitOnly')) { $item.Selected = $true }
            }
            return 'Continue'
        }
        'None' {
            foreach ($item in $State.Items) { $item.Selected = $false }
            return 'Continue'
        }
        'Confirm' { return 'Confirm' }
        'Cancel' { return 'Cancel' }
    }
    'Continue'
}

function Format-ResikPickerRow {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Item
    )

    $target = $Item.Target
    '{0,-12} {1,-23} {2,-10} {3,-9} {4}' -f $target.Id, $target.Name, $target.Category, "$($target.RiskLevel) risk", $Item.Note
}

function Format-ResikPickerScreen {
    # Returns the lines to draw as objects with Text and Color ($null for the
    # default color). Every line is padded or cut to Width - 1 characters so
    # that redrawing in place never wraps, and the line count never changes.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $State,

        [string] $Title = 'Select targets to clean',

        [ValidateRange(20, 10000)]
        [int] $Width = 80
    )

    $lines = New-Object System.Collections.Generic.List[object]
    $limit = $Width - 1
    $addLine = {
        param([string] $Text, $Color = $null)
        if ($Text.Length -gt $limit) { $Text = $Text.Substring(0, $limit - 3) + '...' }
        $lines.Add([pscustomobject]@{ Text = $Text.PadRight($limit); Color = $Color })
    }

    & $addLine $Title
    & $addLine 'Up/Down: move  Space: select  A: all  N: none  Enter: confirm  Q/Esc: cancel'
    & $addLine ''

    for ($index = 0; $index -lt $State.Items.Count; $index++) {
        $item = $State.Items[$index]
        $isCursor = $index -eq $State.Cursor
        $pointer = if ($isCursor) { '>' } else { ' ' }
        $box = if (-not $item.Selectable) { '[-]' } elseif ($item.Selected) { '[x]' } else { '[ ]' }
        $color = if ($isCursor) { 'Cyan' } elseif (-not $item.Selectable) { 'DarkGray' } else { $null }
        & $addLine "$pointer $box $(Format-ResikPickerRow $item)" $color
    }

    & $addLine ''
    $current = if ($State.Items.Count -gt 0) { $State.Items[$State.Cursor] } else { $null }
    $details = if ($null -ne $current) { $current.Details } else { '' }
    & $addLine "  $details" 'DarkGray'

    $selected = @($State.Items | Where-Object { $_.Selected })
    $total = [long]0
    foreach ($item in $selected) { if ($null -ne $item.EstimatedBytes) { $total += $item.EstimatedBytes } }
    & $addLine "  Selected: $($selected.Count) target(s), estimated $(Format-ResikSize $total)"

    $lines.ToArray()
}

function Get-ResikConsoleWidth {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    try { [Math]::Max(20, [Console]::WindowWidth) } catch { 80 }
}

function Get-ResikConsoleCursorRow {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    [Console]::CursorTop
}

function Move-ResikConsoleCursor {
    [CmdletBinding()]
    param([int] $Row)
    [Console]::SetCursorPosition(0, [Math]::Max(0, $Row))
}

function Read-ResikPickerKey {
    # Waits for a key press and returns a picker command.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $keyInfo = [Console]::ReadKey($true)
    ConvertFrom-ResikConsoleKey -Key $keyInfo.Key -Character $keyInfo.KeyChar
}

function Show-ResikTargetPicker {
    # Draws the picker and handles keys until the user confirms or cancels.
    # Returns 'Confirm' or 'Cancel'; the selection is left in State.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $State,

        [string] $Title = 'Select targets to clean'
    )

    $cursorWasVisible = $null
    try { $cursorWasVisible = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch { $cursorWasVisible = $null }
    try {
        $origin = $null
        while ($true) {
            $lines = @(Format-ResikPickerScreen -State $State -Title $Title -Width (Get-ResikConsoleWidth))
            if ($null -ne $origin) { Move-ResikConsoleCursor -Row $origin }
            foreach ($line in $lines) {
                if ($line.Color) { Write-Host $line.Text -ForegroundColor $line.Color } else { Write-Host $line.Text }
            }
            # Measured after the first draw, because drawing can scroll the window.
            if ($null -eq $origin) { $origin = (Get-ResikConsoleCursorRow) - $lines.Count }

            $action = Invoke-ResikPickerKey -State $State -Command (Read-ResikPickerKey)
            if ($action -ne 'Continue') { return $action }
        }
    }
    finally {
        if ($null -ne $cursorWasVisible) {
            try { [Console]::CursorVisible = $cursorWasVisible } catch { Write-Verbose 'Could not restore the cursor.' }
        }
    }
}

function ConvertFrom-ResikNumberedSelection {
    # Parses the answer to the numbered list: "1,3" or "1 3", "a" or "all", or
    # an empty answer to cancel. Returns Action ('Select', 'Cancel', 'Invalid')
    # and zero-based Indexes into the selectable items. All is true for "a".
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text,

        [int] $Count
    )

    $answer = "$Text".Trim().ToLowerInvariant()
    if ($answer -eq '') {
        return [pscustomobject]@{ Action = 'Cancel'; Indexes = @(); All = $false }
    }
    if ($answer -eq 'a' -or $answer -eq 'all') {
        $all = if ($Count -gt 0) { @(0..($Count - 1)) } else { @() }
        return [pscustomobject]@{ Action = 'Select'; Indexes = $all; All = $true }
    }

    $indexes = New-Object System.Collections.Generic.List[int]
    foreach ($part in ($answer -split '[,\s]+' | Where-Object { $_ })) {
        $number = 0
        if (-not [int]::TryParse($part, [ref]$number) -or $number -lt 1 -or $number -gt $Count) {
            return [pscustomobject]@{ Action = 'Invalid'; Indexes = @(); All = $false }
        }
        if (-not $indexes.Contains($number - 1)) { $indexes.Add($number - 1) }
    }
    [pscustomobject]@{ Action = 'Select'; Indexes = $indexes.ToArray(); All = $false }
}

function Read-ResikLine {
    # Reads one line of input through the PowerShell host.
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Prompt)
    Read-Host -Prompt $Prompt
}

function Read-ResikNumberedSelection {
    # The fallback picker for terminals without key input. Returns 'Confirm'
    # or 'Cancel'; the selection is left in State.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $State,

        [string] $Title = 'Select targets to clean'
    )

    $selectable = @($State.Items | Where-Object { $_.Selectable })
    Write-Host $Title
    Write-Host ''
    $number = 0
    foreach ($item in $State.Items) {
        $label = if ($item.Selectable) { $number++; '{0,3})' -f $number } else { '   -' }
        Write-Host "$label $(Format-ResikPickerRow $item)"
    }
    Write-Host ''
    if ($selectable.Count -eq 0) {
        return 'Confirm'
    }

    while ($true) {
        $answer = Read-ResikLine -Prompt 'Numbers to select (for example 1,3), "a" for all, or Enter to cancel'
        if ($null -eq $answer) { return 'Cancel' }
        $parsed = ConvertFrom-ResikNumberedSelection -Text $answer -Count $selectable.Count
        if ($parsed.Action -eq 'Cancel') { return 'Cancel' }
        if ($parsed.Action -eq 'Invalid') {
            Write-Host "Enter numbers from 1 to $($selectable.Count), separated by commas or spaces."
            continue
        }
        foreach ($index in $parsed.Indexes) {
            # "a" leaves out targets that must be chosen one by one.
            if ($parsed.All -and (Get-ResikOptionalProperty $selectable[$index].Target 'ExplicitOnly')) { continue }
            $selectable[$index].Selected = $true
        }
        return 'Confirm'
    }
}

function Select-ResikTargetInteractive {
    # Lets the user pick targets. Returns Cancelled and the selected Targets.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Targets,

        [AllowEmptyCollection()]
        [object[]] $Analysis = @(),

        [ValidateSet('Keys', 'Numbered')]
        [string] $Mode = 'Keys',

        [switch] $DryRun
    )

    $state = New-ResikPickerState -Targets $Targets -Analysis $Analysis
    $title = if ($DryRun) { 'Select targets to analyze (dry run; nothing will be changed)' } else { 'Select targets to clean' }
    $action = if ($Mode -eq 'Keys') {
        Show-ResikTargetPicker -State $state -Title $title
    }
    else {
        Read-ResikNumberedSelection -State $state -Title $title
    }

    [pscustomobject]@{
        Cancelled = $action -eq 'Cancel'
        Targets   = @($state.Items | Where-Object { $_.Selected } | ForEach-Object { $_.Target })
    }
}
