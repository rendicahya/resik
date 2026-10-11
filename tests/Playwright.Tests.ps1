BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'playwright target' {
    BeforeEach {
        $script:savedBrowsersPath = $env:PLAYWRIGHT_BROWSERS_PATH
        $script:browsers = Join-Path $TestDrive ('ms-playwright-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $script:browsers 'chromium-1234\chrome.exe') -Size 4000
        New-TestFile -Path (Join-Path $script:browsers 'chromium_headless_shell-1234\shell.exe') -Size 2000
        New-TestFile -Path (Join-Path $script:browsers 'ffmpeg-1011\ffmpeg.exe') -Size 500
        New-TestFile -Path (Join-Path $script:browsers '.links\abc') -Size 10
        New-TestFile -Path (Join-Path $script:browsers 'notes\keep.txt') -Size 30
        $env:PLAYWRIGHT_BROWSERS_PATH = $script:browsers
        $script:cleanArgs = $null
        Mock Write-Host {}
        Mock Resolve-ResikExecutable { 'C:\fake\playwright.exe' } -ParameterFilter { $Name -eq 'playwright' -and $Extension -ne '.cmd' }
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'playwright' -and $Extension -eq '.cmd' }
        Mock Invoke-ResikNativeCommand {
            $script:cleanArgs = $ArgumentList
            Get-ChildItem -LiteralPath $script:browsers -Directory | Where-Object { $_.Name -match '-\d+$' } |
                Remove-Item -Recurse -Force
            New-TestRunResult
        } -ParameterFilter { $ArgumentList[0] -ceq 'uninstall' }
    }

    AfterEach {
        $env:PLAYWRIGHT_BROWSERS_PATH = $script:savedBrowsersPath
    }

    It 'is not detected without the playwright command, and points to npx' {
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'playwright' }
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikPlaywrightTarget)
        $result.Status | Should -BeExactly 'Skipped'
        $result.Message | Should -BeLike '*npx playwright uninstall --all*'
    }

    It 'also finds playwright.cmd from a global npm install' {
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'playwright' -and $Extension -ne '.cmd' }
        Mock Resolve-ResikExecutable { 'C:\fake\playwright.cmd' } -ParameterFilter { $Name -eq 'playwright' -and $Extension -eq '.cmd' }
        Get-ResikPlaywrightExecutable | Should -BeExactly 'C:\fake\playwright.cmd'
    }

    It 'measures only the browser folders' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikPlaywrightTarget)

        $result.Status | Should -BeExactly 'AnalysisOnly'
        $result.EstimatedBytes | Should -Be 6500
        $result.Message | Should -BeExactly "$script:browsers (chromium-1234, chromium_headless_shell-1234, ffmpeg-1011)"
        Should -Invoke Invoke-ResikNativeCommand -Times 0
    }

    It 'defaults to %LOCALAPPDATA%\ms-playwright' {
        $env:PLAYWRIGHT_BROWSERS_PATH = $null
        Get-ResikPlaywrightBrowsersDirectory | Should -BeExactly (Join-Path $env:LOCALAPPDATA 'ms-playwright')
    }

    It 'leaves browsers kept inside projects alone (PLAYWRIGHT_BROWSERS_PATH=0)' {
        $env:PLAYWRIGHT_BROWSERS_PATH = '0'
        (Invoke-ResikTargetAnalysis -Target (New-ResikPlaywrightTarget)).Message | Should -BeLike 'PLAYWRIGHT_BROWSERS_PATH=0*'
        (Invoke-ResikTargetCleanup -Target (New-ResikPlaywrightTarget)).Status | Should -BeExactly 'Skipped'
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'runs "playwright uninstall --all" and keeps other folders' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikPlaywrightTarget)

        $result.Status | Should -BeExactly 'Success'
        $script:cleanArgs | Should -Be @('uninstall', '--all')
        $result.MeasuredBytes | Should -Be 6500
        Join-Path $script:browsers 'notes\keep.txt' | Should -Exist
    }

    It 'reports partial success when a browser could not be removed' {
        Mock Invoke-ResikNativeCommand {
            Remove-Item -LiteralPath (Join-Path $script:browsers 'ffmpeg-1011') -Recurse -Force
            New-TestRunResult
        } -ParameterFilter { $ArgumentList[0] -ceq 'uninstall' }

        (Invoke-ResikTargetCleanup -Target (New-ResikPlaywrightTarget)).Status | Should -BeExactly 'PartialSuccess'
    }

    It 'refuses a protected browsers folder' {
        $env:PLAYWRIGHT_BROWSERS_PATH = $env:LOCALAPPDATA
        $result = Invoke-ResikTargetCleanup -Target (New-ResikPlaywrightTarget)
        $result.Status | Should -BeExactly 'Failed'
        $result.Message | Should -BeLike '*Refusing to clean Playwright browsers*'
        $script:cleanArgs | Should -BeNullOrEmpty
    }
}
