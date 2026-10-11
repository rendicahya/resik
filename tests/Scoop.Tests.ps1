BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')

    # Keep the tests away from the real Scoop configuration and environment.
    $script:savedEnv = @{}
    foreach ($name in @('SCOOP', 'SCOOP_CACHE', 'XDG_CONFIG_HOME')) {
        $script:savedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}

AfterAll {
    foreach ($name in $script:savedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:savedEnv[$name])
    }
}

Describe 'Scoop targets' {
    BeforeEach {
        $env:SCOOP = $null
        $env:SCOOP_CACHE = $null
        $env:XDG_CONFIG_HOME = Join-Path $TestDrive ('config-' + [guid]::NewGuid().ToString('N'))

        # <root>\shims\scoop.cmd, two apps with an old version each, one app
        # without a "current" link, and two cached downloads.
        $script:root = Join-Path $TestDrive ('scoop-' + [guid]::NewGuid().ToString('N'))
        $script:shim = Join-Path $script:root 'shims\scoop.cmd'
        New-TestFile -Path $script:shim -Size 10
        New-TestFile -Path (Join-Path $script:root 'apps\one\1.0\one.exe') -Size 1000
        New-TestFile -Path (Join-Path $script:root 'apps\one\2.0\one.exe') -Size 1100
        New-Item -ItemType Junction -Path (Join-Path $script:root 'apps\one\current') -Value (Join-Path $script:root 'apps\one\2.0') | Out-Null
        New-TestFile -Path (Join-Path $script:root 'apps\two\5.0\two.exe') -Size 300
        New-Item -ItemType Junction -Path (Join-Path $script:root 'apps\two\current') -Value (Join-Path $script:root 'apps\two\5.0') | Out-Null
        New-TestFile -Path (Join-Path $script:root 'apps\three\a\x') -Size 40
        New-TestFile -Path (Join-Path $script:root 'apps\three\b\x') -Size 40
        New-TestFile -Path (Join-Path $script:root 'cache\one#1.0#https_example.zip') -Size 700
        New-TestFile -Path (Join-Path $script:root 'cache\two#5.0#https_example.zip') -Size 200

        $script:cleanArgs = $null
        Mock Write-Host {}
        Mock Resolve-ResikExecutable { $script:shim } -ParameterFilter { $Name -eq 'scoop' -and $Extension -eq '.cmd' }
    }

    Context 'locations' {
        It 'finds the root from the shim and the cache under it' {
            $location = Get-ResikScoopLocation -ScoopPath $script:shim
            $location.Root | Should -BeExactly $script:root
            $location.Apps | Should -BeExactly (Join-Path $script:root 'apps')
            $location.Cache | Should -BeExactly (Join-Path $script:root 'cache')
        }

        It 'prefers SCOOP and SCOOP_CACHE' {
            $other = Join-Path $TestDrive 'other-root'
            New-Item -ItemType Directory -Force -Path (Join-Path $other 'apps') | Out-Null
            $env:SCOOP = $other
            $env:SCOOP_CACHE = Join-Path $TestDrive 'other-cache'

            $location = Get-ResikScoopLocation -ScoopPath $script:shim

            $location.Root | Should -BeExactly $other
            $location.Cache | Should -BeExactly (Join-Path $TestDrive 'other-cache')
        }

        It 'reads cache_path from the user config' {
            $config = Join-Path $env:XDG_CONFIG_HOME 'scoop\config.json'
            New-Item -ItemType Directory -Force -Path (Split-Path $config) | Out-Null
            $custom = Join-Path $TestDrive 'configured-cache'
            Set-Content -LiteralPath $config -Encoding UTF8 -Value (@{ cache_path = $custom } | ConvertTo-Json)

            (Get-ResikScoopLocation -ScoopPath $script:shim).Cache | Should -BeExactly $custom
        }

        It 'prefers a portable config.json in the root' {
            $custom = Join-Path $TestDrive 'portable-cache'
            Set-Content -LiteralPath (Join-Path $script:root 'config.json') -Encoding UTF8 -Value (@{ cache_path = $custom } | ConvertTo-Json)

            (Get-ResikScoopLocation -ScoopPath $script:shim).Cache | Should -BeExactly $custom
        }

        It 'refuses a protected cache location' {
            $env:SCOOP_CACHE = $env:USERPROFILE
            { Get-ResikScoopLocation -ScoopPath $script:shim } | Should -Throw '*Refusing to clean Scoop*'
        }
    }

    Context 'scoop-apps' {
        It 'finds old versions next to the version "current" links to' {
            $old = Get-ResikScoopOldVersion -AppsPath (Join-Path $script:root 'apps')

            $old.Folders | Should -Be @((Join-Path $script:root 'apps\one\1.0'))
            $old.UnknownApps | Should -Be 1
        }

        It 'estimates the size of the old versions' {
            $result = Invoke-ResikTargetAnalysis -Target (New-ResikScoopAppsTarget)

            $result.Status | Should -BeExactly 'AnalysisOnly'
            $result.EstimatedBytes | Should -Be 1000
            $result.Message | Should -BeLike '*1 old version folder(s)*1 app(s) could not be checked*'
        }

        It 'runs "scoop cleanup *" and measures the removed folders' {
            Mock Invoke-ResikNativeCommand {
                $script:cleanArgs = $ArgumentList
                Remove-Item -LiteralPath (Join-Path $script:root 'apps\one\1.0') -Recurse -Force
                New-TestRunResult
            }

            $result = Invoke-ResikTargetCleanup -Target (New-ResikScoopAppsTarget)

            $result.Status | Should -BeExactly 'Success'
            $script:cleanArgs | Should -Be @('cleanup', '*')
            $result.MeasuredBytes | Should -Be 1000
            Join-Path $script:root 'apps\one\2.0\one.exe' | Should -Exist
        }

        It 'reports partial success when an old version remains' {
            Mock Invoke-ResikNativeCommand { New-TestRunResult }

            $result = Invoke-ResikTargetCleanup -Target (New-ResikScoopAppsTarget)

            $result.Status | Should -BeExactly 'PartialSuccess'
            $result.Message | Should -BeLike '*1 old version folder(s) remain*'
        }
    }

    Context 'scoop-cache' {
        It 'estimates the size of the download cache' {
            (Invoke-ResikTargetAnalysis -Target (New-ResikScoopCacheTarget)).EstimatedBytes | Should -Be 900
        }

        It 'runs "scoop cache rm *"' {
            Mock Invoke-ResikNativeCommand {
                $script:cleanArgs = $ArgumentList
                Get-ChildItem -LiteralPath (Join-Path $script:root 'cache') -File | Remove-Item
                New-TestRunResult
            }

            $result = Invoke-ResikTargetCleanup -Target (New-ResikScoopCacheTarget)

            $result.Status | Should -BeExactly 'Success'
            $script:cleanArgs | Should -Be @('cache', 'rm', '*')
            $result.MeasuredBytes | Should -Be 900
        }

        It 'reports partial success when Scoop leaves files behind but exits 0' {
            Mock Invoke-ResikNativeCommand { New-TestRunResult }

            $result = Invoke-ResikTargetCleanup -Target (New-ResikScoopCacheTarget)

            $result.Status | Should -BeExactly 'PartialSuccess'
            $result.Message | Should -BeLike '*2 file(s) could not be removed*'
        }

        It 'skips an empty cache' {
            Get-ChildItem -LiteralPath (Join-Path $script:root 'cache') -File | Remove-Item
            Mock Invoke-ResikNativeCommand { throw 'must not run' }

            (Invoke-ResikTargetCleanup -Target (New-ResikScoopCacheTarget)).Status | Should -BeExactly 'Skipped'
        }
    }

    It 'are separate targets with separate results' {
        $ids = @(Get-ResikTargetCatalog | ForEach-Object Id)
        $ids | Should -Contain 'scoop-apps'
        $ids | Should -Contain 'scoop-cache'
    }
}
