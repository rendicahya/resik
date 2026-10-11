BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')

    $script:fakeUv = 'C:\fake\uv.exe'

    function New-FakeUvCache {
        # A cache folder in TestDrive that looks like one uv created.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Writes only to TestDrive.')]
        param([string] $Path, [switch] $NoTag)
        New-Item -ItemType Directory -Force -Path (Join-Path $Path 'wheels-v6') | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $Path 'wheels-v6\pkg.whl'), (New-Object byte[] 4096))
        if (-not $NoTag) {
            Set-Content -LiteralPath (Join-Path $Path 'CACHEDIR.TAG') -Encoding ASCII `
                -Value 'Signature: 8a477f597d28d172789f06886806bc55'
        }
    }

    function New-RunResult {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates an in-memory object only.')]
        param([string] $Status = 'Success', [string] $StdOut = '', [string] $StdErr = '', [string] $Message = '')
        [pscustomobject]@{
            Command = 'uv'; Status = $Status; ExitCode = $(if ($Status -eq 'Success') { 0 } else { 2 })
            StdOut = $StdOut; StdErr = $StdErr; Message = $Message; Duration = [timespan]::Zero
        }
    }
}

Describe 'uv target' {
    BeforeEach {
        $script:cacheDir = Join-Path $TestDrive ('cache-' + [guid]::NewGuid().ToString('N'))
        $script:cleanArgs = $null

        Mock Write-Host {}
        Mock Resolve-ResikExecutable { $script:fakeUv } -ParameterFilter { $Name -eq 'uv' }
        Mock Invoke-ResikNativeCommand { New-RunResult -StdOut "$script:cacheDir`r`n" } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'cache dir'
        }
        Mock Invoke-ResikNativeCommand {
            $script:cleanArgs = $ArgumentList
            Remove-Item -LiteralPath $script:cacheDir -Recurse -Force
            New-RunResult
        } -ParameterFilter { $ArgumentList[0] -ceq 'cache' -and $ArgumentList[1] -ceq 'clean' }
    }

    It 'is registered in the catalog with a Clean operation' {
        $target = @(Get-ResikTargetCatalog) | Where-Object Id -eq 'uv'
        $target | Should -Not -BeNullOrEmpty
        $target.Clean | Should -Not -BeNullOrEmpty
        $target.Category | Should -BeExactly 'Developer'
    }

    It 'is listed in the help text' {
        Get-ResikHelpText | Should -Match '(?m)^\s+uv\s'
    }

    It 'is not detected when uv is missing' {
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'uv' }

        $result = Invoke-ResikTargetAnalysis -Target (New-ResikUvTarget)

        $result.Status | Should -BeExactly 'Skipped'
        $result.Message | Should -BeLike '*uv was not found on PATH*'
    }

    Context 'analysis' {
        It 'measures the cache that uv reports, without cleaning it' {
            New-FakeUvCache -Path $script:cacheDir

            $result = Invoke-ResikTargetAnalysis -Target (New-ResikUvTarget)

            $result.Status | Should -BeExactly 'AnalysisOnly'
            $result.EstimatedBytes | Should -Be (4096 + (Get-Item (Join-Path $script:cacheDir 'CACHEDIR.TAG')).Length)
            $result.Message | Should -BeLike "$script:cacheDir (2 files)"
            Should -Invoke Invoke-ResikNativeCommand -Times 0 -ParameterFilter { $ArgumentList -contains 'clean' }
            Join-Path $script:cacheDir 'wheels-v6\pkg.whl' | Should -Exist
        }

        It 'reports zero when the cache does not exist' {
            $result = Invoke-ResikTargetAnalysis -Target (New-ResikUvTarget)

            $result.Status | Should -BeExactly 'AnalysisOnly'
            $result.EstimatedBytes | Should -Be 0
        }

        It 'fails when "uv cache dir" fails' {
            Mock Invoke-ResikNativeCommand { New-RunResult -Status NonZeroExit -Message 'uv cache dir exited with code 2.' -StdErr 'error: bad config' } -ParameterFilter {
                ($ArgumentList -join ' ') -ceq 'cache dir'
            }

            $result = Invoke-ResikTargetAnalysis -Target (New-ResikUvTarget)

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*exited with code 2. error: bad config'
        }

        It 'fails when "uv cache dir" prints something unexpected' {
            Mock Invoke-ResikNativeCommand { New-RunResult -StdOut "one`ntwo" } -ParameterFilter {
                ($ArgumentList -join ' ') -ceq 'cache dir'
            }

            (Invoke-ResikTargetAnalysis -Target (New-ResikUvTarget)).Status | Should -BeExactly 'Failed'
        }
    }

    Context 'cleanup' {
        It 'runs "uv cache clean" on the validated directory and measures the result' {
            New-FakeUvCache -Path $script:cacheDir

            $result = Invoke-ResikTargetCleanup -Target (New-ResikUvTarget) -EstimatedBytes 1

            $result.Status | Should -BeExactly 'Success'
            $script:cleanArgs | Should -Be @('cache', 'clean', '--cache-dir', $script:cacheDir)
            $result.MeasuredBytes | Should -BeGreaterThan 4095
            $result.EstimatedBytes | Should -Be 1
            $result.FreeSpaceChangeBytes | Should -Not -BeNullOrEmpty
        }

        It 'never passes --force to uv' {
            New-FakeUvCache -Path $script:cacheDir
            Invoke-ResikTargetCleanup -Target (New-ResikUvTarget) | Out-Null
            $script:cleanArgs | Should -Not -Contain '--force'
        }

        It 'skips when there is no cache' {
            $result = Invoke-ResikTargetCleanup -Target (New-ResikUvTarget)

            $result.Status | Should -BeExactly 'Skipped'
            $script:cleanArgs | Should -BeNullOrEmpty
        }

        It 'refuses a directory without CACHEDIR.TAG' {
            New-FakeUvCache -Path $script:cacheDir -NoTag

            $result = Invoke-ResikTargetCleanup -Target (New-ResikUvTarget)

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*no CACHEDIR.TAG file*'
            $script:cleanArgs | Should -BeNullOrEmpty
            Join-Path $script:cacheDir 'wheels-v6\pkg.whl' | Should -Exist
        }

        It 'refuses a protected location such as the user profile' {
            Mock Invoke-ResikNativeCommand { New-RunResult -StdOut $env:USERPROFILE } -ParameterFilter {
                ($ArgumentList -join ' ') -ceq 'cache dir'
            }

            $result = Invoke-ResikTargetCleanup -Target (New-ResikUvTarget)

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*Refusing to clean the uv cache*protected*'
            $script:cleanArgs | Should -BeNullOrEmpty
        }

        It 'refuses a junction' {
            $real = Join-Path $TestDrive ('real-' + [guid]::NewGuid().ToString('N'))
            New-FakeUvCache -Path $real
            New-Item -ItemType Junction -Path $script:cacheDir -Value $real | Out-Null

            $result = Invoke-ResikTargetCleanup -Target (New-ResikUvTarget)

            $result.Status | Should -BeExactly 'Failed'
            $script:cleanArgs | Should -BeNullOrEmpty
        }

        It 'reports a failed "uv cache clean" with its error output' {
            New-FakeUvCache -Path $script:cacheDir
            Mock Invoke-ResikNativeCommand {
                New-RunResult -Status NonZeroExit -Message 'uv cache clean exited with code 2.' -StdErr 'error: in use'
            } -ParameterFilter { $ArgumentList[1] -ceq 'clean' }

            $result = Invoke-ResikTargetCleanup -Target (New-ResikUvTarget)

            $result.Status | Should -BeExactly 'Failed'
            $result.Message | Should -BeLike '*exited with code 2. error: in use'
            $result.MeasuredBytes | Should -Be 0
        }

        It 'reports partial success when uv fails after removing some files' {
            New-FakeUvCache -Path $script:cacheDir
            Mock Invoke-ResikNativeCommand {
                Remove-Item -LiteralPath (Join-Path $script:cacheDir 'wheels-v6') -Recurse -Force
                New-RunResult -Status TimedOut -Message 'uv cache clean did not finish within 1800 seconds and was stopped.'
            } -ParameterFilter { $ArgumentList[1] -ceq 'clean' }

            $result = Invoke-ResikTargetCleanup -Target (New-ResikUvTarget)

            $result.Status | Should -BeExactly 'PartialSuccess'
            $result.MeasuredBytes | Should -Be 4096
        }

        It 're-reads the cache directory at cleanup time' {
            New-FakeUvCache -Path $script:cacheDir
            Invoke-ResikTargetCleanup -Target (New-ResikUvTarget) | Out-Null
            Should -Invoke Invoke-ResikNativeCommand -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -ceq 'cache dir' }
        }
    }
}

Describe 'uv target with the real uv' {
    # Runs the installed uv against a throwaway cache in TestDrive only.
    BeforeAll {
        $script:realUv = Resolve-ResikExecutable -Name 'uv'
        $script:savedCacheDir = $env:UV_CACHE_DIR
    }
    AfterAll {
        $env:UV_CACHE_DIR = $script:savedCacheDir
    }

    It 'cleans a cache in TestDrive' {
        if (-not $script:realUv) {
            Set-ItResult -Skipped -Because 'uv is not installed'
            return
        }
        Mock Write-Host {}
        $cache = Join-Path $TestDrive 'real-uv-cache'
        New-FakeUvCache -Path $cache
        $env:UV_CACHE_DIR = $cache

        # Guard: never continue unless uv itself points at the test cache.
        Get-ResikUvCacheDirectory -UvPath $script:realUv | Should -BeExactly $cache

        $result = Invoke-ResikTargetCleanup -Target (New-ResikUvTarget)

        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -BeGreaterThan 4095
        $cache | Should -Not -Exist
    }
}
