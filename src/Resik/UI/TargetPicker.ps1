# Interactive target selection.
#
# The picker is split into testable parts: New-ResikPickerState builds the
# list, Invoke-ResikPickerKey applies a key, and Format-ResikPickerScreen
# returns the lines to draw. Only Show-ResikTargetPicker, Read-ResikPickerKey,
# and the small console wrappers touch the console.
#
# Keys: Up/Down move, Space toggles, A selects all, N selects none, Enter
# confirms, Q or Escape cancels. When the console reports mouse events
# (Enable-ResikPickerMouse), a left click toggles the row under it and the
# wheel moves the cursor. Terminals without key input get a numbered list
# instead (Read-ResikNumberedSelection).
#
# Targets with the same Group (the parts of one browser) are listed under a
# heading row; toggling the heading toggles its parts. State.Items holds the
# targets in display order, State.Rows the drawn rows, and Cursor indexes
# State.Rows.

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

    # Cleanable targets come first, largest first, after ListFirst targets.
    # Tools that are not installed are left out.
    $items = New-Object System.Collections.Generic.List[object]
    $order = 0
    foreach ($target in $Targets) {
        $order++
        $result = $Analysis | Where-Object { $_.TargetId -eq $target.Id } | Select-Object -First 1
        $estimate = $null
        $details = ''
        if ($null -eq $result) {
            $group = 'Problem'
            $note = 'not analyzed'
        }
        else {
            $details = ConvertTo-ResikDisplayText $result.Message
            $estimate = $result.EstimatedBytes
            $group = Get-ResikAnalysisGroup -Result $result -Target $target
            $note = switch ($group) {
                'Ready' { '' }
                'ReportOnly' { 'report only' }
                'Skipped' { 'skipped' }
                default { if ($result.Status -eq 'Failed') { 'analysis failed' } else { "$($result.Status)" } }
            }
        }
        if ($group -eq 'NotFound') { continue }

        $items.Add([pscustomobject]@{
                Target         = $target
                Selectable     = $group -eq 'Ready'
                Selected       = $false
                Note           = $note
                Details        = $details
                EstimatedBytes = $estimate
                Rank           = @{ Ready = 0; ReportOnly = 1; Skipped = 2; Problem = 3 }[$group]
                ListFirst      = [bool](Get-ResikOptionalProperty $target 'ListFirst')
                Order          = $order
            })
    }

    # Targets that share a Group (the parts of one browser) are kept together
    # under a heading row, in catalog order. The group is sorted as one entry,
    # by its best status and its total size.
    $entries = New-Object System.Collections.Generic.List[object]
    $byGroup = @{}
    foreach ($item in $items) {
        $groupName = [string](Get-ResikOptionalProperty $item.Target 'Group')
        if ($groupName -and $byGroup.ContainsKey($groupName)) {
            $byGroup[$groupName].Members.Add($item)
            continue
        }
        $entry = [pscustomobject]@{ Name = $groupName; Members = New-Object System.Collections.Generic.List[object] }
        $entry.Members.Add($item)
        if ($groupName) { $byGroup[$groupName] = $entry }
        $entries.Add($entry)
    }
    foreach ($entry in $entries) {
        $total = $null
        foreach ($member in $entry.Members) {
            if ($null -ne $member.EstimatedBytes) { $total = [long]$total + $member.EstimatedBytes }
        }
        $entry | Add-Member -NotePropertyName Rank -NotePropertyValue (($entry.Members | Measure-Object -Property Rank -Minimum).Minimum)
        $entry | Add-Member -NotePropertyName EstimatedBytes -NotePropertyValue $total
        $entry | Add-Member -NotePropertyName ListFirst -NotePropertyValue (@($entry.Members | Where-Object { $_.ListFirst }).Count -gt 0)
        $entry | Add-Member -NotePropertyName Order -NotePropertyValue (($entry.Members | Measure-Object -Property Order -Minimum).Minimum)
    }

    $sorted = @($entries | Sort-Object -Property Rank,
        @{ Expression = { $_.ListFirst }; Descending = $true },
        @{ Expression = { $null -eq $_.EstimatedBytes } },
        @{ Expression = { $_.EstimatedBytes }; Descending = $true },
        Order)

    $flat = New-Object System.Collections.Generic.List[object]
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $sorted) {
        $members = @($entry.Members | Sort-Object -Property Order)
        $grouped = $entry.Name -and $members.Count -gt 1
        if ($grouped) {
            $rows.Add([pscustomobject]@{ Kind = 'Group'; Name = $entry.Name; Item = $null; Members = $members; Indent = 0 })
        }
        foreach ($member in $members) {
            $flat.Add($member)
            $rows.Add([pscustomobject]@{ Kind = 'Item'; Name = ''; Item = $member; Members = @($member); Indent = [int]$grouped })
        }
    }

    [pscustomobject]@{
        Items  = $flat.ToArray()
        Rows   = $rows.ToArray()
        Cursor = 0
        # The first row drawn when the list is taller than the window.
        Top    = 0
    }
}

