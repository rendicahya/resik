BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'Chromium browser targets' {
    BeforeEach {
        $base = Join-Path $TestDrive ('chromium-' + [guid]::NewGuid().ToString('N'))
        $script:local = Join-Path $base 'Local'
        $script:roaming = Join-Path $base 'Roaming'
        $script:userData = Join-Path $script:local 'BraveSoftware\Brave-Browser\User Data'
        # Two profiles; "Not a profile" has no Preferences file.
        New-TestFile -Path (Join-Path $script:userData 'Default\Preferences') -Size 10
        New-TestFile -Path (Join-Path $script:userData 'Default\Cache\Cache_Data\data_1') -Size 1000
        New-TestFile -Path (Join-Path $script:userData 'Default\Code Cache\js\index') -Size 200
        New-TestFile -Path (Join-Path $script:userData 'Default\GPUCache\data_0') -Size 30
        New-TestFile -Path (Join-Path $script:userData 'Default\Service Worker\CacheStorage\x') -Size 70
        New-TestFile -Path (Join-Path $script:userData 'Default\History') -Size 50
        New-TestFile -Path (Join-Path $script:userData 'Default\Network\Cookies') -Size 60
        New-TestFile -Path (Join-Path $script:userData 'Default\IndexedDB\db') -Size 80
        New-TestFile -Path (Join-Path $script:userData 'Profile 1\Preferences') -Size 10
        New-TestFile -Path (Join-Path $script:userData 'Profile 1\Cache\Cache_Data\data_2') -Size 500
        New-TestFile -Path (Join-Path $script:userData 'Not a profile\Cache\x') -Size 4000
        New-TestFile -Path (Join-Path $script:userData 'GrShaderCache\data_0') -Size 400
        New-TestFile -Path (Join-Path $script:userData 'Local State') -Size 20

        Mock Write-Host {}
        Mock Get-ResikLocalAppDataPath { $script:local }
        Mock Get-ResikRoamingAppDataPath { $script:roaming }
        $script:open = $false
        Mock Test-ResikAppRunning { $script:open }
        Mock Stop-ResikAppProcess { $script:open = $false }
        Mock Read-ResikConfirmation { $true }
    }

    It 'registers four parts per browser, with service workers Medium and explicit-only' {
        $catalog = @(Get-ResikTargetCatalog)
        foreach ($browser in 'chrome', 'brave', 'comet', 'vivaldi') {
            foreach ($part in 'cache', 'code-cache', 'gpu-cache') {
                $target = $catalog | Where-Object Id -eq "$browser-$part"
                $target.RiskLevel | Should -BeExactly 'Low'
                $target.ExplicitOnly | Should -BeFalse
                $target.Category | Should -BeExactly 'Apps'
            }
            $workers = $catalog | Where-Object Id -eq "$browser-service-workers"
            $workers.RiskLevel | Should -BeExactly 'Medium'
            $workers.ExplicitOnly | Should -BeTrue
        }
    }

    It 'measures each part in every real profile' -ForEach @(
        @{ Part = 'cache'; Bytes = 1500 }
        @{ Part = 'code-cache'; Bytes = 200 }
        @{ Part = 'gpu-cache'; Bytes = 430 }
        @{ Part = 'service-workers'; Bytes = 70 }
    ) {
        (Invoke-ResikTargetAnalysis -Target (New-ResikChromiumTarget -SpecId 'brave' -PartId $Part)).EstimatedBytes | Should -Be $Bytes
    }

    It 'is not detected without browser data' {
        (Invoke-ResikTargetAnalysis -Target (New-ResikChromiumTarget -SpecId 'comet' -PartId 'cache')).Message | Should -BeLike 'Not detected: *'
    }

    It 'empties only the chosen part and keeps everything else' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikChromiumTarget -SpecId 'brave' -PartId 'cache') -CanPrompt $true

        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 1500
        Join-Path $script:userData 'Default\Cache' | Should -Exist
        Join-Path $script:userData 'Default\Cache\Cache_Data' | Should -Not -Exist
        Join-Path $script:userData 'Profile 1\Cache\Cache_Data\data_2' | Should -Not -Exist
        foreach ($kept in 'Default\Code Cache\js\index', 'Default\GPUCache\data_0', 'Default\Service Worker\CacheStorage\x',
            'Default\History', 'Default\Network\Cookies', 'Default\IndexedDB\db', 'Not a profile\Cache\x', 'GrShaderCache\data_0') {
            Join-Path $script:userData $kept | Should -Exist
        }
    }

    It 'does not follow a cache folder that is a junction' {
        $elsewhere = Join-Path $TestDrive ('elsewhere-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $elsewhere 'precious') -Size 9000
        New-Item -ItemType Junction -Path (Join-Path $script:userData 'Default\DawnCache') -Value $elsewhere | Out-Null

        (Invoke-ResikTargetCleanup -Target (New-ResikChromiumTarget -SpecId 'brave' -PartId 'gpu-cache') -CanPrompt $true).MeasuredBytes | Should -Be 430
        Join-Path $elsewhere 'precious' | Should -Exist
    }

    It 'asks to close the running browser, then cleans' {
        $script:open = $true
        $result = Invoke-ResikTargetCleanup -Target (New-ResikChromiumTarget -SpecId 'brave' -PartId 'code-cache') -CanPrompt $true

        $result.Status | Should -BeExactly 'Success'
        Should -Invoke Read-ResikConfirmation -Times 1 -Exactly -ParameterFilter { $Prompt -like 'Brave is running, so Brave compiled script cache cannot be deleted.*' }
        Should -Invoke Stop-ResikAppProcess -Times 1 -Exactly -ParameterFilter { $App.ProcessName -contains 'brave' }
    }

    It 'removes nothing when closing the browser is declined' {
        $script:open = $true
        Mock Read-ResikConfirmation { $false }
        $result = Invoke-ResikTargetCleanup -Target (New-ResikChromiumTarget -SpecId 'brave' -PartId 'cache') -CanPrompt $true

        $result.Status | Should -BeExactly 'Skipped'
        Join-Path $script:userData 'Default\Cache\Cache_Data\data_1' | Should -Exist
    }

    It 'notes a running browser in the analysis' {
        $script:open = $true
        (Invoke-ResikTargetAnalysis -Target (New-ResikChromiumTarget -SpecId 'brave' -PartId 'cache')).Message |
            Should -BeLike '*. Brave is running; Resik will ask to close it before cleaning'
    }

    It 'matches Chrome only by its own install folders, and the Claude desktop app not by the CLI' {
        $chrome = (Get-ResikChromiumSpec -Id 'chrome').App
        'C:\Users\u\AppData\Local\ms-playwright\chromium-1\chrome-win64\chrome.exe' -like $chrome.PathLike[0] | Should -BeFalse
        'C:\Program Files\Google\Chrome\Application\chrome.exe' -like $chrome.PathLike[0] | Should -BeTrue
        $claude = (Get-ResikChromiumSpec -Id 'claude-desktop').App
        @($claude.PathLike | Where-Object { 'C:\Users\u\scoop\apps\claude-code\current\claude.exe' -like $_ }).Count | Should -Be 0
        @($claude.PathLike | Where-Object { 'C:\Program Files\WindowsApps\Claude_1.0.0.0_x64__abc\app\claude.exe' -like $_ }).Count | Should -Be 1
    }
}

