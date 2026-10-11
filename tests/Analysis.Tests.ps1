BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'Invoke-ResikAnalysis' {
    It 'reports an available target as AnalysisOnly with its estimate' {
        $result = Invoke-ResikAnalysis -Targets @(New-TestTarget -Id 'a')

        $result.Status | Should -BeExactly 'AnalysisOnly'
        $result.Operation | Should -BeExactly 'Analyze'
        $result.EstimatedBytes | Should -Be 1024
        $result.Duration | Should -BeOfType ([timespan])
    }

    It 'skips a target that is not detected without running its analysis' {
        $script:analyzed = $false
        $target = New-TestTarget -Id 'missing' `
            -Detect { [pscustomobject]@{ Available = $false; Details = 'tool not installed' } } `
            -Analyze { $script:analyzed = $true }

        $result = Invoke-ResikAnalysis -Targets @($target)

        $result.Status | Should -BeExactly 'Skipped'
        $result.Message | Should -BeLike '*tool not installed*'
        $script:analyzed | Should -BeFalse
    }

    It 'keeps an unmeasurable estimate as null rather than zero' {
        $target = New-TestTarget -Id 'unmeasured' -Analyze { [pscustomobject]@{ Details = 'size unknown' } }

        $result = Invoke-ResikAnalysis -Targets @($target)

        $result.Status | Should -BeExactly 'AnalysisOnly'
        $null -eq $result.EstimatedBytes | Should -BeTrue
    }

    It 'isolates a failing target from the others' {
        $targets = @(
            (New-TestTarget -Id 'first'),
            (New-TestTarget -Id 'broken' -Analyze { throw 'boom' }),
            (New-TestTarget -Id 'nonterminating' -Detect { Write-Error 'detect failed' }),
            (New-TestTarget -Id 'last')
        )

        $results = @(Invoke-ResikAnalysis -Targets $targets)

        $results.Count | Should -Be 4
        $results[0].Status | Should -BeExactly 'AnalysisOnly'
        $results[1].Status | Should -BeExactly 'Failed'
        $results[1].Message | Should -BeLike '*boom*'
        $results[2].Status | Should -BeExactly 'Failed'
        $results[3].Status | Should -BeExactly 'AnalysisOnly'
    }

    It 'treats a negative estimate as a failure' {
        $target = New-TestTarget -Id 'negative' -Analyze { [pscustomobject]@{ EstimatedBytes = -5 } }

        (Invoke-ResikAnalysis -Targets @($target)).Status | Should -BeExactly 'Failed'
    }
}
