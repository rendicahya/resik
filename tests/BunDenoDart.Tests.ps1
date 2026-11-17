BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'bun target' {
    BeforeEach {
        $script:cacheDir = Join-Path $TestDrive ('bun-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $script:cacheDir 'left-pad@1.3.0@@@1\index.js') -Size 1200
        $script:cleanArgs = $null
        $script:cleanFolder = $null
        Mock Write-Host {}
        Mock Resolve-ResikExecutable { 'C:\fake\bun.exe' } -ParameterFilter { $Name -eq 'bun' }
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut "$script:cacheDir`n" } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'pm cache'
        }
        Mock Invoke-ResikNativeCommand {
            $script:cleanArgs = $ArgumentList
            $script:cleanFolder = $WorkingDirectory
            Get-ChildItem -LiteralPath $script:cacheDir -Force | Remove-Item -Recurse -Force
            New-TestRunResult
        } -ParameterFilter { ($ArgumentList -join ' ') -ceq 'pm cache rm' }
    }

    It 'is Low risk and chosen by --all' {
        $target = New-ResikBunTarget
        $target.RiskLevel | Should -BeExactly 'Low'
        $target.ExplicitOnly | Should -BeFalse
    }

    It 'is not detected when bun is missing' {
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'bun' }
        (Invoke-ResikTargetAnalysis -Target (New-ResikBunTarget)).Status | Should -BeExactly 'Skipped'
    }

    It 'measures the cache without cleaning it' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikBunTarget)
        $result.EstimatedBytes | Should -Be 1200
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'runs "bun pm cache rm" in the user profile folder' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikBunTarget)
        $result.Status | Should -BeExactly 'Success'
        $script:cleanArgs | Should -Be @('pm', 'cache', 'rm')
        $script:cleanFolder | Should -BeExactly ([Environment]::GetFolderPath('UserProfile'))
        $result.MeasuredBytes | Should -Be 1200
    }

    It 'refuses a protected location' {
        $script:cacheDir = $env:USERPROFILE
        (Invoke-ResikTargetCleanup -Target (New-ResikBunTarget)).Message | Should -BeLike '*Refusing to clean the Bun cache*'
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'rejects unexpected output' {
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut "one`ntwo`n" } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'pm cache'
        }
        (Invoke-ResikTargetCleanup -Target (New-ResikBunTarget)).Status | Should -BeExactly 'Failed'
        $script:cleanArgs | Should -BeNullOrEmpty
    }
}

Describe 'deno target' {
    BeforeEach {
        $script:denoDir = Join-Path $TestDrive ('deno-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $script:denoDir 'remote\https\deno.land\abc') -Size 900
        New-TestFile -Path (Join-Path $script:denoDir 'npm\registry.npmjs.org\x.tgz') -Size 600
        $script:cleanArgs = $null
        $script:cleanFolder = $null
        Mock Write-Host {}
        Mock Resolve-ResikExecutable { 'C:\fake\deno.exe' } -ParameterFilter { $Name -eq 'deno' }
        Mock Invoke-ResikNativeCommand {
            New-TestRunResult -StdOut (@{ version = 1; denoDir = $script:denoDir; modulesCache = "$script:denoDir\remote" } | ConvertTo-Json)
        } -ParameterFilter { ($ArgumentList -join ' ') -ceq 'info --json' }
        Mock Invoke-ResikNativeCommand {
            $script:cleanArgs = $ArgumentList
            $script:cleanFolder = $WorkingDirectory
            Remove-Item -LiteralPath $script:denoDir -Recurse -Force
            New-TestRunResult
        } -ParameterFilter { ($ArgumentList -join ' ') -ceq 'clean' }
    }

    It 'is Medium risk' {
        (New-ResikDenoTarget).RiskLevel | Should -BeExactly 'Medium'
    }

    It 'is not detected when deno is missing' {
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'deno' }
        (Invoke-ResikTargetAnalysis -Target (New-ResikDenoTarget)).Status | Should -BeExactly 'Skipped'
    }

    It 'measures DENO_DIR without cleaning it' {
        (Invoke-ResikTargetAnalysis -Target (New-ResikDenoTarget)).EstimatedBytes | Should -Be 1500
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'runs "deno clean" in the user profile folder' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikDenoTarget)
        $result.Status | Should -BeExactly 'Success'
        $script:cleanArgs | Should -Be @('clean')
        $script:cleanFolder | Should -BeExactly ([Environment]::GetFolderPath('UserProfile'))
        $result.MeasuredBytes | Should -Be 1500
    }

    It 'skips when DENO_DIR does not exist' {
        Remove-Item -LiteralPath $script:denoDir -Recurse -Force
        (Invoke-ResikTargetCleanup -Target (New-ResikDenoTarget)).Status | Should -BeExactly 'Skipped'
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'refuses a protected location' {
        $script:denoDir = $env:USERPROFILE
        (Invoke-ResikTargetCleanup -Target (New-ResikDenoTarget)).Message | Should -BeLike '*Refusing to clean DENO_DIR*'
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'rejects output without denoDir' {
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut '{"version":1}' } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'info --json'
        }
        (Invoke-ResikTargetCleanup -Target (New-ResikDenoTarget)).Message | Should -BeLike "*Unexpected output from 'tool'*"
        $script:cleanArgs | Should -BeNullOrEmpty
    }
}

