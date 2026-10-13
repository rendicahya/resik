BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')

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

Describe 'scoop-persist target' {
    BeforeEach {
        $env:SCOOP = $null
        $env:SCOOP_CACHE = $null
        $env:XDG_CONFIG_HOME = Join-Path $TestDrive ('config-' + [guid]::NewGuid().ToString('N'))

        # "kept" is installed; "gone" and "old" were uninstalled.
        $script:root = Join-Path $TestDrive ('scoop-' + [guid]::NewGuid().ToString('N'))
        $script:persist = Join-Path $script:root 'persist'
        $script:shim = Join-Path $script:root 'shims\scoop.cmd'
        New-TestFile -Path $script:shim -Size 10
        New-TestFile -Path (Join-Path $script:root 'apps\kept\1.0\kept.exe') -Size 10
        New-TestFile -Path (Join-Path $script:persist 'kept\settings.ini') -Size 100
        New-TestFile -Path (Join-Path $script:persist 'gone\settings.ini') -Size 300
        New-TestFile -Path (Join-Path $script:persist 'old\data\a.db') -Size 500

        $script:answers = @{ gone = $true; old = $true }
        Mock Write-Host {}
        Mock Resolve-ResikExecutable { $script:shim } -ParameterFilter { $Name -eq 'scoop' -and $Extension -eq '.cmd' }
        Mock Read-ResikConfirmation {
            foreach ($name in $script:answers.Keys) {
                if ($Prompt -like "*'$name'*") { return $script:answers[$name] }
            }
            $false
        }
    }

    It 'is chosen only explicitly' {
        (New-ResikScoopPersistTarget).ExplicitOnly | Should -BeTrue
        (New-ResikScoopPersistTarget).RiskLevel | Should -BeExactly 'High'
    }

    It 'lists only folders of apps that are not installed' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikScoopPersistTarget)

        $result.Status | Should -BeExactly 'AnalysisOnly'
        $result.EstimatedBytes | Should -Be 800
        $result.Message | Should -BeLike '*gone (*'
        $result.Message | Should -BeLike '*old (*'
        $result.Message | Should -Not -BeLike '*kept (*'
        Join-Path $script:persist 'gone\settings.ini' | Should -Exist
    }

    It 'ignores a persist folder that is a junction' {
        $elsewhere = Join-Path $TestDrive ('elsewhere-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $elsewhere 'x') -Size 5000
        New-Item -ItemType Junction -Path (Join-Path $script:persist 'linked') -Value $elsewhere | Out-Null

        (Invoke-ResikTargetAnalysis -Target (New-ResikScoopPersistTarget)).EstimatedBytes | Should -Be 800
    }

    It 'deletes each confirmed folder and keeps installed apps'' data' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikScoopPersistTarget) -CanPrompt $true

        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 800
        Join-Path $script:persist 'gone' | Should -Not -Exist
        Join-Path $script:persist 'old' | Should -Not -Exist
        Join-Path $script:persist 'kept\settings.ini' | Should -Exist
        Should -Invoke Read-ResikConfirmation -Times 2 -Exactly
    }

    It 'keeps a folder the user declines' {
        $script:answers.old = $false

        $result = Invoke-ResikTargetCleanup -Target (New-ResikScoopPersistTarget) -CanPrompt $true

        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 300
        $result.Message | Should -BeLike '*Kept: old*'
        Join-Path $script:persist 'old\data\a.db' | Should -Exist
    }

    It 'is skipped when every folder is declined' {
        $script:answers = @{}

        $result = Invoke-ResikTargetCleanup -Target (New-ResikScoopPersistTarget) -CanPrompt $true

        $result.Status | Should -BeExactly 'Skipped'
        $result.MeasuredBytes | Should -BeNullOrEmpty
        Join-Path $script:persist 'gone\settings.ini' | Should -Exist
    }

    It 'removes nothing and asks nothing without a terminal' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikScoopPersistTarget) -CanPrompt $false

        $result.Status | Should -BeExactly 'Skipped'
        Should -Invoke Read-ResikConfirmation -Times 0
        Join-Path $script:persist 'gone\settings.ini' | Should -Exist
    }

    It 'keeps a folder whose app was installed again while asking' {
        Mock Read-ResikConfirmation {
            New-TestFile -Path (Join-Path $script:root 'apps\gone\1.0\gone.exe') -Size 10
            $true
        } -ParameterFilter { $Prompt -like "*'gone'*" }

        $result = Invoke-ResikTargetCleanup -Target (New-ResikScoopPersistTarget) -CanPrompt $true

        $result.Message | Should -BeLike '*gone (installed again)*'
        Join-Path $script:persist 'gone\settings.ini' | Should -Exist
    }

    It 'reports a folder it could not fully delete' {
        $locked = Join-Path $script:persist 'old\data\a.db'
        $stream = [System.IO.File]::Open($locked, 'Open', 'Read', 'None')
        try {
            $result = Invoke-ResikTargetCleanup -Target (New-ResikScoopPersistTarget) -CanPrompt $true
        }
        finally {
            $stream.Dispose()
        }

        $result.Status | Should -BeExactly 'PartialSuccess'
        $result.Message | Should -BeLike '*Not fully deleted: old (1 item(s)*'
        Join-Path $script:persist 'gone' | Should -Not -Exist
    }
}