function Update-ResikPickerScroll {
    # Moves State.Top as little as possible so the cursor row is among the
    # Visible rows drawn from Top, and no space is left empty below the list.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Changes an in-memory object only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $State,

        [Parameter(Mandatory)]
        [int] $Visible
    )

    $count = $State.Rows.Count
    $top = [int]$State.Top
    if ($Visible -lt 1 -or $count -le $Visible) {
        $State.Top = 0
        return
    }
    if ($State.Cursor -lt $top) { $top = $State.Cursor }
    if ($State.Cursor -ge $top + $Visible) { $top = $State.Cursor - $Visible + 1 }
    $State.Top = [Math]::Max(0, [Math]::Min($top, $count - $Visible))
}

function Switch-ResikPickerRow {
    # Toggles one row. A group row selects every selectable part except those
    # that must be chosen one by one, or clears the group when they are all
    # selected already.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Row
    )

    if ($Row.Kind -eq 'Item') {
        if ($Row.Item.Selectable) { $Row.Item.Selected = -not $Row.Item.Selected }
        return
    }
    $eligible = @($Row.Members | Where-Object { $_.Selectable -and -not (Get-ResikOptionalProperty $_.Target 'ExplicitOnly') })
    $select = @($eligible | Where-Object { -not $_.Selected }).Count -gt 0
    foreach ($member in $Row.Members) {
        if ($select) {
            if ($eligible -contains $member) { $member.Selected = $true }
        }
        else {
            $member.Selected = $false
        }
    }
}

function Get-ResikPickerGroupBox {
    # [x] when every selectable part is selected, [~] for some, [ ] for none,
    # and [-] when no part can be selected.
    [CmdletBinding()]
    [OutputType([string])]
    param([object] $Row)

    $selectable = @($Row.Members | Where-Object { $_.Selectable })
    if ($selectable.Count -eq 0) { return '[-]' }
    $selected = @($selectable | Where-Object { $_.Selected }).Count
    if ($selected -eq 0) { return '[ ]' }
    if ($selected -eq $selectable.Count) { return '[x]' }
    '[~]'
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
    # 'Cancel'. 'Click' moves the cursor to Row (an index into State.Rows, or
    # -1 for a click outside the list) and toggles it.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $State,

        [Parameter(Mandatory)]
        [string] $Command,

        [int] $Row = -1
    )

    $count = $State.Rows.Count
    switch ($Command) {
        'Click' {
            if ($Row -ge 0 -and $Row -lt $count) {
                $State.Cursor = $Row
                Switch-ResikPickerRow -Row $State.Rows[$Row]
            }
            return 'Continue'
        }
        'Up' {
            if ($count -gt 0) { $State.Cursor = ($State.Cursor - 1 + $count) % $count }
            return 'Continue'
        }
        'Down' {
            if ($count -gt 0) { $State.Cursor = ($State.Cursor + 1) % $count }
            return 'Continue'
        }
        'Toggle' {
            if ($count -gt 0) { Switch-ResikPickerRow -Row $State.Rows[$State.Cursor] }
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
        [object] $Item,

        [int] $IdWidth = 12,

        [int] $NameWidth = 24,

        # Parts of a group are indented under its heading.
        [int] $Indent = 0
    )

    $target = $Item.Target
    $size = if ($null -eq $Item.EstimatedBytes) { '?' } else { Format-ResikSize $Item.EstimatedBytes }
    if ($Item.Note -and $null -eq $Item.EstimatedBytes) { $size = '' }
    $name = Limit-ResikText $target.Name $NameWidth
    $id = ('  ' * $Indent) + $target.Id
    ("{0,-$IdWidth}  {1,-$NameWidth}  {2,9}  {3,-6}  {4}" -f $id, $name, $size, "$($target.RiskLevel)", $Item.Note).TrimEnd()
}

