BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'npm target' {
    BeforeEach {
        $script:cacheDir = Join-Path $TestDrive ('npm-' + [guid]::NewGuid().ToString('N'))
        $script:cleanArgs = $null
        Mock Write-Host {}
        Mock Resolve-ResikExecutable { 'C:\fake\npm.cmd' } -ParameterFilter { $Name -eq 'npm' -and $Extension -eq '.cmd' }
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut "$script:cacheDir`n" } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'config get cache'
        }
        Mock Invoke-ResikNativeCommand {
            $script:cleanArgs = $ArgumentList
            Remove-Item -LiteralPath (Join-Path $script:cacheDir '_cacache') -Recurse -Force
            New-TestRunResult
        } -ParameterFilter { ($ArgumentList -join ' ') -like 'cache clean*' }

        New-TestFile -Path (Join-Path $script:cacheDir '_cacache\content-v2\a') -Size 3000
        New-TestFile -Path (Join-Path $script:cacheDir '_npx\keep\package.json') -Size 50
    }

    It 'is not detected when npm.cmd is missing' {
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'npm' }
        (Invoke-ResikTargetAnalysis -Target (New-ResikNpmTarget)).Status | Should -BeExactly 'Skipped'
    }

    It 'measures only _cacache' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikNpmTarget)

        $result.Status | Should -BeExactly 'AnalysisOnly'
        $result.EstimatedBytes | Should -Be 3000
        Should -Invoke Invoke-ResikNativeCommand -Times 0 -ParameterFilter { $ArgumentList -contains 'clean' }
    }

    It 'runs "npm cache clean --force" and keeps the npx cache' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikNpmTarget)

        $result.Status | Should -BeExactly 'Success'
        $script:cleanArgs | Should -Be @('cache', 'clean', '--force')
        $result.MeasuredBytes | Should -Be 3000
        Join-Path $script:cacheDir '_npx\keep\package.json' | Should -Exist
    }

    It 'skips when there is no _cacache' {
        Remove-Item -LiteralPath (Join-Path $script:cacheDir '_cacache') -Recurse -Force
        (Invoke-ResikTargetCleanup -Target (New-ResikNpmTarget)).Status | Should -BeExactly 'Skipped'
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'refuses a protected cache location' {
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut $env:USERPROFILE } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'config get cache'
        }

        $result = Invoke-ResikTargetCleanup -Target (New-ResikNpmTarget)

        $result.Status | Should -BeExactly 'Failed'
        $result.Message | Should -BeLike '*Refusing to clean the npm cache*'
        $script:cleanArgs | Should -BeNullOrEmpty
    }
}
