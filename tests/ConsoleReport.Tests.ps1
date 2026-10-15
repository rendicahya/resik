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

    It 'groups targets, sorts the cleanable ones by size, and leaves out missing tools' {
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
            'Total you can reclaim: about 5.0 KB (estimate only; nothing was removed)'
            '1 target could not be measured in advance (shown as ?).'
        )
    }

    It 'names missing tools once with ShowNotFound' {
        $targets = @((New-TestTarget -Id 'small' -Clean $script:clean), (New-TestTarget -Id 'a-long-missing-id' -Clean $script:clean))
        $results = @(
            (New-ResikResult -TargetId 'small' -Operation Analyze -Status AnalysisOnly -EstimatedBytes 1024),
            (New-ResikResult -TargetId 'a-long-missing-id' -Operation Analyze -Status Skipped -Message 'Not detected: missing.')
        )

        $hidden = @(Format-ResikSummary -Results $results -Targets $targets)
        $shown = @(Format-ResikSummary -Results $results -Targets $targets -ShowNotFound)

        ($hidden -join "`n") | Should -Not -BeLike '*a-long-missing-id*'
        $hidden[1] | Should -BeExactly '  small  Fake small  1.0 KB  Low'
        $shown | Should -Contain 'Not found: a-long-missing-id'
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
    It 'groups results, sorts cleaned targets by what was removed, and hides routine details' {
        $targets = @('a', 'big', 'unsized', 'part', 'b', 'off') | ForEach-Object { New-TestTarget -Id $_ }
        $results = @(
            (New-ResikResult -TargetId 'a' -Operation Clean -Status Success -EstimatedBytes 4096 -MeasuredBytes 2048 -FreeSpaceChangeBytes 1024 -Message 'Ran: tool clean'),
            (New-ResikResult -TargetId 'big' -Operation Clean -Status Success -MeasuredBytes 8192 -FreeSpaceChangeBytes -512 -Message 'Deleted 3 file(s) in C:\cache'),
            (New-ResikResult -TargetId 'unsized' -Operation Clean -Status Success -Message 'Deleted: old-app. Kept: other-app'),
            (New-ResikResult -TargetId 'part' -Operation Clean -Status PartialSuccess -MeasuredBytes 100 -FreeSpaceChangeBytes 100 -Message 'Deleted 1 file(s) in C:\x; 1 item(s) could not be deleted'),
            (New-ResikResult -TargetId 'b' -Operation Clean -Status Failed -Message 'Cleanup failed: boom'),
            (New-ResikResult -TargetId 'off' -Operation Clean -Status Skipped -Message 'Nothing to clean.')
        )

        $lines = @(Format-ResikCleanupSummary -Results $results -Targets $targets)

        $lines | Should -Be @(
            'Cleaned                  Removed  Free space'
            '  big      Fake big       8.0 KB      -512 B'
            '  a        Fake a         2.0 KB      1.0 KB'
            '  unsized  Fake unsized        ?           ?'
            '    Deleted: old-app. Kept: other-app'
            ''
            'Partly cleaned           Removed  Free space'
            '  part     Fake part       100 B       100 B'
            '    Deleted 1 file(s) in C:\x; 1 item(s) could not be deleted'
            ''
            'Failed'
            '  b        Fake b'
            '    Cleanup failed: boom'
            ''
            'Not cleaned'
            '  off      Fake off'
            '    Nothing to clean.'
            ''
            'Measured cache reduction:  10.1 KB (2 targets not measured)'
            'Change in free disk space: 612 B (2 targets not measured)'
            'The two can differ: other programs also write to the disk, and hard-linked files stay on it.'
        )
    }

    It 'never shows an estimate as a measurement' {
        $results = @(New-ResikResult -TargetId 'a' -Operation Clean -Status Success -EstimatedBytes 4096)
        (Format-ResikCleanupSummary -Results $results) -join "`n" | Should -Not -BeLike '*4.0 KB*'
    }

    It 'says nothing was cleaned when every target was skipped' {
        $results = @(New-ResikResult -TargetId 'a' -Operation Clean -Status Skipped)
        (Format-ResikCleanupSummary -Results $results) | Should -Contain 'Nothing was cleaned.'
    }
}
