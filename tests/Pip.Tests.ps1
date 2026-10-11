BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
    $script:windowsApps = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Microsoft\WindowsApps'
}

Describe 'Test-ResikWindowsAppsPythonStub' {
    It 'treats WindowsApps python.exe as a stub when no Store Python is installed' {
        Mock Get-ChildItem { } -ParameterFilter { $Filter -eq 'PythonSoftwareFoundation.Python.*' }
        Test-ResikWindowsAppsPythonStub -Path (Join-Path $script:windowsApps 'python.exe') | Should -BeTrue
    }

    It 'accepts WindowsApps python.exe when a Store Python is installed' {
        Mock Get-ChildItem { [pscustomobject]@{ Name = 'PythonSoftwareFoundation.Python.3.13_x' } } -ParameterFilter {
            $Filter -eq 'PythonSoftwareFoundation.Python.*'
        }
        Test-ResikWindowsAppsPythonStub -Path (Join-Path $script:windowsApps 'python.exe') | Should -BeFalse
    }

    It 'accepts python.exe elsewhere' {
        Test-ResikWindowsAppsPythonStub -Path 'C:\Python313\python.exe' | Should -BeFalse
    }
}

Describe 'Find-ResikPipPython' {
    BeforeEach {
        Mock Resolve-ResikExecutable { $null }
        Mock Get-Command { } -ParameterFilter { $Name -eq 'python.exe' }
    }

    It 'skips the Store stub and interpreters without pip' {
        Mock Get-Command {
            [pscustomobject]@{ Path = (Join-Path $script:windowsApps 'python.exe') }
            [pscustomobject]@{ Path = 'C:\NoPip\python.exe' }
            [pscustomobject]@{ Path = 'C:\Good\python.exe' }
        } -ParameterFilter { $Name -eq 'python.exe' }
        Mock Test-ResikWindowsAppsPythonStub { $Path -like '*WindowsApps*' }
        Mock Invoke-ResikNativeCommand { New-TestRunResult -Status NonZeroExit } -ParameterFilter { $FilePath -eq 'C:\NoPip\python.exe' }
        Mock Invoke-ResikNativeCommand { New-TestRunResult } -ParameterFilter { $FilePath -eq 'C:\Good\python.exe' }
        Mock Invoke-ResikNativeCommand { throw 'the stub must never run' } -ParameterFilter { $FilePath -like '*WindowsApps*' }

        (Find-ResikPipPython).FilePath | Should -BeExactly 'C:\Good\python.exe'
    }

    It 'falls back to a uv-managed Python, never a project environment' {
        Mock Resolve-ResikExecutable { 'C:\fake\uv.exe' } -ParameterFilter { $Name -eq 'uv' }
        $script:uvPython = Join-Path $TestDrive 'uvpython\python.exe'
        New-TestFile -Path $script:uvPython
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut $script:uvPython } -ParameterFilter { $FilePath -eq 'C:\fake\uv.exe' }
        Mock Invoke-ResikNativeCommand { New-TestRunResult } -ParameterFilter { $FilePath -like '*uvpython*' }

        $found = Find-ResikPipPython

        $found.FilePath | Should -BeExactly $script:uvPython
        $found.Source | Should -BeExactly 'uv-managed Python'
        Should -Invoke Invoke-ResikNativeCommand -ParameterFilter {
            $FilePath -eq 'C:\fake\uv.exe' -and $ArgumentList -contains '--managed-python' -and $ArgumentList -contains '--no-project' -and
            $ArgumentList -contains '--no-python-downloads'
        }
    }

    It 'returns $null when nothing has pip' {
        Find-ResikPipPython | Should -BeNullOrEmpty
    }
}

Describe 'pip target' {
    BeforeEach {
        $script:cacheDir = Join-Path $TestDrive ('pip-' + [guid]::NewGuid().ToString('N'))
        $script:cleanArgs = $null
        Mock Write-Host {}
        Mock Find-ResikPipPython { [pscustomobject]@{ FilePath = 'C:\fake\python.exe'; Source = 'python on PATH' } }
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut "$script:cacheDir`r`n" } -ParameterFilter {
            ($ArgumentList -join ' ') -like '-m pip cache dir*'
        }
        Mock Invoke-ResikNativeCommand {
            $script:cleanArgs = $ArgumentList
            foreach ($name in @('http', 'http-v2', 'wheels')) {
                Get-ChildItem -LiteralPath (Join-Path $script:cacheDir $name) -Recurse -File -ErrorAction SilentlyContinue | Remove-Item
            }
            New-TestRunResult
        } -ParameterFilter { ($ArgumentList -join ' ') -like '-m pip cache purge*' }

        New-TestFile -Path (Join-Path $script:cacheDir 'http-v2\a\b') -Size 2000
        New-TestFile -Path (Join-Path $script:cacheDir 'wheels\x\pkg.whl') -Size 500
        New-TestFile -Path (Join-Path $script:cacheDir 'selfcheck\other.json') -Size 70
    }

    It 'is not detected without a Python that has pip' {
        Mock Find-ResikPipPython { $null }
        (Invoke-ResikTargetAnalysis -Target (New-ResikPipTarget)).Status | Should -BeExactly 'Skipped'
    }

    It 'measures only the folders that pip cache purge empties' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikPipTarget)

        $result.Status | Should -BeExactly 'AnalysisOnly'
        $result.EstimatedBytes | Should -Be 2500
        Should -Invoke Invoke-ResikNativeCommand -Times 0 -ParameterFilter { $ArgumentList -contains 'purge' }
    }

    It 'runs pip cache purge on the validated directory' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikPipTarget)

        $result.Status | Should -BeExactly 'Success'
        $script:cleanArgs | Should -Be @('-m', 'pip', 'cache', 'purge', '--cache-dir', $script:cacheDir, '--no-input', '--disable-pip-version-check')
        $result.MeasuredBytes | Should -Be 2500
    }

    It 'refuses a protected cache location' {
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut $env:LOCALAPPDATA } -ParameterFilter {
            ($ArgumentList -join ' ') -like '-m pip cache dir*'
        }

        (Invoke-ResikTargetCleanup -Target (New-ResikPipTarget)).Message | Should -BeLike '*Refusing to clean the pip cache*'
        $script:cleanArgs | Should -BeNullOrEmpty
    }
}