Describe 'dart target' {
    BeforeAll {
        $script:savedPubCache = [Environment]::GetEnvironmentVariable('PUB_CACHE')
    }

    AfterAll {
        [Environment]::SetEnvironmentVariable('PUB_CACHE', $script:savedPubCache)
    }

    BeforeEach {
        [Environment]::SetEnvironmentVariable('PUB_CACHE', $null)
        $script:localAppData = Join-Path $TestDrive ('local-' + [guid]::NewGuid().ToString('N'))
        $script:pubCache = Join-Path $script:localAppData 'Pub\Cache'
        New-TestFile -Path (Join-Path $script:pubCache 'hosted\pub.dev\http-1.2.0\lib\http.dart') -Size 2500
        $script:cleanArgs = $null
        $script:cleanFolder = $null
        Mock Write-Host {}
        Mock Get-ResikLocalAppDataPath { $script:localAppData }
        Mock Resolve-ResikExecutable { 'C:\fake\dart.exe' } -ParameterFilter { $Name -eq 'dart' -and $Extension -ne '.bat' }
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'dart' -and $Extension -eq '.bat' }
        Mock Invoke-ResikNativeCommand {
            $script:cleanFile = $FilePath
            $script:cleanArgs = $ArgumentList
            $script:cleanFolder = $WorkingDirectory
            $root = if ($env:PUB_CACHE) { $env:PUB_CACHE } else { $script:pubCache }
            Remove-Item -LiteralPath $root -Recurse -Force
            New-Item -ItemType Directory -Path $root | Out-Null
            New-TestRunResult -StdOut "Removing pub cache directory $root."
        } -ParameterFilter { ($ArgumentList -join ' ') -ceq 'pub cache clean --force' }
    }

    It 'is Medium risk' {
        (New-ResikDartTarget).RiskLevel | Should -BeExactly 'Medium'
    }

    It 'is not detected when dart is missing' {
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'dart' }
        (Invoke-ResikTargetAnalysis -Target (New-ResikDartTarget)).Status | Should -BeExactly 'Skipped'
    }

    It 'uses the Flutter dart.bat when there is no dart.exe' {
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'dart' -and $Extension -ne '.bat' }
        Mock Resolve-ResikExecutable { 'C:\fake\flutter\bin\dart.bat' } -ParameterFilter { $Name -eq 'dart' -and $Extension -eq '.bat' }
        (Invoke-ResikTargetCleanup -Target (New-ResikDartTarget)).Status | Should -BeExactly 'Success'
        $script:cleanFile | Should -BeExactly 'C:\fake\flutter\bin\dart.bat'
    }

    It 'measures the default cache in LOCALAPPDATA without cleaning it' {
        (Invoke-ResikTargetAnalysis -Target (New-ResikDartTarget)).EstimatedBytes | Should -Be 2500
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'runs "dart pub cache clean --force" in the user profile folder' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikDartTarget)
        $result.Status | Should -BeExactly 'Success'
        $script:cleanArgs | Should -Be @('pub', 'cache', 'clean', '--force')
        $script:cleanFolder | Should -BeExactly ([Environment]::GetFolderPath('UserProfile'))
        $result.MeasuredBytes | Should -Be 2500
    }

    It 'uses PUB_CACHE when it is set' {
        $custom = Join-Path $TestDrive ('pub-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $custom 'git\x') -Size 400
        [Environment]::SetEnvironmentVariable('PUB_CACHE', $custom)

        (Invoke-ResikTargetAnalysis -Target (New-ResikDartTarget)).EstimatedBytes | Should -Be 400
        (Invoke-ResikTargetCleanup -Target (New-ResikDartTarget)).MeasuredBytes | Should -Be 400
        Join-Path $script:pubCache 'hosted' | Should -Exist
    }

    It 'reports a missing cache as empty and skips cleanup' {
        Remove-Item -LiteralPath $script:pubCache -Recurse -Force
        (Invoke-ResikTargetAnalysis -Target (New-ResikDartTarget)).EstimatedBytes | Should -Be 0
        (Invoke-ResikTargetCleanup -Target (New-ResikDartTarget)).Status | Should -BeExactly 'Skipped'
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'refuses a protected PUB_CACHE' {
        [Environment]::SetEnvironmentVariable('PUB_CACHE', $env:USERPROFILE)
        (Invoke-ResikTargetCleanup -Target (New-ResikDartTarget)).Message | Should -BeLike '*Refusing to clean the pub cache*'
        $script:cleanArgs | Should -BeNullOrEmpty
    }
}