Describe 'Chromium app targets' {
    BeforeEach {
        $base = Join-Path $TestDrive ('electron-' + [guid]::NewGuid().ToString('N'))
        $script:local = Join-Path $base 'Local'
        $script:roaming = Join-Path $base 'Roaming'
        $script:code = Join-Path $script:roaming 'Code'
        New-TestFile -Path (Join-Path $script:code 'Cache\Cache_Data\f') -Size 100
        New-TestFile -Path (Join-Path $script:code 'Code Cache\js\g') -Size 20
        New-TestFile -Path (Join-Path $script:code 'GPUCache\h') -Size 3
        New-TestFile -Path (Join-Path $script:code 'CachedData\abc\i') -Size 400
        New-TestFile -Path (Join-Path $script:code 'CachedExtensionVSIXs\ext.vsix') -Size 5000
        New-TestFile -Path (Join-Path $script:code 'User\settings.json') -Size 7
        New-TestFile -Path (Join-Path $script:code 'Service Worker\x') -Size 9

        Mock Write-Host {}
        Mock Get-ResikLocalAppDataPath { $script:local }
        Mock Get-ResikRoamingAppDataPath { $script:roaming }
        Mock Test-ResikAppRunning { $false }
    }

    It 'registers one Low target per app' {
        $catalog = @(Get-ResikTargetCatalog)
        foreach ($id in 'claude-desktop-cache', 'clickup-cache', 'vscode-cache', 'play-games-cache') {
            ($catalog | Where-Object Id -eq $id).RiskLevel | Should -BeExactly 'Low'
        }
    }

    It 'empties the caches and VS Code''s extra folders, keeping settings and site data' {
        $target = New-ResikChromiumTarget -SpecId 'vscode'
        (Invoke-ResikTargetAnalysis -Target $target).EstimatedBytes | Should -Be 5523

        $result = Invoke-ResikTargetCleanup -Target $target -CanPrompt $true
        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 5523
        Join-Path $script:code 'CachedExtensionVSIXs\ext.vsix' | Should -Not -Exist
        Join-Path $script:code 'User\settings.json' | Should -Exist
        Join-Path $script:code 'Service Worker\x' | Should -Exist
    }
}

