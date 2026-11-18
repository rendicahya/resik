BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')

    function New-TestPickerState {
        # Targets: 'uv' (cleanable, 2 KB), 'scoop' (not found), 'pip' (cleanable, 1 KB),
        # 'conda' (analysis only).
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates an in-memory object only.')]
        param()
        $clean = { [pscustomobject]@{ Status = 'Success' } }
        $targets = @(
            (New-TestTarget -Id 'uv' -Clean $clean),
            (New-TestTarget -Id 'scoop' -Clean $clean),
            (New-TestTarget -Id 'pip' -Clean $clean),
            (New-TestTarget -Id 'conda')
        )
        $analysis = @(
            (New-ResikResult -TargetId 'uv' -Operation Analyze -Status AnalysisOnly -EstimatedBytes 2048 -Message 'C:\uv\cache'),
            (New-ResikResult -TargetId 'scoop' -Operation Analyze -Status Skipped -Message 'Not detected: scoop was not found on PATH.'),
            (New-ResikResult -TargetId 'pip' -Operation Analyze -Status AnalysisOnly -EstimatedBytes 1024),
            (New-ResikResult -TargetId 'conda' -Operation Analyze -Status AnalysisOnly -EstimatedBytes 4096)
        )
        New-ResikPickerState -Targets $targets -Analysis $analysis
    }

    function New-TestGroupedState {
        # 'uv' (2 KB), a group 'B' of 'b-cache' (1 KB), 'b-code' (3 KB), and
        # the explicit-only 'b-sw' (512 B), and 'pip' (1 KB).
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates an in-memory object only.')]
        param()
        $clean = { [pscustomobject]@{ Status = 'Success' } }
        $targets = @(
            (New-TestTarget -Id 'uv' -Clean $clean),
            (New-TestTarget -Id 'b-cache' -Clean $clean -Group 'B'),
            (New-TestTarget -Id 'b-code' -Clean $clean -Group 'B'),
            (New-TestTarget -Id 'b-sw' -Clean $clean -Group 'B' -ExplicitOnly),
            (New-TestTarget -Id 'pip' -Clean $clean)
        )
        $sizes = @{ 'uv' = 2048; 'b-cache' = 1024; 'b-code' = 3072; 'b-sw' = 512; 'pip' = 1024 }
        $analysis = @(foreach ($id in $sizes.Keys) {
                New-ResikResult -TargetId $id -Operation Analyze -Status AnalysisOnly -EstimatedBytes $sizes[$id]
            })
        New-ResikPickerState -Targets $targets -Analysis $analysis
    }
}

