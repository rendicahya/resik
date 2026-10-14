BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'Format-ResikSize' {
    It 'formats <Bytes> as <Expected>' -ForEach @(
        @{ Bytes = 0; Expected = '0 B' }
        @{ Bytes = 512; Expected = '512 B' }
        @{ Bytes = 1536; Expected = '1.5 KB' }
        @{ Bytes = 1073741824; Expected = '1.0 GB' }
        @{ Bytes = -512; Expected = '-512 B' }
        @{ Bytes = -1536; Expected = '-1.5 KB' }
    ) {
        Format-ResikSize -Bytes $Bytes | Should -BeExactly $Expected
    }

    It 'shows a missing measurement as n/a, not zero' {
        Format-ResikSize -Bytes $null | Should -BeExactly 'n/a'
    }
}

Describe 'ConvertTo-ResikDisplayText' {
    It 'shortens <Text> to <Expected>' -ForEach @(
        @{ Text = 'C:\Users\me\cache (3 files)'; Expected = '~\cache (3 files)' }
        @{ Text = 'c:\users\me\cache'; Expected = '~\cache' }
        @{ Text = 'Gone: C:\Users\me'; Expected = 'Gone: ~' }
        @{ Text = 'C:\Users\meadow\cache'; Expected = 'C:\Users\meadow\cache' }
        @{ Text = 'D:\C:\Users\me\x'; Expected = 'D:\C:\Users\me\x' }
    ) {
        ConvertTo-ResikDisplayText -Text $Text -UserProfile 'C:\Users\me' | Should -BeExactly $Expected
    }
}

Describe 'Limit-ResikText and Split-ResikText' {
    It 'cuts long text with an ellipsis, and leaves short text alone' {
        Limit-ResikText 'abcdefghij' 8 | Should -BeExactly 'abcde...'
        Limit-ResikText 'abc' 8 | Should -BeExactly 'abc'
        Limit-ResikText 'abcdefghij' 0 | Should -BeExactly 'abcdefghij'
    }

    It 'wraps at spaces, indenting each line' {
        @(Split-ResikText 'one two three four five six' -Width 16 -Indent '  ') |
            Should -Be @('  one two three', '  four five six')
    }

    It 'breaks a word longer than the line' {
        @(Split-ResikText 'aaaaaaaaaaaaaaaaaaaaaaaaa b' -Width 12) | Should -Be @('aaaaaaaaaaaa', 'aaaaaaaaaaaa', 'a b')
    }

    It 'does not wrap without a width' {
        @(Split-ResikText 'one two' -Width 0 -Indent '  ') | Should -Be @('  one two')
    }
}

Describe 'Format-ResikSummary' {
    BeforeAll {
        $script:clean = { }
    }

    It 'groups targets, sorts the cleanable ones by size, and names missing tools once' {
        $targets = @(
            (New-TestTarget -Id 'small' -Clean $script:clean),
            (New-TestTarget -Id 'gone' -Clean $script:clean),
            (New-TestTarget -Id 'big' -Clean $script:clean),
            (New-TestTarget -Id 'unsized' -Clean $script:clean),
            (New-TestTarget -Id 'report'),
            (New-TestTarget -Id 'off' -Clean $script:clean),
            (New-TestTarget -Id 'broken' -Clean $script:clean)
        )
        $results = @(
            (New-ResikResult -TargetId 'small' -Operation Analyze -Status AnalysisOnly -EstimatedBytes 1024 -Message 'small cache'),
            (New-ResikResult -TargetId 'gone' -Operation Analyze -Status Skipped -Message 'Not detected: gone was not found on PATH.'),
            (New-ResikResult -TargetId 'big' -Operation Analyze -Status AnalysisOnly -EstimatedBytes 4096),
            (New-ResikResult -TargetId 'unsized' -Operation Analyze -Status AnalysisOnly),
            (New-ResikResult -TargetId 'report' -Operation Analyze -Status AnalysisOnly -EstimatedBytes 8192 -Message 'Clean it in the IDE.'),
            (New-ResikResult -TargetId 'off' -Operation Analyze -Status Skipped -Message 'The cache is turned off.'),
            (New-ResikResult -TargetId 'broken' -Operation Analyze -Status Failed -Message 'Analysis failed: boom')
        )

        $lines = @(Format-ResikSummary -Results $results -Targets $targets)

        $lines | Should -Be @(
            'Ready to clean             Size  Risk'
            '  big      Fake big      4.0 KB  Low'
            '  small    Fake small    1.0 KB  Low   small cache'
            '  unsized  Fake unsized       ?  Low'
            ''
            'Report only                Size  Risk'
            '  report   Fake report   8.0 KB  Low'
            '    Clean it in the IDE.'
            ''
            'Skipped'
            '  off'
            '    The cache is turned off.'
            ''
            'Problems'
            '  broken (Failed)'
            '    Analysis failed: boom'
            ''
            'Not found: gone'
            ''
            'Total you can reclaim: about 5.0 KB (estimate only; nothing was removed)'
            '1 target could not be measured in advance (shown as ?).'
        )
    }

    It 'cuts details to fit the width' {
        $results = @(New-ResikResult -TargetId 'a' -Operation Analyze -Status AnalysisOnly -EstimatedBytes 1 -Message ('x' * 200))

        foreach ($line in (Format-ResikSummary -Results $results -Width 60)) {
            $line.Length | Should -BeLessOrEqual 59
        }
    }

    It 'says when there is nothing to clean' {
        $results = @(New-ResikResult -TargetId 'a' -Operation Analyze -Status Skipped -Message 'Not detected: a')
        (Format-ResikSummary -Results $results) | Should -Contain 'Nothing to clean.'
    }

    It 'handles no results' {
        Format-ResikSummary -Results @() | Should -Be @('No results.')
    }
}

