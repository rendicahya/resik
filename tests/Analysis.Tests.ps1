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

Describe 'Parallel analysis' {
    BeforeAll {
        $script:sourceRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Resik'
        $script:fakeTargets = @(
            (New-TestTarget -Id 'fake-1' -Analyze { [pscustomobject]@{ EstimatedBytes = 1; Details = 'one' } }),
            (New-TestTarget -Id 'fake-2' -Analyze { throw 'boom' }),
            (New-TestTarget -Id 'fake-3' -Detect { [pscustomobject]@{ Available = $false; Details = 'not here' } }),
            (New-TestTarget -Id 'fake-4' -Analyze { [pscustomobject]@{ EstimatedBytes = 4; Details = 'four' } }),
            (New-TestTarget -Id 'fake-5' -Analyze { [pscustomobject]@{ EstimatedBytes = 5; Details = 'five' } })
        )
    }

    It 'is used only with a worker source folder' {
        Mock Invoke-ResikParallelAnalysis {}
        $null = @(Invoke-ResikAnalysis -Targets $script:fakeTargets)
        Should -Invoke Invoke-ResikParallelAnalysis -Times 0
        $null = @(Invoke-ResikAnalysis -Targets $script:fakeTargets -WorkerSourceRoot $script:sourceRoot)
        Should -Invoke Invoke-ResikParallelAnalysis -Times 1 -Exactly
    }

    It 'is not used for targets with duplicate IDs' {
        Mock Invoke-ResikParallelAnalysis {}
        $targets = @($script:fakeTargets) + @(New-TestTarget -Id 'fake-1')
        @(Invoke-ResikAnalysis -Targets $targets -WorkerSourceRoot $script:sourceRoot).Count | Should -Be 6
        Should -Invoke Invoke-ResikParallelAnalysis -Times 0
    }

    It 'returns every result in target order when workers cannot build the targets' {
        # Workers load the real source, whose catalog has none of these IDs,
        # so this thread analyzes each target itself.
        $results = @(Invoke-ResikParallelAnalysis -Targets $script:fakeTargets -WorkerSourceRoot $script:sourceRoot -WorkerCount 2)

        @($results.TargetId) | Should -Be @('fake-1', 'fake-2', 'fake-3', 'fake-4', 'fake-5')
        @($results.Status) | Should -Be @('AnalysisOnly', 'Failed', 'Skipped', 'AnalysisOnly', 'AnalysisOnly')
        @($results.EstimatedBytes)[0] | Should -Be 1
        $results[1].Message | Should -BeExactly 'Analysis failed: boom'
        $results[4].Message | Should -BeExactly 'five'
    }

    It 'analyzes every target on this thread when the workers fail to load' {
        $results = @(Invoke-ResikParallelAnalysis -Targets $script:fakeTargets -WorkerSourceRoot (Join-Path $TestDrive 'missing') -WorkerCount 2)

        @($results.TargetId) | Should -Be @('fake-1', 'fake-2', 'fake-3', 'fake-4', 'fake-5')
        $results[3].EstimatedBytes | Should -Be 4
    }
}