Describe 'Picker groups' {
    It 'keeps a group together in catalog order, sorted by its total size' {
        $state = New-TestGroupedState
        @($state.Items | ForEach-Object { $_.Target.Id }) | Should -Be @('b-cache', 'b-code', 'b-sw', 'uv', 'pip')
        @($state.Rows | ForEach-Object { $_.Kind }) | Should -Be @('Group', 'Item', 'Item', 'Item', 'Item', 'Item')
        $state.Rows[0].Name | Should -BeExactly 'B'
        @($state.Rows | ForEach-Object { $_.Indent }) | Should -Be @(0, 1, 1, 1, 0, 0)
    }

    It 'puts a ListFirst target first among the cleanable ones, even without a size' {
        $clean = { [pscustomobject]@{ Status = 'Success' } }
        $targets = @(
            (New-TestTarget -Id 'big' -Clean $clean),
            (New-TestTarget -Id 'update' -Clean $clean -ListFirst),
            (New-TestTarget -Id 'report' -ListFirst)
        )
        $analysis = @(
            (New-ResikResult -TargetId 'big' -Operation Analyze -Status AnalysisOnly -EstimatedBytes 4096),
            (New-ResikResult -TargetId 'update' -Operation Analyze -Status AnalysisOnly),
            (New-ResikResult -TargetId 'report' -Operation Analyze -Status AnalysisOnly -EstimatedBytes 8192)
        )
        $state = New-ResikPickerState -Targets $targets -Analysis $analysis
        @($state.Items | ForEach-Object { $_.Target.Id }) | Should -Be @('update', 'big', 'report')
    }

    It 'shows a group of one target as a plain row' {
        $target = New-TestTarget -Id 'x' -Clean { } -Group 'X'
        $analysis = New-ResikResult -TargetId 'x' -Operation Analyze -Status AnalysisOnly
        $state = New-ResikPickerState -Targets @($target) -Analysis @($analysis)
        @($state.Rows | ForEach-Object { $_.Kind }) | Should -Be @('Item')
        $state.Rows[0].Indent | Should -Be 0
    }

    It 'selects every part but explicit-only ones from the heading, then clears them' {
        $state = New-TestGroupedState
        Invoke-ResikPickerKey -State $state -Command Toggle | Out-Null
        @($state.Items | Where-Object Selected | ForEach-Object { $_.Target.Id }) | Should -Be @('b-cache', 'b-code')
        Get-ResikPickerGroupBox -Row $state.Rows[0] | Should -BeExactly '[~]'

        Invoke-ResikPickerKey -State $state -Command Toggle | Out-Null
        @($state.Items | Where-Object Selected).Count | Should -Be 0
        Get-ResikPickerGroupBox -Row $state.Rows[0] | Should -BeExactly '[ ]'
    }

    It 'shows [x] when every part is selected, and clears them all from the heading' {
        $state = New-TestGroupedState
        foreach ($item in $state.Items) { if ($item.Target.Group -eq 'B') { $item.Selected = $true } }
        Get-ResikPickerGroupBox -Row $state.Rows[0] | Should -BeExactly '[x]'

        Invoke-ResikPickerKey -State $state -Command Toggle | Out-Null
        @($state.Items | Where-Object Selected).Count | Should -Be 0
    }

    It 'draws the heading with the total size and indents its parts' {
        $state = New-TestGroupedState
        $state.Cursor = 2
        $text = @(Format-ResikPickerScreen -State $state -Width 100 | ForEach-Object { $_.Text.TrimEnd() })
        $text[3..9] | Should -Be @(
            '      Target                        Size  Risk'
            '  [ ] B                           4.5 KB'
            '  [ ]   b-cache  Fake b-cache     1.0 KB  Low'
            '> [ ]   b-code   Fake b-code      3.0 KB  Low'
            '  [ ]   b-sw     Fake b-sw         512 B  Low'
            '  [ ] uv         Fake uv          2.0 KB  Low'
            '  [ ] pip        Fake pip         1.0 KB  Low'
        )
    }

    It 'explains the heading in the details line' {
        $state = New-TestGroupedState
        $text = @(Format-ResikPickerScreen -State $state -Width 200 | ForEach-Object { $_.Text.TrimEnd() })
        $text[-2] | Should -BeExactly '  Selecting B selects all its parts except those that must be chosen one by one.'
    }

    It 'lists headings without numbers in the numbered fallback' {
        Mock Write-Host {}
        Mock Read-ResikLine { '2' }
        $state = New-TestGroupedState

        Read-ResikNumberedSelection -State $state | Should -BeExactly 'Confirm'

        @($state.Items | Where-Object Selected | ForEach-Object { $_.Target.Id }) | Should -Be @('b-code')
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '     B *' }
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '  2)   b-code *' }
    }
}

Describe 'Get-ResikConsoleInputSource' {
    It 'compiles' {
        if ($null -eq ('Resik.ConsoleInput' -as [type])) {
            Add-Type -TypeDefinition (Get-ResikConsoleInputSource) -ErrorAction Stop
        }
        'Resik.ConsoleInput' -as [type] | Should -Not -BeNullOrEmpty
        [Resik.ConsoleInput].GetMethod('Read') | Should -Not -BeNullOrEmpty
    }
}

Describe 'Browser groups in the catalog' {
    It 'groups each browser''s parts, and edge-profile with Edge, but not app caches' {
        $catalog = @(Get-ResikTargetCatalog)
        $group = @{}
        foreach ($target in $catalog) { $group[$target.Id] = $target.Group }
        $group['chrome-cache'] | Should -BeExactly 'Google Chrome'
        $group['comet-service-workers'] | Should -BeExactly 'Comet'
        $group['edge-gpu-cache'] | Should -BeExactly 'Microsoft Edge'
        $group['edge-profile'] | Should -BeExactly 'Microsoft Edge'
        $group['vscode-cache'] | Should -BeExactly ''
        $group['uv'] | Should -BeExactly ''
    }
}