Describe 'Explicit-only targets' {
    BeforeEach {
        $script:normal = New-TestTarget -Id 'normal' -Clean { [pscustomobject]@{ Status = 'Success' } }
        $script:explicit = New-ResikTarget -Id 'explicit' -Name 'Explicit' -Category Developer -RiskLevel High `
            -Description 'Test' -Detect { [pscustomobject]@{ Available = $true } } `
            -Analyze { [pscustomobject]@{ EstimatedBytes = 1 } } -Clean { [pscustomobject]@{ Status = 'Success' } } -ExplicitOnly
    }

    It 'are left out of --all but can be chosen with --only' {
        @(Resolve-ResikSelection -Targets @($script:normal, $script:explicit) -All).Id | Should -Be @('normal')
        @(Resolve-ResikSelection -Targets @($script:normal, $script:explicit) -Only 'explicit').Id | Should -Be @('explicit')
    }

    It 'are left out of "select all" in the picker but can be toggled' {
        $analysis = @(Invoke-ResikAnalysis -Targets @($script:normal, $script:explicit))
        $state = New-ResikPickerState -Targets @($script:normal, $script:explicit) -Analysis $analysis

        Invoke-ResikPickerKey -State $state -Command 'All' | Out-Null
        @($state.Items | Where-Object { $_.Selected } | ForEach-Object { $_.Target.Id }) | Should -Be @('normal')

        $state.Cursor = 1
        Invoke-ResikPickerKey -State $state -Command 'Toggle' | Out-Null
        $state.Items[1].Selected | Should -BeTrue
    }

    It 'are left out of "a" in the numbered list but can be picked by number' {
        Mock Write-Host {}
        $analysis = @(Invoke-ResikAnalysis -Targets @($script:normal, $script:explicit))

        Mock Read-ResikLine { 'a' }
        $state = New-ResikPickerState -Targets @($script:normal, $script:explicit) -Analysis $analysis
        Read-ResikNumberedSelection -State $state | Should -BeExactly 'Confirm'
        @($state.Items | Where-Object { $_.Selected } | ForEach-Object { $_.Target.Id }) | Should -Be @('normal')

        Mock Read-ResikLine { '2' }
        $state = New-ResikPickerState -Targets @($script:normal, $script:explicit) -Analysis $analysis
        Read-ResikNumberedSelection -State $state | Out-Null
        @($state.Items | Where-Object { $_.Selected } | ForEach-Object { $_.Target.Id }) | Should -Be @('explicit')
    }

    It 'passes CanPrompt to Clean, which is false unless a person can answer' {
        $probe = New-TestTarget -Id 'probe' -Clean { param($Context) [pscustomobject]@{ Status = 'Success'; Details = "$($Context.CanPrompt)" } }
        (Invoke-ResikTargetCleanup -Target $probe).Message | Should -BeExactly 'False'
        (Invoke-ResikTargetCleanup -Target $probe -CanPrompt $true).Message | Should -BeExactly 'True'
    }
}
