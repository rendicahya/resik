BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'choco target' {
    BeforeEach {
        $script:cleanArgs = $null
        Mock Write-Host {}
        Mock Resolve-ResikExecutable { 'C:\fake\choco.exe' } -ParameterFilter { $Name -eq 'choco' }
        Mock Invoke-ResikNativeCommand {
            New-TestRunResult -StdOut "Chocolatey v2.7.3`r`nUser HTTP Cache`r`nWe found 1 cached sources.`r`nWe found 23 cached items for all sources, where 23 items have expired.`r`n"
        } -ParameterFilter { ($ArgumentList -join ' ') -ceq 'cache list' }
        Mock Invoke-ResikNativeCommand { $script:cleanArgs = $ArgumentList; New-TestRunResult } -ParameterFilter {
            $ArgumentList[1] -ceq 'remove'
        }
    }

    It 'reports the item count without a size estimate' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikChocolateyTarget)

        $result.Status | Should -BeExactly 'AnalysisOnly'
        $result.EstimatedBytes | Should -BeNullOrEmpty
        $result.Message | Should -BeExactly 'User HTTP cache: We found 23 cached items for all sources, where 23 items have expired.'
    }

    It 'runs "choco cache remove --yes" and reports no measurements it does not have' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikChocolateyTarget)

        $result.Status | Should -BeExactly 'Success'
        $script:cleanArgs | Should -Be @('cache', 'remove', '--yes')
        $result.MeasuredBytes | Should -BeNullOrEmpty
        $result.FreeSpaceChangeBytes | Should -BeNullOrEmpty
    }

    It 'reports a failed removal' {
        Mock Invoke-ResikNativeCommand { New-TestRunResult -Status NonZeroExit -Message 'choco.exe exited with code 1.' } -ParameterFilter {
            $ArgumentList[1] -ceq 'remove'
        }
        (Invoke-ResikTargetCleanup -Target (New-ResikChocolateyTarget)).Status | Should -BeExactly 'Failed'
    }
}

Describe 'nuget target' {
    BeforeEach {
        $script:cacheDir = Join-Path $TestDrive ('v3-cache-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $script:cacheDir 'source\list.dat') -Size 1234
        $script:cleanArgs = $null
        Mock Write-Host {}
        Mock Resolve-ResikExecutable { 'C:\fake\dotnet.exe' } -ParameterFilter { $Name -eq 'dotnet' }
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut "8.0.404 [C:\Program Files\dotnet\sdk]`r`n" } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq '--list-sdks'
        }
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut "http-cache: $script:cacheDir\`r`n" } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'nuget locals http-cache --list'
        }
        Mock Invoke-ResikNativeCommand {
            $script:cleanArgs = $ArgumentList
            Remove-Item -LiteralPath $script:cacheDir -Recurse -Force
            New-TestRunResult
        } -ParameterFilter { $ArgumentList -contains '--clear' }
    }

    It 'is not detected without a .NET SDK' {
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut '' } -ParameterFilter { ($ArgumentList -join ' ') -ceq '--list-sdks' }

        $result = Invoke-ResikTargetAnalysis -Target (New-ResikNuGetTarget)

        $result.Status | Should -BeExactly 'Skipped'
        $result.Message | Should -BeLike '*No .NET SDK*'
    }

    It 'reads the location in either output format: <Line>' -ForEach @(
        @{ Line = 'http-cache: {0}' }
        @{ Line = 'info : http-cache: {0}' }
    ) {
        $script:line = $Line -f $script:cacheDir
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut $script:line } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'nuget locals http-cache --list'
        }
        Get-ResikNuGetHttpCacheDirectory -DotnetPath 'C:\fake\dotnet.exe' | Should -BeExactly $script:cacheDir
    }

    It 'measures the HTTP cache' {
        (Invoke-ResikTargetAnalysis -Target (New-ResikNuGetTarget)).EstimatedBytes | Should -Be 1234
    }

    It 'clears only the HTTP cache, never global-packages' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikNuGetTarget)

        $result.Status | Should -BeExactly 'Success'
        $script:cleanArgs | Should -Be @('nuget', 'locals', 'http-cache', '--clear')
        $result.MeasuredBytes | Should -Be 1234
        Should -Invoke Invoke-ResikNativeCommand -Times 0 -ParameterFilter {
            $ArgumentList -contains 'global-packages' -or $ArgumentList -contains 'all'
        }
    }

    It 'refuses a protected location' {
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut "http-cache: $env:LOCALAPPDATA" } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'nuget locals http-cache --list'
        }

        (Invoke-ResikTargetCleanup -Target (New-ResikNuGetTarget)).Message | Should -BeLike '*Refusing to clean the NuGet HTTP cache*'
        $script:cleanArgs | Should -BeNullOrEmpty
    }
}

Describe 'Target catalog' {
    It 'lists every target in the help text' {
        $help = Get-ResikHelpText
        foreach ($target in @(Get-ResikTargetCatalog)) {
            $help | Should -Match "(?m)^\s+$([regex]::Escape($target.Id))\s+$([regex]::Escape($target.Name))\s*$"
        }
    }

    It 'gives every target a unique ID, and Clean to all but the analysis-only ones' {
        Mock Test-ResikAdministrator { $true }
        $catalog = @(Get-ResikTargetCatalog)
        $catalog.Count | Should -Be 24
        @($catalog | Where-Object { $null -eq $_.Clean } | ForEach-Object { $_.Id }) | Should -Be @('gradle', 'maven', 'jetbrains')
        @($catalog.Id | Select-Object -Unique).Count | Should -Be $catalog.Count
    }
}
