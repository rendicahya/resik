BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'Poetry target' {
    BeforeEach {
        $script:cacheDir = Join-Path $TestDrive ('poetry-' + [guid]::NewGuid().ToString('N'))
        $script:repositories = Join-Path $script:cacheDir 'cache\repositories'
        $script:cleared = New-Object 'System.Collections.Generic.List[string]'
        $script:cacheNames = "PyPI`nprivate`n"
        Mock Write-Host {}
        Mock Resolve-ResikExecutable { 'C:\fake\poetry.exe' } -ParameterFilter { $Name -eq 'poetry' }
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut "$script:cacheDir`n" } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'config cache-dir'
        }
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut $script:cacheNames } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'cache list'
        }
        Mock Invoke-ResikNativeCommand {
            $script:cleared.Add(($ArgumentList -join ' '))
            Remove-Item -LiteralPath (Join-Path $script:repositories $ArgumentList[2]) -Recurse -Force
            New-TestRunResult
        } -ParameterFilter { ($ArgumentList -join ' ') -like 'cache clear*' }

        New-TestFile -Path (Join-Path $script:repositories 'PyPI\_http\a') -Size 3000
        New-TestFile -Path (Join-Path $script:repositories 'private\_http\b') -Size 1000
        New-TestFile -Path (Join-Path $script:cacheDir 'artifacts\keep.whl') -Size 500
    }

    It 'is not detected when poetry.exe is missing' {
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'poetry' }
        (Invoke-ResikTargetAnalysis -Target (New-ResikPoetryTarget)).Status | Should -BeExactly 'Skipped'
    }

    It 'measures only the repository caches and cleans nothing' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikPoetryTarget)

        $result.Status | Should -BeExactly 'AnalysisOnly'
        $result.EstimatedBytes | Should -Be 4000
        $script:cleared.Count | Should -Be 0
    }

    It 'clears each cache by name and keeps the artifacts' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikPoetryTarget)

        $result.Status | Should -BeExactly 'Success'
        @($script:cleared) | Should -Be @('cache clear PyPI --all --no-interaction', 'cache clear private --all --no-interaction')
        $result.MeasuredBytes | Should -Be 4000
        Join-Path $script:cacheDir 'artifacts\keep.whl' | Should -Exist
    }

    It 'skips when there are no caches' {
        $script:cacheNames = ''
        (Invoke-ResikTargetCleanup -Target (New-ResikPoetryTarget)).Status | Should -BeExactly 'Skipped'
        $script:cleared.Count | Should -Be 0
    }

    It 'reports partial success when one cache fails' {
        Mock Invoke-ResikNativeCommand {
            New-TestRunResult -Status NonZeroExit -Message 'poetry exited with code 1.'
        } -ParameterFilter { ($ArgumentList -join ' ') -ceq 'cache clear private --all --no-interaction' }

        $result = Invoke-ResikTargetCleanup -Target (New-ResikPoetryTarget)

        $result.Status | Should -BeExactly 'PartialSuccess'
        $result.MeasuredBytes | Should -Be 3000
        $result.Message | Should -BeLike '*poetry exited with code 1.*'
    }

    It 'never passes a cache name that is not a plain name' {
        $script:cacheNames = "PyPI`n--all:x`n"

        $result = Invoke-ResikTargetCleanup -Target (New-ResikPoetryTarget)

        $result.Status | Should -BeExactly 'PartialSuccess'
        @($script:cleared) | Should -Be @('cache clear PyPI --all --no-interaction')
        $result.Message | Should -BeLike "*Skipped the cache '--all:x'*"
    }

    It 'refuses a protected cache location' {
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut $env:USERPROFILE } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'config cache-dir'
        }

        $result = Invoke-ResikTargetCleanup -Target (New-ResikPoetryTarget)

        $result.Status | Should -BeExactly 'Failed'
        $result.Message | Should -BeLike '*Refusing to clean the Poetry cache*'
        $script:cleared.Count | Should -Be 0
    }
}
