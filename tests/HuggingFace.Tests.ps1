BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
    $script:hfVariables = @('HF_HUB_CACHE', 'HUGGINGFACE_HUB_CACHE', 'HF_HOME', 'XDG_CACHE_HOME')
}

Describe 'Hugging Face cache location' {
    BeforeEach {
        $script:savedEnv = @{}
        foreach ($name in $script:hfVariables) {
            $script:savedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $null)
        }
    }

    AfterEach {
        foreach ($name in $script:hfVariables) { [Environment]::SetEnvironmentVariable($name, $script:savedEnv[$name]) }
    }

    It 'defaults to ~\.cache\huggingface\hub' {
        Get-ResikHuggingFaceCacheDirectory | Should -BeExactly (Join-Path $env:USERPROFILE '.cache\huggingface\hub')
    }

    It 'uses <Variable> in the documented order' -ForEach @(
        @{ Variable = 'XDG_CACHE_HOME'; Value = 'C:\xdg'; Expected = 'C:\xdg\huggingface\hub' }
        @{ Variable = 'HF_HOME'; Value = 'C:\hfhome'; Expected = 'C:\hfhome\hub' }
        @{ Variable = 'HUGGINGFACE_HUB_CACHE'; Value = 'C:\legacy'; Expected = 'C:\legacy' }
        @{ Variable = 'HF_HUB_CACHE'; Value = 'C:\hub'; Expected = 'C:\hub' }
    ) {
        # Every variable of lower priority is set too, so the order is tested.
        $names = @('XDG_CACHE_HOME', 'HF_HOME', 'HUGGINGFACE_HUB_CACHE', 'HF_HUB_CACHE')
        foreach ($name in @($names | Select-Object -First ($names.IndexOf($Variable)))) {
            [Environment]::SetEnvironmentVariable($name, "C:\lower-$name")
        }
        [Environment]::SetEnvironmentVariable($Variable, $Value)

        Get-ResikHuggingFaceCacheDirectory | Should -BeExactly $Expected
    }

    It 'refuses a protected location' {
        $env:HF_HUB_CACHE = $env:USERPROFILE
        { Get-ResikHuggingFaceCacheDirectory } | Should -Throw 'Refusing to clean the Hugging Face cache:*protected*'
    }

    It 'refuses a relative path' {
        $env:HF_HUB_CACHE = 'hub'
        { Get-ResikHuggingFaceCacheDirectory } | Should -Throw '*not a fully qualified local path*'
    }
}

Describe 'ConvertFrom-ResikHuggingFaceSize' {
    It 'reads <Text> as <Bytes> bytes (powers of 1000)' -ForEach @(
        @{ Text = '500.0'; Bytes = 500 }
        @{ Text = '3.5K'; Bytes = 3500 }
        @{ Text = '2.5M'; Bytes = 2500000 }
        @{ Text = '1.9G'; Bytes = 1900000000 }
    ) {
        ConvertFrom-ResikHuggingFaceSize -Text $Text | Should -Be $Bytes
    }

    It 'rejects unknown size text' {
        { ConvertFrom-ResikHuggingFaceSize -Text '3.5 KiB' } | Should -Throw "Unexpected size*"
    }
}

