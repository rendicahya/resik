BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')

    $script:savedEnv = @{}
    foreach ($name in @('TORCHINDUCTOR_CACHE_DIR', 'TRITON_CACHE_DIR', 'TRITON_HOME', 'TMPDIR', 'TEMP', 'TMP',
            'LOGNAME', 'USER', 'LNAME', 'USERNAME')) {
        $script:savedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}

AfterAll {
    foreach ($name in $script:savedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:savedEnv[$name])
    }
}

Describe 'Compilation cache locations' {
    BeforeEach {
        foreach ($name in $script:savedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $null) }
        $env:TEMP = 'C:\Users\me\AppData\Local\Temp'
    }
    AfterEach {
        foreach ($name in $script:savedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $script:savedEnv[$name]) }
    }

    It 'puts the Inductor cache in the temp folder, named after the user' {
        $env:USERNAME = 'me'
        $location = Get-ResikTorchInductorCacheLocation
        $location.Path | Should -BeExactly 'C:\Users\me\AppData\Local\Temp\torchinductor_me'
        $location.Variable | Should -BeExactly ''
    }

    It 'checks TMPDIR before TEMP, and LOGNAME before USERNAME, as Python does' {
        $env:TMPDIR = 'D:\tmp'
        $env:USERNAME = 'me'
        $env:LOGNAME = 'other'
        (Get-ResikTorchInductorCacheLocation).Path | Should -BeExactly 'D:\tmp\torchinductor_other'
    }

    It 'replaces characters Windows does not allow in the user name' {
        $env:USERNAME = 'DOMAIN\me'
        (Get-ResikTorchInductorCacheLocation).Path | Should -BeExactly 'C:\Users\me\AppData\Local\Temp\torchinductor_DOMAIN_me'
    }

    It 'notes when TORCHINDUCTOR_CACHE_DIR sets the folder' {
        $env:TORCHINDUCTOR_CACHE_DIR = 'D:\caches\inductor'
        $location = Get-ResikTorchInductorCacheLocation
        $location.Path | Should -BeExactly 'D:\caches\inductor'
        $location.Variable | Should -BeExactly 'TORCHINDUCTOR_CACHE_DIR'
    }

    It 'puts the Triton cache in ~\.triton\cache, or under TRITON_HOME' {
        (Get-ResikTritonCacheLocation).Path | Should -BeExactly (Join-Path $env:USERPROFILE '.triton\cache')
        $env:TRITON_HOME = 'D:\triton-home'
        $location = Get-ResikTritonCacheLocation
        $location.Path | Should -BeExactly 'D:\triton-home\.triton\cache'
        $location.Variable | Should -BeExactly ''
    }

    It 'notes when TRITON_CACHE_DIR sets the folder' {
        $env:TRITON_CACHE_DIR = 'D:\caches\triton'
        (Get-ResikTritonCacheLocation).Variable | Should -BeExactly 'TRITON_CACHE_DIR'
    }
}

Describe 'torch-inductor and triton targets' {
    BeforeEach {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:inductor = Join-Path $base 'Temp\torchinductor_me'
        $script:tritonHome = Join-Path $base 'home'
        $script:triton = Join-Path $script:tritonHome '.triton\cache'
        New-TestFile -Path (Join-Path $script:inductor 'fxgraph\ab\entry') -Size 1000
        New-TestFile -Path (Join-Path $script:inductor 'triton\0\KEY\kernel.cubin') -Size 500
        New-TestFile -Path (Join-Path $script:triton 'KEYA\kernel.json') -Size 300
        New-TestFile -Path (Join-Path $script:tritonHome '.triton\override\KEYB\kernel.ptx') -Size 70

        $script:inductorVariable = ''
        $script:tritonVariable = ''
        Mock Get-ResikTorchInductorCacheLocation { New-ResikCacheLocation -Path $script:inductor -Variable $script:inductorVariable }
        Mock Get-ResikTritonCacheLocation { New-ResikCacheLocation -Path $script:triton -Variable $script:tritonVariable }
        Mock Write-Host {}
    }

    It 'are registered and listed in the help text' {
        $ids = @(Get-ResikTargetCatalog).Id
        $ids | Should -Contain 'torch-inductor'
        $ids | Should -Contain 'triton'
        Get-ResikHelpText | Should -Match '(?m)^\s+torch-inductor\s'
    }

    It 'is not detected without the cache folder' {
        Remove-Item -LiteralPath $script:inductor -Recurse -Force
        (Invoke-ResikTargetAnalysis -Target (New-ResikTorchInductorTarget)).Message | Should -BeLike 'Not detected: *'
    }

    It 'measures each cache without changing it' {
        $inductor = Invoke-ResikTargetAnalysis -Target (New-ResikTorchInductorTarget)
        $triton = Invoke-ResikTargetAnalysis -Target (New-ResikTritonTarget)

        $inductor.EstimatedBytes | Should -Be 1500
        $triton.EstimatedBytes | Should -Be 300
        Join-Path $script:inductor 'fxgraph\ab\entry' | Should -Exist
    }

    It 'empties the Inductor cache and keeps the folder' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikTorchInductorTarget)

        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 1500
        @(Get-ChildItem -LiteralPath $script:inductor -Force).Count | Should -Be 0
        $script:inductor | Should -Exist
    }

    It 'empties the Triton cache but keeps kernels replaced by hand' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikTritonTarget)

        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 300
        Join-Path $script:triton 'KEYA' | Should -Not -Exist
        Join-Path $script:tritonHome '.triton\override\KEYB\kernel.ptx' | Should -Exist
    }

    It 'reports partial success when a kernel is in use' {
        $stream = [System.IO.File]::Open((Join-Path $script:inductor 'triton\0\KEY\kernel.cubin'), 'Open', 'Read', 'None')
        try {
            $result = Invoke-ResikTargetCleanup -Target (New-ResikTorchInductorTarget)
        }
        finally {
            $stream.Dispose()
        }

        $result.Status | Should -BeExactly 'PartialSuccess'
        $result.MeasuredBytes | Should -Be 1000
        $result.Message | Should -BeLike '*Close Python programs*'
    }

    It 'only reports a cache that an environment variable moved' {
        $script:inductorVariable = 'TORCHINDUCTOR_CACHE_DIR'
        $target = New-ResikTorchInductorTarget

        $target.Clean | Should -BeNullOrEmpty
        $result = Invoke-ResikTargetAnalysis -Target $target
        $result.EstimatedBytes | Should -Be 1500
        $result.Message | Should -BeLike '*TORCHINDUCTOR_CACHE_DIR sets this folder, so Resik does not clean it*'
    }

    It 'skips at cleanup time if the variable was set after the target was created' {
        $target = New-ResikTritonTarget
        $script:tritonVariable = 'TRITON_CACHE_DIR'

        $result = Invoke-ResikTargetCleanup -Target $target

        $result.Status | Should -BeExactly 'Skipped'
        Join-Path $script:triton 'KEYA\kernel.json' | Should -Exist
    }

    It 'refuses a protected location' {
        $script:inductor = $env:LOCALAPPDATA
        (Invoke-ResikTargetAnalysis -Target (New-ResikTorchInductorTarget)).Message | Should -BeLike '*protected location*'
        (Invoke-ResikTargetCleanup -Target (New-ResikTorchInductorTarget)).Status | Should -BeExactly 'Failed'
    }
}