Describe 'Picker clicks' {
    It 'moves the cursor to the clicked row and toggles it' {
        $state = New-TestGroupedState
        Invoke-ResikPickerKey -State $state -Command Click -Row 4 | Should -BeExactly 'Continue'
        $state.Cursor | Should -Be 4
        @($state.Items | Where-Object Selected | ForEach-Object { $_.Target.Id }) | Should -Be @('uv')
    }

    It 'ignores a click outside the list' {
        $state = New-TestGroupedState
        Invoke-ResikPickerKey -State $state -Command Click -Row -1 | Out-Null
        Invoke-ResikPickerKey -State $state -Command Click -Row 99 | Out-Null
        $state.Cursor | Should -Be 0
        @($state.Items | Where-Object Selected).Count | Should -Be 0
    }

    It 'marks which row each screen line selects' {
        $state = New-TestPickerState
        @(Format-ResikPickerScreen -State $state | ForEach-Object { $_.Row }) | Should -Be @(-1, -1, -1, -1, 0, 1, 2, -1, -1, -1)
    }
}

Describe 'New-ResikPickerState' {
    It 'makes only cleanable, analyzed targets selectable, and selects nothing' {
        $state = New-TestPickerState

        @($state.Items | ForEach-Object { $_.Selectable }) | Should -Be @($true, $true, $false)
        @($state.Items | Where-Object Selected).Count | Should -Be 0
        $state.Cursor | Should -Be 0
    }

    It 'lists cleanable targets by size, then report-only ones, and leaves out missing tools' {
        $state = New-TestPickerState
        @($state.Items | ForEach-Object { $_.Target.Id }) | Should -Be @('uv', 'pip', 'conda')
        $state.Items[2].Note | Should -BeExactly 'report only'
        $state.Items[0].Note | Should -BeExactly ''
        $state.Items[0].Details | Should -BeExactly 'C:\uv\cache'
    }

    It 'marks a failed analysis' {
        $target = New-TestTarget -Id 'x' -Clean { }
        $analysis = New-ResikResult -TargetId 'x' -Operation Analyze -Status Failed -Message 'Analysis failed: boom'
        $state = New-ResikPickerState -Targets @($target) -Analysis @($analysis)

        $state.Items[0].Selectable | Should -BeFalse
        $state.Items[0].Note | Should -BeExactly 'analysis failed'
    }
}

Describe 'ConvertFrom-ResikConsoleKey' {
    It 'maps <Key> <Character> to <Expected>' -ForEach @(
        @{ Key = 'UpArrow'; Character = [char]0; Expected = 'Up' }
        @{ Key = 'DownArrow'; Character = [char]0; Expected = 'Down' }
        @{ Key = 'Spacebar'; Character = [char]' '; Expected = 'Toggle' }
        @{ Key = 'Enter'; Character = [char]13; Expected = 'Confirm' }
        @{ Key = 'Escape'; Character = [char]27; Expected = 'Cancel' }
        @{ Key = 'A'; Character = [char]'a'; Expected = 'All' }
        @{ Key = 'A'; Character = [char]'A'; Expected = 'All' }
        @{ Key = 'N'; Character = [char]'n'; Expected = 'None' }
        @{ Key = 'Q'; Character = [char]'q'; Expected = 'Cancel' }
        @{ Key = 'X'; Character = [char]'x'; Expected = 'Other' }
    ) {
        ConvertFrom-ResikConsoleKey -Key $Key -Character $Character | Should -BeExactly $Expected
    }
}

Describe 'Invoke-ResikPickerKey' {
    BeforeEach {
        $script:state = New-TestPickerState
    }

    It 'moves the cursor and wraps around' {
        Invoke-ResikPickerKey -State $script:state -Command Up | Should -BeExactly 'Continue'
        $script:state.Cursor | Should -Be 2
        Invoke-ResikPickerKey -State $script:state -Command Down | Out-Null
        $script:state.Cursor | Should -Be 0
        Invoke-ResikPickerKey -State $script:state -Command Down | Out-Null
        $script:state.Cursor | Should -Be 1
    }

    It 'toggles the item under the cursor' {
        Invoke-ResikPickerKey -State $script:state -Command Toggle | Out-Null
        $script:state.Items[0].Selected | Should -BeTrue
        Invoke-ResikPickerKey -State $script:state -Command Toggle | Out-Null
        $script:state.Items[0].Selected | Should -BeFalse
    }

    It 'does not select an unavailable item' {
        $script:state.Cursor = 2
        Invoke-ResikPickerKey -State $script:state -Command Toggle | Out-Null
        $script:state.Items[2].Selected | Should -BeFalse
    }

    It 'selects all selectable items, then none' {
        Invoke-ResikPickerKey -State $script:state -Command All | Out-Null
        @($script:state.Items | ForEach-Object { $_.Selected }) | Should -Be @($true, $true, $false)

        Invoke-ResikPickerKey -State $script:state -Command None | Out-Null
        @($script:state.Items | Where-Object Selected).Count | Should -Be 0
    }

    It 'returns <Expected> for <Command>' -ForEach @(
        @{ Command = 'Confirm'; Expected = 'Confirm' }
        @{ Command = 'Cancel'; Expected = 'Cancel' }
        @{ Command = 'Other'; Expected = 'Continue' }
    ) {
        Invoke-ResikPickerKey -State $script:state -Command $Command | Should -BeExactly $Expected
    }
}

