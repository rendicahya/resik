BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'Composer target' {
    BeforeEach {
        $script:cacheDir = Join-Path $TestDrive ('composer-' + [guid]::NewGuid().ToString('N'))
        $script:config = @{
            'cache-dir'       = $script:cacheDir.Replace('\', '/')
            'cache-files-dir' = "$($script:cacheDir.Replace('\', '/'))/files"
            'cache-repo-dir'  = "$($script:cacheDir.Replace('\', '/'))/repo"
            'cache-vcs-dir'   = "$($script:cacheDir.Replace('\', '/'))/vcs"
        }
        $script:cleanArgs = $null
        Mock Write-Host {}
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'composer' -and $Extension -eq '.cmd' }
        Mock Resolve-ResikExecutable { 'C:\fake\composer.bat' } -ParameterFilter { $Name -eq 'composer' -and $Extension -eq '.bat' }
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut "$($script:config[$ArgumentList[2]])`n" } -ParameterFilter {
            $ArgumentList[1] -ceq 'config'
        }
        Mock Invoke-ResikNativeCommand {
            $script:cleanArgs = $ArgumentList
            Get-ChildItem -LiteralPath $script:cacheDir -Force | Remove-Item -Recurse -Force
            New-TestRunResult
        } -ParameterFilter { $ArgumentList -contains 'clear-cache' }

        New-TestFile -Path (Join-Path $script:cacheDir 'files\vendor\pkg\a.zip') -Size 3000
        New-TestFile -Path (Join-Path $script:cacheDir 'repo\packagist\b.json') -Size 1000
    }

    It 'is not detected when composer is missing' {
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'composer' }
        (Invoke-ResikTargetAnalysis -Target (New-ResikComposerTarget)).Status | Should -BeExactly 'Skipped'
    }

    It 'also finds a composer.cmd shim' {
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'composer' -and $Extension -eq '.bat' }
        Mock Resolve-ResikExecutable { 'C:\fake\composer.cmd' } -ParameterFilter { $Name -eq 'composer' -and $Extension -eq '.cmd' }
        (Invoke-ResikComposerDetection).Details | Should -BeExactly 'C:\fake\composer.cmd'
    }

    It 'reads the cache folders through "composer global config" and measures them once' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikComposerTarget)

        $result.Status | Should -BeExactly 'AnalysisOnly'
        $result.EstimatedBytes | Should -Be 4000
        Should -Invoke Invoke-ResikNativeCommand -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'global config cache-dir --absolute --no-interaction'
        }
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'runs "composer global clear-cache"' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikComposerTarget)

        $result.Status | Should -BeExactly 'Success'
        $script:cleanArgs | Should -Be @('global', 'clear-cache', '--no-interaction')
        $result.MeasuredBytes | Should -Be 4000
    }

    It 'also measures a cache folder outside cache-dir' {
        $elsewhere = Join-Path $TestDrive ('vcs-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $elsewhere 'clone\c') -Size 500
        $script:config['cache-vcs-dir'] = $elsewhere

        (Invoke-ResikTargetAnalysis -Target (New-ResikComposerTarget)).EstimatedBytes | Should -Be 4500
    }

    It 'skips a disabled cache' {
        foreach ($key in @($script:config.Keys)) { $script:config[$key] = 'nul' }

        (Invoke-ResikTargetAnalysis -Target (New-ResikComposerTarget)).Message | Should -BeExactly 'The Composer cache is disabled.'
        (Invoke-ResikTargetCleanup -Target (New-ResikComposerTarget)).Status | Should -BeExactly 'Skipped'
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'refuses a protected cache location' {
        $script:config['cache-repo-dir'] = $env:USERPROFILE

        $result = Invoke-ResikTargetCleanup -Target (New-ResikComposerTarget)

        $result.Status | Should -BeExactly 'Failed'
        $result.Message | Should -BeLike '*Refusing to clean the Composer cache (cache-repo-dir)*'
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'reports a failed clear-cache' {
        Mock Invoke-ResikNativeCommand {
            New-TestRunResult -Status NonZeroExit -Message 'composer.bat exited with code 1.'
        } -ParameterFilter { $ArgumentList -contains 'clear-cache' }

        $result = Invoke-ResikTargetCleanup -Target (New-ResikComposerTarget)

        $result.Status | Should -BeExactly 'Failed'
        $result.Message | Should -BeLike '*exited with code 1.*'
    }
}
