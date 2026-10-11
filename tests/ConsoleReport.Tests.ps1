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

Describe 'Format-ResikSummary' {
    It 'labels the total as an estimate and counts unmeasured targets' {
        $results = @(
            (New-ResikResult -TargetId 'a' -Operation Analyze -Status AnalysisOnly -EstimatedBytes 2048),
            (New-ResikResult -TargetId 'b' -Operation Analyze -Status AnalysisOnly),
            (New-ResikResult -TargetId 'c' -Operation Analyze -Status Failed -Message 'Analysis failed: boom')
        )

        $text = (Format-ResikSummary -Results $results) -join "`n"

        $text | Should -BeLike '*Estimated reclaimable space: 2.0 KB (estimate only; nothing was removed)*'
        $text | Should -BeLike '*1 target(s) could not be measured*'
        $text | Should -BeLike '*Analysis failed: boom*'
    }

    It 'handles no results' {
        Format-ResikSummary -Results @() | Should -Be @('No results.')
    }

    It 'leaves analysis-only targets out of the reclaimable total' {
        $targets = @((New-TestTarget -Id 'cleanable' -Clean { }), (New-TestTarget -Id 'report'))
        $results = @(
            (New-ResikResult -TargetId 'cleanable' -Operation Analyze -Status AnalysisOnly -EstimatedBytes 1024),
            (New-ResikResult -TargetId 'report' -Operation Analyze -Status AnalysisOnly -EstimatedBytes 4096)
        )

        $lines = @(Format-ResikSummary -Results $results -Targets $targets)

        $lines | Should -Contain 'Estimated reclaimable space: 1.0 KB (estimate only; nothing was removed)'
        $lines | Should -Contain 'Not included, because Resik only reports their size: report'
        ($lines -join "`n") | Should -BeLike '*report*4.0 KB*'
    }
}

Describe 'Format-ResikCleanupPlan' {
    It 'lists each target with its estimate, location, and description' {
        $target = New-TestTarget -Id 'a'
        $analysis = New-ResikResult -TargetId 'a' -Operation Analyze -Status AnalysisOnly -EstimatedBytes 2048 -Message 'C:\cache'

        $text = (Format-ResikCleanupPlan -Targets @($target) -AnalysisResults @($analysis)) -join "`n"

        $text | Should -BeLike '*a - Fake a (Developer, Low risk), estimated 2.0 KB*'
        $text | Should -BeLike '*Location: C:\cache*'
        $text | Should -BeLike '*Test target*'
    }
}

Describe 'Format-ResikCleanupSummary' {
    It 'separates measured cache reduction from the change in free space' {
        $results = @(
            (New-ResikResult -TargetId 'a' -Operation Clean -Status Success -EstimatedBytes 4096 -MeasuredBytes 2048 -FreeSpaceChangeBytes 1024),
            (New-ResikResult -TargetId 'b' -Operation Clean -Status Failed -Message 'Cleanup failed: boom')
        )

        $text = (Format-ResikCleanupSummary -Results $results) -join "`n"

        $text | Should -BeLike '*Measured cache reduction: 2.0 KB (1 target(s) could not be measured)*'
        $text | Should -BeLike '*Change in free disk space: 1.0 KB (1 target(s) could not be measured)*'
        $text | Should -BeLike '*Cleanup failed: boom*'
        $text | Should -Not -BeLike '*4.0 KB*'
    }

    It 'says nothing was cleaned when every target was skipped' {
        $results = @(New-ResikResult -TargetId 'a' -Operation Clean -Status Skipped)
        (Format-ResikCleanupSummary -Results $results) | Should -Contain 'Nothing was cleaned.'
    }
}