Describe 'Format-ResikPickerScreen' {
    It 'shows checkboxes, the cursor, details, and the selected total, but not missing tools' {
        $state = New-TestPickerState
        $state.Items[0].Selected = $true
        $state.Items[1].Selected = $true

        $lines = @(Format-ResikPickerScreen -State $state -Width 100)
        $text = @($lines | ForEach-Object { $_.Text.TrimEnd() })

        $text | Should -Be @(
            'Select targets to clean'
            'Up/Down move   Space select   A all   N none   Enter confirm   Q cancel'
            ''
            '      Target                   Size  Risk'
            '> [x] uv     Fake uv        2.0 KB  Low'
            '  [x] pip    Fake pip       1.0 KB  Low'
            '  [-] conda  Fake conda     4.0 KB  Low     report only'
            ''
            '  C:\uv\cache'
            '  Selected: 2 targets, about 3.0 KB'
        )
        $lines[4].Color | Should -BeExactly 'Cyan'
        $lines[5].Color | Should -BeExactly 'Green'
        $lines[6].Color | Should -BeExactly 'DarkGray'
    }

    It 'keeps every line exactly one character narrower than the window' {
        $state = New-TestPickerState
        foreach ($line in (Format-ResikPickerScreen -State $state -Width 40)) {
            $line.Text.Length | Should -Be 39
        }
    }

    It 'always has the same number of lines' {
        $state = New-TestPickerState
        $before = @(Format-ResikPickerScreen -State $state).Count
        Invoke-ResikPickerKey -State $state -Command Down | Out-Null
        Invoke-ResikPickerKey -State $state -Command All | Out-Null
        @(Format-ResikPickerScreen -State $state).Count | Should -Be $before
        $before | Should -Be ($state.Items.Count + 7)
    }
}

Describe 'Show-ResikTargetPicker' {
    BeforeEach {
        Mock Write-Host {}
        Mock Get-ResikConsoleWidth { 100 }
        Mock Get-ResikConsoleCursorRow { 50 }
        Mock Move-ResikConsoleCursor {}
        $script:keys = New-Object System.Collections.Generic.Queue[string]
        Mock Read-ResikPickerKey { $script:keys.Dequeue() }
    }

    It 'returns the selection made with the keys' {
        foreach ($key in @('Down', 'Toggle', 'Confirm')) { $script:keys.Enqueue($key) }
        $state = New-TestPickerState

        Show-ResikTargetPicker -State $state | Should -BeExactly 'Confirm'

        @($state.Items | Where-Object Selected | ForEach-Object { $_.Target.Id }) | Should -Be @('pip')
    }

    It 'redraws in place from where the first drawing started' {
        foreach ($key in @('Down', 'Cancel')) { $script:keys.Enqueue($key) }
        $state = New-TestPickerState

        Show-ResikTargetPicker -State $state | Should -BeExactly 'Cancel'

        Should -Invoke Move-ResikConsoleCursor -Times 1 -Exactly -ParameterFilter { $Row -eq (50 - ($state.Items.Count + 7)) }
    }

    It 'toggles the row under a mouse click and restores the console afterwards' {
        Mock Enable-ResikPickerMouse { 7 }
        Mock Disable-ResikPickerMouse {}
        $script:events = New-Object System.Collections.Generic.Queue[object]
        Mock Read-ResikPickerEvent { $script:events.Dequeue() }
        $state = New-TestPickerState
        # The screen is 10 lines drawn up to row 50, so it starts at row 40;
        # its first target row (uv) is row 44 and pip is row 45.
        $script:events.Enqueue([pscustomobject]@{ Command = 'Click'; Y = 45 })
        $script:events.Enqueue([pscustomobject]@{ Command = 'Click'; Y = 2 })
        $script:events.Enqueue('Confirm')

        Show-ResikTargetPicker -State $state | Should -BeExactly 'Confirm'

        @($state.Items | Where-Object Selected | ForEach-Object { $_.Target.Id }) | Should -Be @('pip')
        Should -Invoke Read-ResikPickerKey -Times 0 -Exactly
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*Space or click select*' }
        Should -Invoke Disable-ResikPickerMouse -Times 1 -Exactly -ParameterFilter { $Mode -eq 7 }
    }
}

