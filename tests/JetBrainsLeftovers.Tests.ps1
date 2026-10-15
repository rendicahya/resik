BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'jetbrains-leftovers target' {
    BeforeEach {
        # PyCharmEdu2021.3 has both folders, Rider2024.1 only settings;
        # consentOptions and Toolbox are not IDE versions.
        $base = Join-Path $TestDrive ('jb-' + [guid]::NewGuid().ToString('N'))
        $script:system = Join-Path $base 'Local\JetBrains'
        $script:config = Join-Path $base 'Roaming\JetBrains'
        New-TestFile -Path (Join-Path $script:system 'PyCharmEdu2021.3\index\stubs.dat') -Size 1000
        New-TestFile -Path (Join-Path $script:system 'PyCharmEdu2021.3\LocalHistory\changes.dat') -Size 200
        New-TestFile -Path (Join-Path $script:config 'PyCharmEdu2021.3\options\ide.xml') -Size 30
        New-TestFile -Path (Join-Path $script:config 'Rider2024.1\options\ide.xml') -Size 400
        New-TestFile -Path (Join-Path $script:system 'Toolbox\apps.json') -Size 5000
        New-TestFile -Path (Join-Path $script:config 'consentOptions\accepted') -Size 10

        $script:answers = @{ 'PyCharmEdu2021.3' = $true; 'Rider2024.1' = $true }
        Mock Write-Host {}
        Mock Get-ResikJetBrainsSystemRoot { $script:system }
        Mock Get-ResikJetBrainsConfigRoot { $script:config }
        Mock Get-ResikJetBrainsRunningIde { }
        Mock Read-ResikConfirmation {
            foreach ($name in $script:answers.Keys) {
                if ($Prompt -like "*of $name (*") { return $script:answers[$name] }
            }
            $false
        }
    }

    It 'is registered as a High-risk, explicit-only target' {
        $target = @(Get-ResikTargetCatalog) | Where-Object Id -eq 'jetbrains-leftovers'
        $target.ExplicitOnly | Should -BeTrue
        $target.RiskLevel | Should -BeExactly 'High'
        $target.Clean | Should -Not -BeNullOrEmpty
    }

    It 'is not detected without IDE version folders' {
        Mock Get-ResikJetBrainsSystemRoot { Join-Path $TestDrive 'none-local' }
        Mock Get-ResikJetBrainsConfigRoot { Join-Path $TestDrive 'none-roaming' }
        (Invoke-ResikTargetAnalysis -Target (New-ResikJetBrainsLeftoverTarget)).Message | Should -BeLike 'Not detected: *'
    }

    It 'measures every IDE version in both folders, and nothing else' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikJetBrainsLeftoverTarget)

        $result.Status | Should -BeExactly 'AnalysisOnly'
        $result.EstimatedBytes | Should -Be 1630
        $result.Message | Should -BeExactly '2 IDE version(s), each with its settings, plugins, and Local History: PyCharmEdu2021.3 (1.2 KB), Rider2024.1 (400 B)'
        Join-Path $script:system 'PyCharmEdu2021.3\index\stubs.dat' | Should -Exist
    }

    It 'says to close a running IDE' {
        Mock Get-ResikJetBrainsRunningIde { 'pycharm64' }
        (Invoke-ResikTargetAnalysis -Target (New-ResikJetBrainsLeftoverTarget)).Message | Should -BeLike '*. Close pycharm64 before cleaning'
    }

    It 'ignores a version folder that is a junction' {
        $elsewhere = Join-Path $TestDrive ('elsewhere-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $elsewhere 'x') -Size 9000
        New-Item -ItemType Junction -Path (Join-Path $script:system 'IntelliJIdea2025.1') -Value $elsewhere | Out-Null

        (Invoke-ResikTargetAnalysis -Target (New-ResikJetBrainsLeftoverTarget)).EstimatedBytes | Should -Be 1630
    }

    It 'deletes both folders of each confirmed version and nothing else' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikJetBrainsLeftoverTarget) -CanPrompt $true

        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 1630
        $result.Message | Should -BeExactly 'Deleted: PyCharmEdu2021.3, Rider2024.1'
        Join-Path $script:system 'PyCharmEdu2021.3' | Should -Not -Exist
        Join-Path $script:config 'PyCharmEdu2021.3' | Should -Not -Exist
        Join-Path $script:config 'Rider2024.1' | Should -Not -Exist
        Join-Path $script:system 'Toolbox\apps.json' | Should -Exist
        Join-Path $script:config 'consentOptions\accepted' | Should -Exist
        Should -Invoke Read-ResikConfirmation -Times 2 -Exactly
    }

    It 'keeps a version the user declines' {
        $script:answers['Rider2024.1'] = $false

        $result = Invoke-ResikTargetCleanup -Target (New-ResikJetBrainsLeftoverTarget) -CanPrompt $true

        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 1230
        $result.Message | Should -BeExactly 'Deleted: PyCharmEdu2021.3. Kept: Rider2024.1'
        Join-Path $script:config 'Rider2024.1\options\ide.xml' | Should -Exist
    }

    It 'removes nothing and asks nothing without a terminal' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikJetBrainsLeftoverTarget) -CanPrompt $false

        $result.Status | Should -BeExactly 'Skipped'
        Should -Invoke Read-ResikConfirmation -Times 0
        Join-Path $script:system 'PyCharmEdu2021.3\index\stubs.dat' | Should -Exist
    }

    It 'removes nothing and asks nothing while an IDE is running' {
        Mock Get-ResikJetBrainsRunningIde { 'idea64' }

        $result = Invoke-ResikTargetCleanup -Target (New-ResikJetBrainsLeftoverTarget) -CanPrompt $true

        $result.Status | Should -BeExactly 'Skipped'
        $result.Message | Should -BeLike 'A JetBrains IDE is running (idea64).*'
        Should -Invoke Read-ResikConfirmation -Times 0
        Join-Path $script:system 'PyCharmEdu2021.3\index\stubs.dat' | Should -Exist
    }

    It 'keeps a version when an IDE is started while asking' {
        $script:started = $false
        Mock Read-ResikConfirmation { $script:started = $true; $true }
        Mock Get-ResikJetBrainsRunningIde { if ($script:started) { 'rider64' } }

        $result = Invoke-ResikTargetCleanup -Target (New-ResikJetBrainsLeftoverTarget) -CanPrompt $true

        $result.Status | Should -BeExactly 'Skipped'
        $result.Message | Should -BeLike '*PyCharmEdu2021.3 (an IDE was started)*'
        Join-Path $script:system 'PyCharmEdu2021.3\index\stubs.dat' | Should -Exist
    }

    It 'reports a version it could not fully delete' {
        $locked = Join-Path $script:system 'PyCharmEdu2021.3\index\stubs.dat'
        $stream = [System.IO.File]::Open($locked, 'Open', 'Read', 'None')
        try {
            $result = Invoke-ResikTargetCleanup -Target (New-ResikJetBrainsLeftoverTarget) -CanPrompt $true
        }
        finally {
            $stream.Dispose()
        }

        $result.Status | Should -BeExactly 'PartialSuccess'
        $result.Message | Should -BeLike '*Not fully deleted: PyCharmEdu2021.3 (1 item(s)*'
        Join-Path $script:config 'Rider2024.1' | Should -Not -Exist
    }
}

Describe 'Get-ResikJetBrainsRunningIde' {
    It 'recognizes IDE launchers but not the Toolbox app' {
        Mock Get-Process {
            @('pycharm64', 'idea64', 'jetbrains-toolbox', 'explorer', 'rider64', 'pycharm64') |
                ForEach-Object { [pscustomobject]@{ ProcessName = $_ } }
        }
        @(Get-ResikJetBrainsRunningIde) | Should -Be @('idea64', 'pycharm64', 'rider64')
    }
}