Describe 'other app cache targets' {
    BeforeEach {
        $base = Join-Path $TestDrive ('apps-' + [guid]::NewGuid().ToString('N'))
        $script:local = Join-Path $base 'Local'
        Mock Write-Host {}
        Mock Get-ResikLocalAppDataPath { $script:local }
        Mock Test-ResikAppRunning { $false }
    }

    It 'zotero-cache empties cache2 and startupCache only' {
        $profileFolder = Join-Path $script:local 'Zotero\Zotero\Profiles\abc.default'
        New-TestFile -Path (Join-Path $profileFolder 'cache2\entries\e') -Size 300
        New-TestFile -Path (Join-Path $profileFolder 'startupCache\s') -Size 20
        New-TestFile -Path (Join-Path $profileFolder 'safebrowsing\x') -Size 5

        $result = Invoke-ResikTargetCleanup -Target (New-ResikZoteroTarget) -CanPrompt $true
        $result.MeasuredBytes | Should -Be 320
        Join-Path $profileFolder 'safebrowsing\x' | Should -Exist
    }

    It 'vivaldi-cache finds Vivaldi''s profiles in its User Data folder' {
        $userData = Join-Path $script:local 'Vivaldi\User Data'
        New-TestFile -Path (Join-Path $userData 'Default\Preferences') -Size 1
        New-TestFile -Path (Join-Path $userData 'Default\Cache\Cache_Data\d') -Size 600
        New-TestFile -Path (Join-Path $userData 'Default\History') -Size 9

        $target = New-ResikChromiumTarget -SpecId 'vivaldi' -PartId 'cache'
        (Invoke-ResikTargetAnalysis -Target $target).EstimatedBytes | Should -Be 600
        (Invoke-ResikTargetCleanup -Target $target -CanPrompt $true).MeasuredBytes | Should -Be 600
        Join-Path $userData 'Default\History' | Should -Exist
    }

    It 'firefox-cache empties cache2 and startupCache in every local profile only' {
        $profileRoot = Join-Path $script:local 'Mozilla\Firefox\Profiles'
        New-TestFile -Path (Join-Path $profileRoot 'a.default-release\cache2\entries\e') -Size 700
        New-TestFile -Path (Join-Path $profileRoot 'a.default-release\startupCache\s') -Size 40
        New-TestFile -Path (Join-Path $profileRoot 'b.dev\cache2\entries\f') -Size 60
        New-TestFile -Path (Join-Path $profileRoot 'a.default-release\safebrowsing\x') -Size 5
        New-TestFile -Path (Join-Path $profileRoot 'a.default-release\thumbnails\t') -Size 6

        $target = New-ResikFirefoxTarget
        $target.Category | Should -BeExactly 'Apps'
        (Invoke-ResikTargetAnalysis -Target $target).EstimatedBytes | Should -Be 800
        $result = Invoke-ResikTargetCleanup -Target $target -CanPrompt $true
        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 800
        Join-Path $profileRoot 'a.default-release\cache2' | Should -Exist
        Join-Path $profileRoot 'a.default-release\safebrowsing\x' | Should -Exist
        Join-Path $profileRoot 'a.default-release\thumbnails\t' | Should -Exist
    }

    It 'firefox-cache is not detected without Firefox profiles' {
        (Invoke-ResikTargetAnalysis -Target (New-ResikFirefoxTarget)).Message | Should -BeLike 'Not detected: *'
    }

    It 'matches Firefox by its install folders, never Playwright''s Firefox' {
        $app = Get-ResikFirefoxApp
        foreach ($case in @(
                [pscustomobject]@{ Path = 'C:\Users\u\AppData\Local\ms-playwright\firefox-1466\firefox\firefox.exe'; Count = 0 },
                [pscustomobject]@{ Path = 'C:\Program Files\Mozilla Firefox\firefox.exe'; Count = 1 },
                [pscustomobject]@{ Path = 'C:\Users\u\scoop\apps\firefox\current\firefox.exe'; Count = 1 })) {
            @($app.PathLike | Where-Object { $case.Path -like $_ }).Count | Should -Be $case.Count
        }
    }

    It 'nvidia-shaders empties the driver caches in Local and LocalLow' {
        New-TestFile -Path (Join-Path $script:local 'NVIDIA\DXCache\a') -Size 100
        New-TestFile -Path (Join-Path $script:local 'NVIDIA\Other\keep') -Size 1
        New-TestFile -Path (Join-Path $base 'LocalLow\NVIDIA\PerDriverVersion\DXCache\b') -Size 50

        $target = New-ResikNvidiaShaderTarget
        (Invoke-ResikTargetAnalysis -Target $target).EstimatedBytes | Should -Be 150
        (Invoke-ResikTargetCleanup -Target $target).MeasuredBytes | Should -Be 150
        Join-Path $script:local 'NVIDIA\Other\keep' | Should -Exist
        Join-Path $script:local 'NVIDIA\DXCache' | Should -Exist
    }

    It 'netbeans-cache deletes the version folders and asks to close a running NetBeans' {
        New-TestFile -Path (Join-Path $script:local 'NetBeans\Cache\28\index\x') -Size 70
        New-TestFile -Path (Join-Path $script:local 'NetBeans\Cache\29\y') -Size 30
        $script:open = $true
        Mock Test-ResikAppRunning { $script:open }
        Mock Stop-ResikAppProcess { $script:open = $false }
        Mock Read-ResikConfirmation { $true }

        $result = Invoke-ResikTargetCleanup -Target (New-ResikNetBeansTarget) -CanPrompt $true
        $result.MeasuredBytes | Should -Be 100
        Join-Path $script:local 'NetBeans\Cache\28' | Should -Not -Exist
        Join-Path $script:local 'NetBeans\Cache' | Should -Exist
        Should -Invoke Stop-ResikAppProcess -Times 1 -Exactly -ParameterFilter { $App.IncludeChildren }
    }
}