Describe 'Format-ResikCleanupPlan' {
    It 'lists each target with its estimate, location, and description' {
        $target = New-TestTarget -Id 'a'
        $analysis = New-ResikResult -TargetId 'a' -Operation Analyze -Status AnalysisOnly -EstimatedBytes 2048 -Message 'C:\cache'

        $lines = @(Format-ResikCleanupPlan -Targets @($target) -AnalysisResults @($analysis))

        $lines | Should -Be @(
            'Resik will clean 1 target (about 2.0 KB):'
            ''
            '  Fake a (a) - 2.0 KB, Low risk'
            '    C:\cache'
            '    Test target'
        )
    }

    It 'counts targets of unknown size separately' {
        $targets = @((New-TestTarget -Id 'a'), (New-TestTarget -Id 'b'))
        $analysis = @(
            (New-ResikResult -TargetId 'a' -Operation Analyze -Status AnalysisOnly -EstimatedBytes 1024),
            (New-ResikResult -TargetId 'b' -Operation Analyze -Status AnalysisOnly)
        )

        $lines = @(Format-ResikCleanupPlan -Targets $targets -AnalysisResults $analysis)

        $lines[0] | Should -BeExactly 'Resik will clean 2 targets (about 1.0 KB, plus 1 target of unknown size):'
        $lines | Should -Contain '  Fake b (b) - size unknown, Low risk'
    }
}

Describe 'Format-ResikCleanupSummary' {
    It 'separates measured cache reduction from the change in free space' {
        $results = @(
            (New-ResikResult -TargetId 'a' -Operation Clean -Status Success -EstimatedBytes 4096 -MeasuredBytes 2048 -FreeSpaceChangeBytes 1024),
            (New-ResikResult -TargetId 'b' -Operation Clean -Status Failed -Message 'Cleanup failed: boom')
        )

        $lines = @(Format-ResikCleanupSummary -Results $results)
        $text = $lines -join "`n"

        $lines | Should -Contain '  a       Cleaned             2.0 KB      1.0 KB'
        $lines | Should -Contain '    Cleanup failed: boom'
        $text | Should -BeLike '*Measured cache reduction: 2.0 KB (1 target could not be measured)*'
        $text | Should -BeLike '*Change in free disk space: 1.0 KB (1 target could not be measured)*'
        $text | Should -Not -BeLike '*4.0 KB*'
    }

    It 'says nothing was cleaned when every target was skipped' {
        $results = @(New-ResikResult -TargetId 'a' -Operation Clean -Status Skipped)
        (Format-ResikCleanupSummary -Results $results) | Should -Contain 'Nothing was cleaned.'
    }
}
