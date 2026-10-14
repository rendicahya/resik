BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'pnpm target' {
    BeforeEach {
        $script:storeDir = Join-Path $TestDrive ('pnpm-store-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $script:storeDir 'files\00\a') -Size 2000
        New-TestFile -Path (Join-Path $script:storeDir 'files\01\b') -Size 500
        $script:cleanArgs = $null
        Mock Write-Host {}
        Mock Resolve-ResikExecutable { 'C:\fake\pnpm.exe' } -ParameterFilter { $Name -eq 'pnpm' -and $Extension -ne '.cmd' }
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'pnpm' -and $Extension -eq '.cmd' }
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut "$script:storeDir`r`n" } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'store path'
        }
        Mock Invoke-ResikNativeCommand {
            $script:cleanArgs = $ArgumentList
            $script:cleanFolder = $WorkingDirectory
            Remove-Item -LiteralPath (Join-Path $script:storeDir 'files\01') -Recurse -Force
            New-TestRunResult
        } -ParameterFilter { ($ArgumentList -join ' ') -ceq 'store prune' }
    }

    It 'is not detected when pnpm is missing' {
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'pnpm' }
        (Invoke-ResikTargetAnalysis -Target (New-ResikPnpmTarget)).Status | Should -BeExactly 'Skipped'
    }

    It 'also finds a pnpm.cmd shim' {
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'pnpm' -and $Extension -ne '.cmd' }
        Mock Resolve-ResikExecutable { 'C:\fake\pnpm.cmd' } -ParameterFilter { $Name -eq 'pnpm' -and $Extension -eq '.cmd' }
        (Invoke-ResikPnpmDetection).Details | Should -BeExactly 'C:\fake\pnpm.cmd'
    }

    It 'reports the store size but no estimate, because prune cannot be previewed' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikPnpmTarget)

        $result.Status | Should -BeExactly 'AnalysisOnly'
        $result.EstimatedBytes | Should -BeNullOrEmpty
        $result.Message | Should -BeLike "$script:storeDir (2.4 KB in 2 files)*cannot be previewed"
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'runs "pnpm store prune" in the user profile folder and measures what it removed' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikPnpmTarget)

        $result.Status | Should -BeExactly 'Success'
        $script:cleanArgs | Should -Be @('store', 'prune')
        $script:cleanFolder | Should -BeExactly ([Environment]::GetFolderPath('UserProfile'))
        $result.MeasuredBytes | Should -Be 500
    }

    It 'refuses a protected store location' {
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut $env:USERPROFILE } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'store path'
        }
        (Invoke-ResikTargetCleanup -Target (New-ResikPnpmTarget)).Message | Should -BeLike '*Refusing to prune the pnpm store*'
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'skips a store that does not exist' {
        Remove-Item -LiteralPath $script:storeDir -Recurse -Force
        (Invoke-ResikTargetCleanup -Target (New-ResikPnpmTarget)).Status | Should -BeExactly 'Skipped'
        $script:cleanArgs | Should -BeNullOrEmpty
    }
}

Describe 'yarn target' {
    BeforeEach {
        $script:cacheDir = Join-Path $TestDrive ('yarn-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $script:cacheDir 'v6\npm-left-pad-1.3.0\package.json') -Size 1500
        $script:cleanArgs = $null
        $script:version = '1.22.22'
        Mock Write-Host {}
        Mock Resolve-ResikExecutable { 'C:\fake\yarn.cmd' } -ParameterFilter { $Name -eq 'yarn' -and $Extension -eq '.cmd' }
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut "$script:version`n" } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq '--version'
        }
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut "$script:cacheDir`n" } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'cache dir'
        }
        Mock Invoke-ResikNativeCommand {
            $script:cleanArgs = $ArgumentList
            $script:cleanFolder = $WorkingDirectory
            Get-ChildItem -LiteralPath $script:cacheDir -Force | Remove-Item -Recurse -Force
            New-TestRunResult
        } -ParameterFilter { ($ArgumentList -join ' ') -ceq 'cache clean' }
    }

    It 'is not detected when yarn is missing' {
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'yarn' }
        (Invoke-ResikTargetAnalysis -Target (New-ResikYarnTarget)).Status | Should -BeExactly 'Skipped'
    }

    It 'does not support Yarn 2 or later' {
        $script:version = '4.5.0'

        $result = Invoke-ResikTargetAnalysis -Target (New-ResikYarnTarget)

        $result.Status | Should -BeExactly 'Skipped'
        $result.Message | Should -BeExactly 'Not detected: Yarn 4.5.0 keeps its cache per project; only Yarn 1 (Classic) is supported.'
    }

    It 'measures the cache that "yarn cache dir" reports' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikYarnTarget)

        $result.Status | Should -BeExactly 'AnalysisOnly'
        $result.EstimatedBytes | Should -Be 1500
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'runs "yarn cache clean" in the user profile folder' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikYarnTarget)

        $result.Status | Should -BeExactly 'Success'
        $script:cleanArgs | Should -Be @('cache', 'clean')
        $script:cleanFolder | Should -BeExactly ([Environment]::GetFolderPath('UserProfile'))
        $result.MeasuredBytes | Should -Be 1500
    }

    It 'refuses a protected cache location' {
        $script:cacheDir = $env:LOCALAPPDATA
        (Invoke-ResikTargetCleanup -Target (New-ResikYarnTarget)).Message | Should -BeLike '*Refusing to clean the Yarn cache*'
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'reports a failed clean' {
        Mock Invoke-ResikNativeCommand { New-TestRunResult -Status NonZeroExit -Message 'yarn.cmd exited with code 1.' } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'cache clean'
        }
        (Invoke-ResikTargetCleanup -Target (New-ResikYarnTarget)).Status | Should -BeExactly 'Failed'
    }
}

