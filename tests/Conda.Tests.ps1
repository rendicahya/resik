BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'ConvertFrom-ResikFirstJson' {
    It 'reads the first object and ignores what follows' {
        $text = "{`"a`": `"x } {`", `"b`": {`"c`": 1}}`n{`"message`": `"Dry run. Exiting.`"}`n"
        $value = ConvertFrom-ResikFirstJson -Text $text
        $value.a | Should -BeExactly 'x } {'
        $value.b.c | Should -Be 1
    }

    It 'fails without a complete object' {
        { ConvertFrom-ResikFirstJson -Text 'no json' } | Should -Throw 'No JSON object found.'
        { ConvertFrom-ResikFirstJson -Text '{"a": 1' } | Should -Throw 'Incomplete JSON object.'
    }
}

Describe 'Get-ResikCondaExecutable' {
    BeforeEach {
        $script:savedCondaExe = $env:CONDA_EXE
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'conda' }
    }

    AfterEach {
        $env:CONDA_EXE = $script:savedCondaExe
    }

    It 'falls back to CONDA_EXE when it names an existing conda.exe' {
        $exe = Join-Path $TestDrive 'Scripts\conda.exe'
        New-TestFile -Path $exe
        $env:CONDA_EXE = $exe
        Get-ResikCondaExecutable | Should -BeExactly $exe
    }

    It 'ignores CONDA_EXE when it names <Case>' -ForEach @(
        @{ Case = 'another program'; Leaf = 'Scripts\other.exe'; Create = $true }
        @{ Case = 'a missing file'; Leaf = 'Scripts\missing\conda.exe'; Create = $false }
    ) {
        $exe = Join-Path $TestDrive $Leaf
        if ($Create) { New-TestFile -Path $exe }
        $env:CONDA_EXE = $exe
        Get-ResikCondaExecutable | Should -BeNullOrEmpty
    }
}

Describe 'conda target' {
    BeforeEach {
        $script:pkgs = Join-Path $TestDrive ('pkgs-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $script:pkgs 'old-1.0-0.conda') -Size 2000
        New-TestFile -Path (Join-Path $script:pkgs 'old-1.0-0\info\index.json') -Size 500
        New-TestFile -Path (Join-Path $script:pkgs 'cache\repodata.json') -Size 100
        New-TestFile -Path (Join-Path $script:pkgs 'used-2.0-0\info\index.json') -Size 700
        $script:cleanArgs = $null
        $script:preview = [ordered]@{
            success     = $true
            tarballs    = @{ total_size = 2000; pkgs_dirs = @{ $script:pkgs = @('old-1.0-0.conda') } }
            index_cache = @{ files = @(Join-Path $script:pkgs 'cache') }
            packages    = @{ total_size = 500; pkgs_dirs = @{ $script:pkgs = @('old-1.0-0') } }
            tempfiles   = @()
            logfiles    = @()
        }
        Mock Write-Host {}
        Mock Resolve-ResikExecutable { 'C:\fake\conda.exe' } -ParameterFilter { $Name -eq 'conda' }
        Mock Invoke-ResikNativeCommand {
            # A dry run also prints the DryRunExit message as a second object.
            New-TestRunResult -StdOut (($script:preview | ConvertTo-Json -Depth 5) + "`n{`"message`": `"Dry run. Exiting.`"}")
        } -ParameterFilter { $ArgumentList -contains '--dry-run' }
        Mock Invoke-ResikNativeCommand {
            $script:cleanArgs = $ArgumentList
            Remove-Item -LiteralPath (Join-Path $script:pkgs 'old-1.0-0.conda'), (Join-Path $script:pkgs 'old-1.0-0'), (Join-Path $script:pkgs 'cache') -Recurse -Force
            New-TestRunResult -StdOut '{"success": true}'
        } -ParameterFilter { $ArgumentList -contains '--yes' }
    }

    It 'is not detected without conda' {
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'conda' }
        $saved = $env:CONDA_EXE
        try {
            $env:CONDA_EXE = $null
            (Invoke-ResikTargetAnalysis -Target (New-ResikCondaTarget)).Status | Should -BeExactly 'Skipped'
        }
        finally { $env:CONDA_EXE = $saved }
    }

    It 'estimates unused packages and tarballs from "conda clean --all --dry-run --json"' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikCondaTarget)

        $result.Status | Should -BeExactly 'AnalysisOnly'
        $result.EstimatedBytes | Should -Be 2500
        $result.Message | Should -BeLike "$script:pkgs (*"
        Should -Invoke Invoke-ResikNativeCommand -Times 0 -ParameterFilter { $ArgumentList -contains '--yes' }
    }

    It 'measures a package folder once even when conda also lists a folder inside it' {
        $preview = Get-ResikCondaCleanPreview -CondaPath 'C:\fake\conda.exe'
        $preview.Paths | Should -Be @($script:pkgs)
    }

    It 'runs "conda clean --all --yes --json" and never --force-pkgs-dirs' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikCondaTarget)

        $result.Status | Should -BeExactly 'Success'
        $script:cleanArgs | Should -Be @('clean', '--all', '--yes', '--json')
        $result.MeasuredBytes | Should -Be 2600
        Join-Path $script:pkgs 'used-2.0-0\info\index.json' | Should -Exist
        Should -Invoke Invoke-ResikNativeCommand -Times 0 -ParameterFilter {
            $ArgumentList -contains '--force-pkgs-dirs' -or $ArgumentList -contains '-f'
        }
    }

    It 'skips cleanup when conda reports nothing to remove' {
        $script:preview.tarballs = @{ total_size = 0; pkgs_dirs = @{} }
        $script:preview.packages = @{ total_size = 0; pkgs_dirs = @{} }
        $script:preview.index_cache = @{ files = @() }
        (Invoke-ResikTargetCleanup -Target (New-ResikCondaTarget)).Status | Should -BeExactly 'Skipped'
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'refuses a protected package cache' {
        $script:preview.packages = @{ total_size = 1; pkgs_dirs = @{ $env:LOCALAPPDATA = @('x') } }
        $result = Invoke-ResikTargetCleanup -Target (New-ResikCondaTarget)
        $result.Status | Should -BeExactly 'Failed'
        $result.Message | Should -BeLike '*Refusing to clean the conda package cache*'
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'fails analysis when the preview has no package section' {
        $script:preview.Remove('packages')
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikCondaTarget)
        $result.Status | Should -BeExactly 'Failed'
        $result.Message | Should -BeLike "*'packages' is missing*"
    }
}