function Format-ResikPickerGroupRow {
    # A group heading: its name across the ID and name columns, and the total
    # size of its parts.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Row,

        [int] $IdWidth = 12,

        [int] $NameWidth = 24
    )

    $total = $null
    foreach ($member in $Row.Members) {
        if ($null -ne $member.EstimatedBytes) { $total = [long]$total + $member.EstimatedBytes }
    }
    $size = if ($null -eq $total) { '' } else { Format-ResikSize $total }
    $width = $IdWidth + 2 + $NameWidth
    $note = ''
    if (@($Row.Members | Where-Object { $_.Selectable }).Count -eq 0) { $note = "$($Row.Members[0].Note)" }
    ("{0,-$width}  {1,9}  {2,-6}  {3}" -f (Limit-ResikText $Row.Name $width), $size, '', $note).TrimEnd()
}

function Get-ResikPickerLayout {
    # Column widths that fit every row of the picker.
    [CmdletBinding()]
    param([object] $State)

    $idWidth = 2
    $nameWidth = 4
    foreach ($row in $State.Rows) {
        if ($row.Kind -ne 'Item') { continue }
        $idWidth = [Math]::Max($idWidth, $row.Item.Target.Id.Length + 2 * $row.Indent)
        $nameWidth = [Math]::Max($nameWidth, $row.Item.Target.Name.Length)
    }
    [pscustomobject]@{ IdWidth = $idWidth; NameWidth = [Math]::Min($nameWidth, 30) }
}