Describe 'node-gyp target' {
    BeforeEach {
        $script:local = Join-Path $TestDrive ('gyp-' + [guid]::NewGuid().ToString('N'))
        $script:cache = Join-Path $script:local 'node-gyp\Cache'
        New-TestFile -Path (Join-Path $script:cache '26.1.0\include\node\node.h') -Size 600
        New-TestFile -Path (Join-Path $script:cache '26.1.0\installVersion') -Size 2
        New-TestFile -Path (Join-Path $script:cache 'not-a-version\keep') -Size 9
        Mock Write-Host {}
        Mock Get-ResikLocalAppDataPath { $script:local }
        $script:savedDevDir = [Environment]::GetEnvironmentVariable('npm_config_devdir')
        [Environment]::SetEnvironmentVariable('npm_config_devdir', $null)
    }

    AfterEach {
        [Environment]::SetEnvironmentVariable('npm_config_devdir', $script:savedDevDir)
    }

    It 'removes the version folders, like node-gyp remove, and keeps other folders' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikNodeGypTarget)

        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 602
        Join-Path $script:cache '26.1.0' | Should -Not -Exist
        Join-Path $script:cache 'not-a-version\keep' | Should -Exist
    }

    It 'uses npm_config_devdir when it is set' {
        $other = Join-Path $TestDrive ('devdir-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $other '20.0.0\installVersion') -Size 4
        [Environment]::SetEnvironmentVariable('npm_config_devdir', $other)

        (Invoke-ResikTargetAnalysis -Target (New-ResikNodeGypTarget)).EstimatedBytes | Should -Be 4
    }
}
