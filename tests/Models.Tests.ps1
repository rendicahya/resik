BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'Test environment' {
    It 'runs under strict mode, like the entry point' {
        # Only strict mode turns reading an unset variable into an error.
        { $null = $variableThatIsNeverSet } | Should -Throw
    }
}

Describe 'New-ResikTarget' {
    It 'creates a target with the expected metadata' {
        $target = New-TestTarget -Id 'uv'

        $target.PSObject.TypeNames | Should -Contain 'Resik.Target'
        $target.Id | Should -BeExactly 'uv'
        $target.Category | Should -BeExactly 'Developer'
        $target.RiskLevel | Should -BeExactly 'Low'
    }

    It 'rejects target ID "<_>"' -ForEach @('UV', 'has space', '-leading', 'a_b', '') {
        { New-TestTarget -Id $_ } | Should -Throw
    }

    It 'rejects an unknown category' {
        { New-ResikTarget -Id 'x' -Name 'X' -Category 'System' -RiskLevel Low -Description 'd' -Detect {} -Analyze {} } |
            Should -Throw
    }

    It 'rejects an unknown risk level' {
        { New-ResikTarget -Id 'x' -Name 'X' -Category Windows -RiskLevel 'Extreme' -Description 'd' -Detect {} -Analyze {} } |
            Should -Throw
    }
}

Describe 'Get-ResikTargetCatalog' {
    It 'contains only valid targets with unique IDs' {
        $catalog = @(Get-ResikTargetCatalog)

        foreach ($target in $catalog) {
            $target.PSObject.TypeNames | Should -Contain 'Resik.Target'
        }
        @($catalog | ForEach-Object { $_.Id } | Select-Object -Unique).Count | Should -Be $catalog.Count
    }
}

Describe 'New-ResikResult' {
    It 'accepts every documented status' {
        foreach ($status in (Get-ResikStatusName)) {
            (New-ResikResult -TargetId 'x' -Operation Analyze -Status $status).Status | Should -BeExactly $status
        }
    }

    It 'rejects an undocumented status' {
        { New-ResikResult -TargetId 'x' -Operation Analyze -Status 'Done' } | Should -Throw
    }

    It 'keeps missing measurements distinct from zero' {
        $missing = New-ResikResult -TargetId 'x' -Operation Analyze -Status AnalysisOnly
        $zero = New-ResikResult -TargetId 'x' -Operation Analyze -Status AnalysisOnly -EstimatedBytes 0

        $missing.EstimatedBytes | Should -BeNullOrEmpty
        $missing.MeasuredBytes | Should -BeNullOrEmpty
        $zero.EstimatedBytes | Should -Be 0
        $null -eq $zero.EstimatedBytes | Should -BeFalse
    }
}
