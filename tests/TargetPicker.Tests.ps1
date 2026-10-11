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
}

Describe 'New-ResikPickerState' {
    It 'makes only cleanable, analyzed targets selectable, and selects nothing' {
        $state = New-TestPickerState

        @($state.Items | ForEach-Object { $_.Selectable }) | Should -Be @($true, $false, $true, $false)
        @($state.Items | Where-Object Selected).Count | Should -Be 0
        $state.Cursor | Should -Be 0
    }

    It 'explains why a target cannot be selected' {
        $state = New-TestPickerState
        $state.Items[1].Note | Should -BeExactly 'not found'
        $state.Items[1].Details | Should -BeLike '*scoop was not found*'
        $state.Items[3].Note | Should -BeExactly 'analysis only'
        $state.Items[0].Note | Should -BeExactly '2.0 KB'
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
        $script:state.Cursor | Should -Be 3
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
        $script:state.Cursor = 1
        Invoke-ResikPickerKey -State $script:state -Command Toggle | Out-Null
        $script:state.Items[1].Selected | Should -BeFalse
    }

    It 'selects all selectable items, then none' {
        Invoke-ResikPickerKey -State $script:state -Command All | Out-Null
        @($script:state.Items | ForEach-Object { $_.Selected }) | Should -Be @($true, $false, $true, $false)

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
    It 'shows checkboxes, the cursor, details, and the selected total' {
        $state = New-TestPickerState
        $state.Items[0].Selected = $true
        $state.Items[2].Selected = $true

        $lines = @(Format-ResikPickerScreen -State $state -Width 100)
        $text = @($lines | ForEach-Object { $_.Text.TrimEnd() })

        $text[0] | Should -BeExactly 'Select targets to clean'
        $text[3] | Should -BeLike '> `[x`] uv *Developer*Low risk*2.0 KB'
        $text[4] | Should -BeLike '  `[-`] scoop *not found'
        $text[5] | Should -BeLike '  `[x`] pip *1.0 KB'
        $text[6] | Should -BeLike '  `[-`] conda *analysis only'
        $text[8] | Should -BeExactly '  C:\uv\cache'
        $text[9] | Should -BeExactly '  Selected: 2 target(s), estimated 3.0 KB'
        $lines[3].Color | Should -BeExactly 'Cyan'
        $lines[4].Color | Should -BeExactly 'DarkGray'
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
        $before | Should -Be ($state.Items.Count + 6)
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
        foreach ($key in @('Down', 'Down', 'Toggle', 'Confirm')) { $script:keys.Enqueue($key) }
        $state = New-TestPickerState

        Show-ResikTargetPicker -State $state | Should -BeExactly 'Confirm'

        @($state.Items | Where-Object Selected | ForEach-Object { $_.Target.Id }) | Should -Be @('pip')
    }

    It 'redraws in place from where the first drawing started' {
        foreach ($key in @('Down', 'Cancel')) { $script:keys.Enqueue($key) }
        $state = New-TestPickerState

        Show-ResikTargetPicker -State $state | Should -BeExactly 'Cancel'

        Should -Invoke Move-ResikConsoleCursor -Times 1 -Exactly -ParameterFilter { $Row -eq (50 - ($state.Items.Count + 6)) }
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

        # Number 2 is pip, because scoop cannot be selected and has no number.
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