function Format-ResikPickerScreen {
    # Returns the lines to draw as objects with Text, Color ($null for the
    # default color), and Row (the index into State.Rows a click on the line
    # selects, or -1). Every line is padded or cut to Width - 1 characters so
    # that redrawing in place never wraps, and the line count never changes.
    # With a Height, the screen has at most Height - 1 lines, so drawing it
    # never scrolls the window: when the rows do not fit, only the rows around
    # the cursor are drawn (State.Top), and the blank lines around the list
    # say how many rows are hidden above and below.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $State,

        [string] $Title = 'Select targets to clean',

        [ValidateRange(20, 10000)]
        [int] $Width = 80,

        # The window height in lines; 0 draws every row.
        [ValidateRange(0, 10000)]
        [int] $Height = 0,

        # The console reports mouse clicks, so the help line mentions them.
        [switch] $Mouse
    )

    $lines = New-Object System.Collections.Generic.List[object]
    $limit = $Width - 1
    $addLine = {
        param([string] $Text, $Color = $null, [int] $Row = -1)
        if ($Text.Length -gt $limit) { $Text = $Text.Substring(0, $limit - 3) + '...' }
        $lines.Add([pscustomobject]@{ Text = $Text.PadRight($limit); Color = $Color; Row = $Row })
    }

    $columns = Get-ResikPickerLayout -State $State
    $header = '      ' + ("{0,-$($columns.IdWidth)}  {1,-$($columns.NameWidth)}  {2,9}  {3}" -f 'Target', '', 'Size', 'Risk')
    $help = if ($Mouse) {
        'Up/Down move   Space or click select   A all   N none   Enter confirm   Q cancel'
    }
    else {
        'Up/Down move   Space select   A all   N none   Enter confirm   Q cancel'
    }

    # Seven lines besides the rows: title, help, the line above the header,
    # header, the line below the rows, details, and the selected total.
    $count = $State.Rows.Count
    $visible = $count
    if ($Height -gt 0) { $visible = [Math]::Min($count, [Math]::Max(1, $Height - 1 - 7)) }
    Update-ResikPickerScroll -State $State -Visible $visible
    $first = [int]$State.Top
    $last = $first + $visible
    $above = if ($first -gt 0) { "  ^ $first more above" } else { '' }
    $below = if ($last -lt $count) { "  v $($count - $last) more below" } else { '' }

    & $addLine $Title 'White'
    & $addLine $help 'DarkGray'
    & $addLine $above 'DarkGray'
    & $addLine $header 'DarkGray'

    for ($index = $first; $index -lt $last; $index++) {
        $row = $State.Rows[$index]
        $isCursor = $index -eq $State.Cursor
        $pointer = if ($isCursor) { '>' } else { ' ' }
        if ($row.Kind -eq 'Group') {
            $box = Get-ResikPickerGroupBox -Row $row
            $text = Format-ResikPickerGroupRow -Row $row -IdWidth $columns.IdWidth -NameWidth $columns.NameWidth
            $color = if ($isCursor) { 'Cyan' } elseif ($box -eq '[-]') { 'DarkGray' } elseif ($box -eq '[x]') { 'Green' } else { 'White' }
        }
        else {
            $item = $row.Item
            $box = if (-not $item.Selectable) { '[-]' } elseif ($item.Selected) { '[x]' } else { '[ ]' }
            $text = Format-ResikPickerRow $item -IdWidth $columns.IdWidth -NameWidth $columns.NameWidth -Indent $row.Indent
            $color = if ($isCursor) { 'Cyan' } elseif (-not $item.Selectable) { 'DarkGray' } elseif ($item.Selected) { 'Green' } else { $null }
        }
        & $addLine "$pointer $box $text" $color $index
    }

    & $addLine $below 'DarkGray'
    $details = ''
    if ($State.Rows.Count -gt 0) {
        $current = $State.Rows[$State.Cursor]
        $details = if ($current.Kind -eq 'Group') {
            "Selecting $($current.Name) selects all its parts except those that must be chosen one by one."
        }
        else {
            $current.Item.Details
        }
    }
    & $addLine "  $details" 'DarkGray'

    $selected = @($State.Items | Where-Object { $_.Selected })
    $total = [long]0
    foreach ($item in $selected) { if ($null -ne $item.EstimatedBytes) { $total += $item.EstimatedBytes } }
    & $addLine "  Selected: $(Format-ResikCount $selected.Count), about $(Format-ResikSize $total)"

    $lines.ToArray()
}

function Get-ResikConsoleWidth {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    try { [Math]::Max(20, [Console]::WindowWidth) } catch { 80 }
}