Describe 'go targets' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ('go-' + [guid]::NewGuid().ToString('N'))
        $script:env = @{ GOCACHE = (Join-Path $script:root 'go-build'); GOMODCACHE = (Join-Path $script:root 'pkg\mod') }
        New-TestFile -Path (Join-Path $script:env.GOCACHE '00\a-d') -Size 700
        New-TestFile -Path (Join-Path $script:env.GOMODCACHE 'cache\download\x.zip') -Size 3000
        $script:cleanArgs = $null
        Mock Write-Host {}
        Mock Resolve-ResikExecutable { 'C:\fake\go.exe' } -ParameterFilter { $Name -eq 'go' }
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut "$($script:env[$ArgumentList[1]])`n" } -ParameterFilter {
            $ArgumentList[0] -ceq 'env'
        }
        Mock Invoke-ResikNativeCommand {
            $script:cleanArgs = $ArgumentList
            $script:cleanFolder = $WorkingDirectory
            $variable = if ($ArgumentList[1] -ceq '-cache') { 'GOCACHE' } else { 'GOMODCACHE' }
            Remove-Item -LiteralPath $script:env[$variable] -Recurse -Force
            New-TestRunResult
        } -ParameterFilter { $ArgumentList[0] -ceq 'clean' }
    }

    It 'is not detected when go is missing' {
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'go' }
        (Invoke-ResikTargetAnalysis -Target (New-ResikGoBuildTarget)).Status | Should -BeExactly 'Skipped'
        (Invoke-ResikTargetAnalysis -Target (New-ResikGoModulesTarget)).Status | Should -BeExactly 'Skipped'
    }

    It 'measures each cache separately' {
        (Invoke-ResikTargetAnalysis -Target (New-ResikGoBuildTarget)).EstimatedBytes | Should -Be 700
        (Invoke-ResikTargetAnalysis -Target (New-ResikGoModulesTarget)).EstimatedBytes | Should -Be 3000
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'runs "go clean <Flag>" for <Id> only' -ForEach @(
        @{ Id = 'go-build'; Flag = '-cache'; Bytes = 700; Other = 'GOMODCACHE' }
        @{ Id = 'go-modules'; Flag = '-modcache'; Bytes = 3000; Other = 'GOCACHE' }
    ) {
        $target = @(Get-ResikTargetCatalog | Where-Object { $_.Id -eq $Id })[0]

        $result = Invoke-ResikTargetCleanup -Target $target

        $result.Status | Should -BeExactly 'Success'
        $script:cleanArgs | Should -Be @('clean', $Flag)
        $script:cleanFolder | Should -BeExactly ([Environment]::GetFolderPath('UserProfile'))
        $result.MeasuredBytes | Should -Be $Bytes
        $script:env[$Other] | Should -Exist
    }

    It 'skips the build cache when GOCACHE is off' {
        $script:env.GOCACHE = 'off'

        (Invoke-ResikTargetAnalysis -Target (New-ResikGoBuildTarget)).Message | Should -BeExactly 'The Go build cache is turned off (GOCACHE=off).'
        (Invoke-ResikTargetCleanup -Target (New-ResikGoBuildTarget)).Status | Should -BeExactly 'Skipped'
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'refuses a protected location' {
        $script:env.GOMODCACHE = $env:USERPROFILE
        (Invoke-ResikTargetCleanup -Target (New-ResikGoModulesTarget)).Message | Should -BeLike '*Refusing to clean GOMODCACHE*'
        $script:cleanArgs | Should -BeNullOrEmpty
    }
}