Describe 'ConvertFrom-ResikNumberedSelection' {
    It 'reads "<Text>" as <Action> <Expected>' -ForEach @(
        @{ Text = '1,3'; Action = 'Select'; Expected = @(0, 2) }
        @{ Text = ' 3 1 '; Action = 'Select'; Expected = @(2, 0) }
        @{ Text = '2,2'; Action = 'Select'; Expected = @(1) }
        @{ Text = 'a'; Action = 'Select'; Expected = @(0, 1, 2) }
        @{ Text = 'ALL'; Action = 'Select'; Expected = @(0, 1, 2) }
        @{ Text = ''; Action = 'Cancel'; Expected = @() }
        @{ Text = '0'; Action = 'Invalid'; Expected = @() }
        @{ Text = '4'; Action = 'Invalid'; Expected = @() }
        @{ Text = 'uv'; Action = 'Invalid'; Expected = @() }
    ) {
        $parsed = ConvertFrom-ResikNumberedSelection -Text $Text -Count 3
        $parsed.Action | Should -BeExactly $Action
        @($parsed.Indexes) | Should -Be $Expected
    }

    It 'selects nothing for "a" when nothing is selectable' {
        @((ConvertFrom-ResikNumberedSelection -Text 'a' -Count 0).Indexes).Count | Should -Be 0
    }
}

Describe 'Read-ResikNumberedSelection' {
    BeforeEach {
        Mock Write-Host {}
        $script:answers = New-Object System.Collections.Generic.Queue[object]
        Mock Read-ResikLine { $script:answers.Dequeue() }
    }

    It 'numbers only selectable targets and asks again after an invalid answer' {
        $script:answers.Enqueue('7')
        $script:answers.Enqueue('2')
        $state = New-TestPickerState

        Read-ResikNumberedSelection -State $state | Should -BeExactly 'Confirm'

        # Number 2 is pip; scoop was not found and has no row.
        @($state.Items | Where-Object Selected | ForEach-Object { $_.Target.Id }) | Should -Be @('pip')
        Should -Invoke Read-ResikLine -Times 2 -Exactly
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '  2) pip *' }
    }

    It 'cancels on an empty answer or the end of input' -ForEach @(@{ Answer = '' }, @{ Answer = $null }) {
        $script:answers.Enqueue($Answer)
        $state = New-TestPickerState

        Read-ResikNumberedSelection -State $state | Should -BeExactly 'Cancel'
        @($state.Items | Where-Object Selected).Count | Should -Be 0
    }
}

Describe 'Select-ResikTargetInteractive' {
    It 'returns the targets picked in the numbered list' {
        Mock Write-Host {}
        Mock Read-ResikLine { 'a' }
        $targets = @((New-TestTarget -Id 'x' -Clean { }), (New-TestTarget -Id 'y' -Clean { }))
        $analysis = @(
            (New-ResikResult -TargetId 'x' -Operation Analyze -Status AnalysisOnly),
            (New-ResikResult -TargetId 'y' -Operation Analyze -Status AnalysisOnly)
        )

        $choice = Select-ResikTargetInteractive -Targets $targets -Analysis $analysis -Mode Numbered

        $choice.Cancelled | Should -BeFalse
        @($choice.Targets | ForEach-Object Id) | Should -Be @('x', 'y')
    }

    It 'says nothing will change in a dry run' {
        Mock Write-Host {}
        Mock Read-ResikLine { '' }
        $target = New-TestTarget -Id 'x' -Clean { }
        $analysis = New-ResikResult -TargetId 'x' -Operation Analyze -Status AnalysisOnly

        $choice = Select-ResikTargetInteractive -Targets @($target) -Analysis @($analysis) -Mode Numbered -DryRun

        $choice.Cancelled | Should -BeTrue
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*dry run; nothing will be changed*' }
    }
}
