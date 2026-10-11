BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'ConvertTo-ResikTargetIdList' {
    It 'accepts a PowerShell array' {
        ConvertTo-ResikTargetIdList -Value @('uv', 'pip') | Should -Be @('uv', 'pip')
    }

    It 'splits a single comma-separated string (powershell.exe -File style)' {
        ConvertTo-ResikTargetIdList -Value 'uv,pip, scoop' | Should -Be @('uv', 'pip', 'scoop')
    }

    It 'normalizes case and removes duplicates' {
        ConvertTo-ResikTargetIdList -Value 'UV,uv,Pip' | Should -Be @('uv', 'pip')
    }

    It 'rejects empty entries' {
        { ConvertTo-ResikTargetIdList -Value 'uv,,pip' } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'rejects malformed IDs' {
        { ConvertTo-ResikTargetIdList -Value '..\windows' } | Should -Throw -ExceptionType ([System.ArgumentException])
    }
}

Describe 'Resolve-ResikSelection' {
    BeforeAll {
        $script:targets = @(
            (New-TestTarget -Id 'uv'),
            (New-TestTarget -Id 'pip'),
            (New-TestTarget -Id 'scoop')
        )
    }

    It 'selects every target with -All' {
        $selected = Resolve-ResikSelection -Targets $script:targets -All
        $selected.Id | Should -Be @('uv', 'pip', 'scoop')
    }

    It 'selects only the requested targets, in catalog order' {
        $selected = Resolve-ResikSelection -Targets $script:targets -Only 'scoop,uv'
        $selected.Id | Should -Be @('uv', 'scoop')
    }

    It 'rejects unknown target IDs and names them' {
        { Resolve-ResikSelection -Targets $script:targets -Only 'uv,nope' } |
            Should -Throw -ExpectedMessage '*Unknown target ID(s): nope*' -ExceptionType ([System.ArgumentException])
    }

    It 'rejects -All combined with -Only' {
        { Resolve-ResikSelection -Targets $script:targets -All -Only 'uv' } |
            Should -Throw -ExpectedMessage '*cannot be used together*'
    }

    It 'requires an explicit selection' {
        { Resolve-ResikSelection -Targets $script:targets } | Should -Throw -ExceptionType ([System.ArgumentException])
    }

    It 'returns an empty selection when no targets are registered' {
        $selected = Resolve-ResikSelection -Targets @() -All
        @($selected).Count | Should -Be 0
    }
}