function Get-ResikConsoleHeight {
    # The window height in lines, or 0 when it cannot be read (then the
    # picker draws every row).
    [CmdletBinding()]
    [OutputType([int])]
    param()
    try { [Math]::Max(0, [Console]::WindowHeight) } catch { 0 }
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

function Get-ResikConsoleInputSource {
    # C# for reading keys and mouse events from the console input buffer with
    # the documented Win32 calls GetConsoleMode, SetConsoleMode, and
    # ReadConsoleInputW. [Console]::ReadKey reports keys only.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    @'
using System;
using System.Runtime.InteropServices;

namespace Resik
{
    public class ConsoleInputEvent
    {
        public string Kind;        // Key, Click, or Wheel
        public ConsoleKey Key;
        public char Character;
        public int X;
        public int Y;
        public int Delta;          // Wheel: positive away from the user
    }

    public static class ConsoleInput
    {
        const int StdInputHandle = -10;
        const uint EnableMouseInput = 0x0010;
        const uint EnableQuickEditMode = 0x0040;
        const uint EnableExtendedFlags = 0x0080;
        const ushort KeyEventType = 0x0001;
        const ushort MouseEventType = 0x0002;
        const uint FromLeft1stButtonPressed = 0x0001;
        const uint DoubleClick = 0x0002;
        const uint MouseWheeled = 0x0004;

        [StructLayout(LayoutKind.Explicit)]
        struct InputRecord
        {
            [FieldOffset(0)] public ushort EventType;
            [FieldOffset(4)] public int KeyDown;
            [FieldOffset(8)] public ushort KeyRepeatCount;
            [FieldOffset(10)] public ushort KeyVirtualKeyCode;
            [FieldOffset(12)] public ushort KeyVirtualScanCode;
            [FieldOffset(14)] public ushort KeyUnicodeChar;
            [FieldOffset(16)] public uint KeyControlKeyState;
            [FieldOffset(4)] public short MouseX;
            [FieldOffset(6)] public short MouseY;
            [FieldOffset(8)] public uint MouseButtonState;
            [FieldOffset(12)] public uint MouseControlKeyState;
            [FieldOffset(16)] public uint MouseEventFlags;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr GetStdHandle(int handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetConsoleMode(IntPtr handle, out uint mode);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetConsoleMode(IntPtr handle, uint mode);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "ReadConsoleInputW")]
        static extern bool ReadConsoleInput(IntPtr handle, [Out] InputRecord[] buffer, uint length, out uint read);

        static IntPtr Input { get { return GetStdHandle(StdInputHandle); } }

        // Turns on mouse input and turns off Quick Edit, which would otherwise
        // take clicks for text selection. Returns the previous mode.
        public static uint EnableMouse()
        {
            uint mode;
            if (!GetConsoleMode(Input, out mode))
            {
                throw new InvalidOperationException("The console input mode could not be read.");
            }
            uint mouseMode = (mode | EnableMouseInput | EnableExtendedFlags) & ~EnableQuickEditMode;
            if (!SetConsoleMode(Input, mouseMode))
            {
                throw new InvalidOperationException("The console input mode could not be changed.");
            }
            return mode;
        }

        public static void Restore(uint mode)
        {
            SetConsoleMode(Input, mode | EnableExtendedFlags);
        }

        // Waits up to timeout milliseconds for a key press, a left click, or a
        // wheel turn, and returns null when none arrived, so the caller can
        // notice Ctrl+C between calls.
        public static ConsoleInputEvent Read(int timeout)
        {
            InputRecord[] records = new InputRecord[1];
            DateTime end = DateTime.UtcNow.AddMilliseconds(timeout);
            while (true)
            {
                int left = (int)(end - DateTime.UtcNow).TotalMilliseconds;
                if (left <= 0 || WaitForSingleObject(Input, (uint)left) != 0)
                {
                    return null;
                }
                uint read;
                if (!ReadConsoleInput(Input, records, 1, out read) || read == 0)
                {
                    return null;
                }
                InputRecord record = records[0];
                if (record.EventType == KeyEventType && record.KeyDown != 0)
                {
                    ConsoleInputEvent key = new ConsoleInputEvent();
                    key.Kind = "Key";
                    key.Key = (ConsoleKey)record.KeyVirtualKeyCode;
                    key.Character = (char)record.KeyUnicodeChar;
                    return key;
                }
                if (record.EventType == MouseEventType)
                {
                    uint flags = record.MouseEventFlags;
                    bool press = (flags == 0 || flags == DoubleClick) &&
                        (record.MouseButtonState & FromLeft1stButtonPressed) != 0;
                    if (press || flags == MouseWheeled)
                    {
                        ConsoleInputEvent mouse = new ConsoleInputEvent();
                        mouse.Kind = press ? "Click" : "Wheel";
                        mouse.X = record.MouseX;
                        mouse.Y = record.MouseY;
                        mouse.Delta = (short)(record.MouseButtonState >> 16);
                        return mouse;
                    }
                }
            }
        }
    }
}
'@
}

function Enable-ResikPickerMouse {
    # Turns on mouse input for the picker. Returns the previous console input
    # mode to pass to Disable-ResikPickerMouse, or $null when the console
    # cannot report mouse events (then the picker uses the keyboard only).
    [CmdletBinding()]
    param()

    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { return $null }
    try {
        if ($null -eq ('Resik.ConsoleInput' -as [type])) {
            Add-Type -TypeDefinition (Get-ResikConsoleInputSource) -ErrorAction Stop
        }
        [Resik.ConsoleInput]::EnableMouse()
    }
    catch {
        Write-Verbose "Mouse input is unavailable: $($_.Exception.Message)"
        $null
    }
}

function Disable-ResikPickerMouse {
    [CmdletBinding()]
    param([object] $Mode)

    if ($null -eq $Mode) { return }
    try { [Resik.ConsoleInput]::Restore([uint32]$Mode) } catch { Write-Verbose 'Could not restore the console input mode.' }
}

function Read-ResikPickerEvent {
    # Waits for a key, click, or wheel turn while mouse input is on. Returns a
    # picker command, or for a click an object with Command 'Click' and the
    # clicked console row Y.
    [CmdletBinding()]
    param()

    while ($true) {
        $inputEvent = [Resik.ConsoleInput]::Read(100)
        if ($null -eq $inputEvent) { continue }
        switch ($inputEvent.Kind) {
            'Key' { return ConvertFrom-ResikConsoleKey -Key $inputEvent.Key -Character $inputEvent.Character }
            'Wheel' { if ($inputEvent.Delta -gt 0) { return 'Up' } else { return 'Down' } }
            'Click' { return [pscustomobject]@{ Command = 'Click'; Y = $inputEvent.Y } }
        }
    }
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
    $mouseMode = Enable-ResikPickerMouse
    try {
        $origin = $null
        $drawn = 0
        while ($true) {
            $width = Get-ResikConsoleWidth
            $lines = @(Format-ResikPickerScreen -State $State -Title $Title -Width $width -Height (Get-ResikConsoleHeight) -Mouse:($null -ne $mouseMode))
            if ($null -ne $origin) { Move-ResikConsoleCursor -Row $origin }
            foreach ($line in $lines) {
                if ($line.Color) { Write-Host $line.Text -ForegroundColor $line.Color } else { Write-Host $line.Text }
            }
            # A window made shorter draws fewer lines; blank the rest of the
            # previous drawing.
            $blank = ''.PadRight([Math]::Max(0, $width - 1))
            for ($extra = $lines.Count; $extra -lt $drawn; $extra++) { Write-Host $blank }
            $drawn = [Math]::Max($lines.Count, $drawn)
            # Measured after every draw, because drawing can scroll the window.
            $origin = (Get-ResikConsoleCursorRow) - $drawn

            $next = if ($null -ne $mouseMode) { Read-ResikPickerEvent } else { Read-ResikPickerKey }
            if ($next -is [string]) {
                $action = Invoke-ResikPickerKey -State $State -Command $next
            }
            else {
                # A click is in console rows; find the picker row drawn there.
                $line = $next.Y - $origin
                $row = if ($line -ge 0 -and $line -lt $lines.Count) { $lines[$line].Row } else { -1 }
                $action = Invoke-ResikPickerKey -State $State -Command $next.Command -Row $row
            }
            if ($action -ne 'Continue') { return $action }
        }
    }
    finally {
        Disable-ResikPickerMouse -Mode $mouseMode
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
    $columns = Get-ResikPickerLayout -State $State
    $number = 0
    foreach ($row in $State.Rows) {
        if ($row.Kind -eq 'Group') {
            Write-Host "     $(Format-ResikPickerGroupRow -Row $row -IdWidth $columns.IdWidth -NameWidth $columns.NameWidth)"
            continue
        }
        $item = $row.Item
        $label = if ($item.Selectable) { $number++; '{0,3})' -f $number } else { '   -' }
        Write-Host "$label $(Format-ResikPickerRow $item -IdWidth $columns.IdWidth -NameWidth $columns.NameWidth -Indent $row.Indent)"
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