Describe 'huggingface target' {
    BeforeEach {
        $script:savedHubCache = $env:HF_HUB_CACHE
        $script:cacheDir = Join-Path $TestDrive ('hub-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $script:cacheDir 'models--org--m\snapshots\bbbb\w.bin') -Size 3000
        New-TestFile -Path (Join-Path $script:cacheDir 'models--org--m\snapshots\aaaa\w.bin') -Size 1000
        $env:HF_HUB_CACHE = $script:cacheDir
        $script:cleanArgs = $null
        $script:previewOutput = '{"dry_run": true, "revisions": 1, "incomplete": 0, "shared_blobs": 0, "size": "3.0K"}'
        Mock Write-Host {}
        Mock Resolve-ResikExecutable { 'C:\fake\hf.exe' } -ParameterFilter { $Name -eq 'hf' }
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut "$script:previewOutput`n" } -ParameterFilter {
            $ArgumentList -contains '--dry-run'
        }
        Mock Invoke-ResikNativeCommand {
            $script:cleanArgs = $ArgumentList
            Remove-Item -LiteralPath (Join-Path $script:cacheDir 'models--org--m\snapshots\bbbb') -Recurse -Force
            New-TestRunResult -StdOut "Cache deletion done. Saved 3.0K.`n{`"revisions_deleted`": 1, `"freed`": `"3.0K`"}`n"
        } -ParameterFilter { $ArgumentList -contains '--yes' }
    }

    AfterEach {
        $env:HF_HUB_CACHE = $script:savedHubCache
    }

    It 'is not detected without the hf command' {
        Mock Resolve-ResikExecutable { $null } -ParameterFilter { $Name -eq 'hf' }
        (Invoke-ResikTargetAnalysis -Target (New-ResikHuggingFaceTarget)).Status | Should -BeExactly 'Skipped'
    }

    It 'estimates from the dry run of "hf cache prune" on the validated folder' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikHuggingFaceTarget)

        $result.Status | Should -BeExactly 'AnalysisOnly'
        $result.EstimatedBytes | Should -Be 3000
        $result.Message | Should -BeExactly "$script:cacheDir (1 unused revision(s), 0 incomplete download(s))"
        Should -Invoke Invoke-ResikNativeCommand -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -ceq "cache prune --dry-run --cache-dir $script:cacheDir --format json"
        }
        Should -Invoke Invoke-ResikNativeCommand -Times 0 -ParameterFilter { $ArgumentList -contains '--yes' }
    }

    It 'reports zero when there is nothing to prune (hf prints nothing)' {
        $script:previewOutput = ''
        (Invoke-ResikTargetAnalysis -Target (New-ResikHuggingFaceTarget)).EstimatedBytes | Should -Be 0
    }

    It 'fails analysis on output it does not understand' {
        $script:previewOutput = 'About to delete 1 unreferenced revision(s) (3.0K total).'
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikHuggingFaceTarget)
        $result.Status | Should -BeExactly 'Failed'
        $result.Message | Should -BeLike '*Unexpected output*'
    }

    It 'does not run hf when there is no cache' {
        Remove-Item -LiteralPath $script:cacheDir -Recurse -Force
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikHuggingFaceTarget)
        $result.EstimatedBytes | Should -Be 0
        Should -Invoke Invoke-ResikNativeCommand -Times 0
    }

    It 'runs "hf cache prune --yes" and measures the whole cache' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikHuggingFaceTarget)

        $result.Status | Should -BeExactly 'Success'
        $script:cleanArgs | Should -Be @('cache', 'prune', '--yes', '--cache-dir', $script:cacheDir, '--format', 'json')
        $result.MeasuredBytes | Should -Be 3000
        Join-Path $script:cacheDir 'models--org--m\snapshots\aaaa\w.bin' | Should -Exist
    }

    It 'skips cleanup when the preview finds nothing' {
        $script:previewOutput = '{"dry_run": true, "revisions": 0, "incomplete": 0, "shared_blobs": 0, "size": "0.0"}'
        (Invoke-ResikTargetCleanup -Target (New-ResikHuggingFaceTarget)).Status | Should -BeExactly 'Skipped'
        $script:cleanArgs | Should -BeNullOrEmpty
    }

    It 'reports a failed prune' {
        Mock Invoke-ResikNativeCommand { New-TestRunResult -Status NonZeroExit -Message 'hf.exe exited with code 1.' } -ParameterFilter {
            $ArgumentList -contains '--yes'
        }
        (Invoke-ResikTargetCleanup -Target (New-ResikHuggingFaceTarget)).Status | Should -BeExactly 'Failed'
    }
}
