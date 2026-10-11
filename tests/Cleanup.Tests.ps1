BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'Invoke-ResikTargetCleanup' {
    It 'returns the outcome of Clean as a result' {
        $target = New-TestTarget -Clean {
            [pscustomobject]@{ Status = 'Success'; Details = 'done'; MeasuredBytes = 10; FreeSpaceChangeBytes = 8 }
        }

        $result = Invoke-ResikTargetCleanup -Target $target -EstimatedBytes 12

        $result.Operation | Should -BeExactly 'Clean'
        $result.Status | Should -BeExactly 'Success'
        $result.Message | Should -BeExactly 'done'
        $result.EstimatedBytes | Should -Be 12
        $result.MeasuredBytes | Should -Be 10
        $result.FreeSpaceChangeBytes | Should -Be 8
        $result.Duration | Should -Not -BeNullOrEmpty
    }

    It 'keeps missing measurements as $null' {
        $result = Invoke-ResikTargetCleanup -Target (New-TestTarget -Clean { [pscustomobject]@{ Status = 'Success' } })
        $result.MeasuredBytes | Should -BeNullOrEmpty
        $result.FreeSpaceChangeBytes | Should -BeNullOrEmpty
    }

    It 'marks a target without Clean as Unsupported' {
        (Invoke-ResikTargetCleanup -Target (New-TestTarget)).Status | Should -BeExactly 'Unsupported'
    }

    It 'turns an exception into a Failed result' {
        $result = Invoke-ResikTargetCleanup -Target (New-TestTarget -Clean { throw 'boom' })
        $result.Status | Should -BeExactly 'Failed'
        $result.Message | Should -BeExactly 'Cleanup failed: boom'
    }

    It 'rejects an invalid status: <_>' -ForEach @('', 'AnalysisOnly', 'success', 'Done') {
        $status = $_
        $result = Invoke-ResikTargetCleanup -Target (New-TestTarget -Clean { [pscustomobject]@{ Status = $status } }.GetNewClosure())
        $result.Status | Should -BeExactly 'Failed'
        $result.Message | Should -BeLike '*invalid status*'
    }
}
