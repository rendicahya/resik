BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'Test-ResikRealFolder' {
    It 'accepts a folder inside the base and rejects one outside it' {
        $base = Join-Path $TestDrive ('real-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $base 'a\b') | Out-Null
        Test-ResikRealFolder -Path (Join-Path $base 'a\b') -Base $base | Should -BeTrue
        Test-ResikRealFolder -Path $TestDrive -Base $base | Should -BeFalse
        Test-ResikRealFolder -Path (Join-Path $base 'missing') -Base $base | Should -BeFalse
    }

    It 'rejects a folder reached through a junction' {
        $base = Join-Path $TestDrive ('real-' + [guid]::NewGuid().ToString('N'))
        $elsewhere = Join-Path $TestDrive ('elsewhere-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $elsewhere 'inner'), $base | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $base 'link') -Value $elsewhere | Out-Null
        Test-ResikRealFolder -Path (Join-Path $base 'link\inner') -Base $base | Should -BeFalse
    }
}

Describe 'edge targets' {
    BeforeEach {
        $script:local = Join-Path $TestDrive ('local-' + [guid]::NewGuid().ToString('N'))
        $script:userData = Join-Path $script:local 'Microsoft\Edge\User Data'
        # Two profiles; "Not a profile" has no Preferences file.
        New-TestFile -Path (Join-Path $script:userData 'Default\Preferences') -Size 10
        New-TestFile -Path (Join-Path $script:userData 'Default\Cache\Cache_Data\data_1') -Size 1000
        New-TestFile -Path (Join-Path $script:userData 'Default\Code Cache\js\index') -Size 200
        New-TestFile -Path (Join-Path $script:userData 'Default\History') -Size 50
        New-TestFile -Path (Join-Path $script:userData 'Default\Network\Cookies') -Size 60
        New-TestFile -Path (Join-Path $script:userData 'Default\Service Worker\CacheStorage\x') -Size 70
        New-TestFile -Path (Join-Path $script:userData 'Profile 1\Preferences') -Size 10
        New-TestFile -Path (Join-Path $script:userData 'Profile 1\GPUCache\data_0') -Size 300
        New-TestFile -Path (Join-Path $script:userData 'Not a profile\Cache\x') -Size 4000
        New-TestFile -Path (Join-Path $script:userData 'GrShaderCache\data_0') -Size 400
        New-TestFile -Path (Join-Path $script:userData 'Local State') -Size 20

        Mock Write-Host {}
        Mock Get-ResikLocalAppDataPath { $script:local }
        # Edge runs while $script:edgeOpen is true; stopping it closes it.
        $script:edgeOpen = $false
        Mock Test-ResikAppRunning { $script:edgeOpen }
        Mock Stop-ResikAppProcess { $script:edgeOpen = $false }
        Mock Read-ResikConfirmation { $true }
    }

    It 'registers edge-profile as High risk and explicit-only, and the cache parts as Edge targets' {
        $catalog = @(Get-ResikTargetCatalog)
        $reset = $catalog | Where-Object Id -eq 'edge-profile'
        $reset.RiskLevel | Should -BeExactly 'High'
        $reset.ExplicitOnly | Should -BeTrue
        foreach ($id in 'edge-cache', 'edge-code-cache', 'edge-gpu-cache', 'edge-service-workers') {
            ($catalog | Where-Object Id -eq $id).Category | Should -BeExactly 'Windows'
        }
    }

    It 'is not detected without Edge data' {
        Mock Get-ResikLocalAppDataPath { Join-Path $TestDrive 'no-edge' }
        (Invoke-ResikTargetAnalysis -Target (New-ResikEdgeProfileTarget)).Message | Should -BeLike 'Not detected: *'
    }

    It 'says it will ask to close Edge while it runs' {
        $script:edgeOpen = $true
        (Invoke-ResikTargetAnalysis -Target (New-ResikEdgeProfileTarget)).Message | Should -BeLike '*Microsoft Edge is running; Resik will ask to close it before cleaning'
    }
    It 'deletes the whole User Data folder after confirmation' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikEdgeProfileTarget) -CanPrompt $true

        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 6120
        $script:userData | Should -Not -Exist
        Join-Path $script:local 'Microsoft\Edge' | Should -Exist
        Should -Invoke Read-ResikConfirmation -Times 1 -Exactly
    }

    It 'keeps the data when the question is declined' {
        Mock Read-ResikConfirmation { $false }
        (Invoke-ResikTargetCleanup -Target (New-ResikEdgeProfileTarget) -CanPrompt $true).Status | Should -BeExactly 'Skipped'
        Join-Path $script:userData 'Default\History' | Should -Exist
    }

    It 'does not ask after "accept all"' {
        (Invoke-ResikTargetCleanup -Target (New-ResikEdgeProfileTarget) -CanPrompt $true -AcceptAll $true).Status | Should -BeExactly 'Success'
        Should -Invoke Read-ResikConfirmation -Times 0 -Exactly
    }

    It 'removes nothing without a terminal' {
        (Invoke-ResikTargetCleanup -Target (New-ResikEdgeProfileTarget)).Status | Should -BeExactly 'Skipped'
        Join-Path $script:userData 'Default\History' | Should -Exist
        Should -Invoke Read-ResikConfirmation -Times 0 -Exactly
    }

    It 'asks to delete first, then to close Edge, and resets it' {
        $script:edgeOpen = $true
        $result = Invoke-ResikTargetCleanup -Target (New-ResikEdgeProfileTarget) -CanPrompt $true

        $result.Status | Should -BeExactly 'Success'
        $script:userData | Should -Not -Exist
        Should -Invoke Read-ResikConfirmation -Times 2 -Exactly
        Should -Invoke Stop-ResikAppProcess -Times 1 -Exactly
    }

    It 'does not close Edge when the reset is declined' {
        $script:edgeOpen = $true
        Mock Read-ResikConfirmation { $false }
        (Invoke-ResikTargetCleanup -Target (New-ResikEdgeProfileTarget) -CanPrompt $true).Message | Should -BeExactly 'You kept the Microsoft Edge data. Nothing was removed.'
        Should -Invoke Read-ResikConfirmation -Times 1 -Exactly
        Should -Invoke Stop-ResikAppProcess -Times 0 -Exactly
        Join-Path $script:userData 'Default\History' | Should -Exist
    }

    It 'asks to close Edge after "accept all" and keeps the data when declined' {
        $script:edgeOpen = $true
        Mock Read-ResikConfirmation { $false } -ParameterFilter { $Prompt -like 'Microsoft Edge is running*' }
        $result = Invoke-ResikTargetCleanup -Target (New-ResikEdgeProfileTarget) -CanPrompt $true -AcceptAll $true

        $result.Status | Should -BeExactly 'Skipped'
        $result.Message | Should -BeExactly 'You kept Microsoft Edge open. Nothing was removed.'
        Join-Path $script:userData 'Default\History' | Should -Exist
    }
}
Describe 'ie-cache target' {
    BeforeEach {
        $script:local = Join-Path $TestDrive ('local-' + [guid]::NewGuid().ToString('N'))
        $script:inet = Join-Path $script:local 'Microsoft\Windows\INetCache'
        New-TestFile -Path (Join-Path $script:inet 'IE\container.dat') -Size 0
        New-TestFile -Path (Join-Path $script:inet 'IE\8C7TYNAB\logo_1.png') -Size 500
        New-TestFile -Path (Join-Path $script:inet 'IE\CGEJFHU0\page_2.htm') -Size 300
        New-TestFile -Path (Join-Path $script:inet 'Low\IE\J1RZGTJA\x_1.js') -Size 200
        New-TestFile -Path (Join-Path $script:inet 'IE\notacache\keep') -Size 40
        New-TestFile -Path (Join-Path $script:inet 'Content.Word\~WRS0001.tmp') -Size 700
        New-TestFile -Path (Join-Path $script:inet 'Content.MSO\abc.png') -Size 800
        Mock Write-Host {}
        Mock Get-ResikLocalAppDataPath { $script:local }
    }

    It 'is Low risk' {
        (New-ResikInternetCacheTarget).RiskLevel | Should -BeExactly 'Low'
    }

    It 'is not detected without cache folders' {
        Mock Get-ResikLocalAppDataPath { Join-Path $TestDrive 'no-inetcache' }
        (Invoke-ResikTargetAnalysis -Target (New-ResikInternetCacheTarget)).Message | Should -BeLike 'Not detected: *'
    }

    It 'measures only the WinINet cache folders' {
        (Invoke-ResikTargetAnalysis -Target (New-ResikInternetCacheTarget)).EstimatedBytes | Should -Be 1000
    }

    It 'empties the cache folders and keeps container.dat and Office files' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikInternetCacheTarget)

        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 1000
        Join-Path $script:inet 'IE\8C7TYNAB' | Should -Exist
        Join-Path $script:inet 'IE\8C7TYNAB\logo_1.png' | Should -Not -Exist
        Join-Path $script:inet 'Low\IE\J1RZGTJA\x_1.js' | Should -Not -Exist
        foreach ($kept in 'IE\container.dat', 'IE\notacache\keep', 'Content.Word\~WRS0001.tmp', 'Content.MSO\abc.png') {
            Join-Path $script:inet $kept | Should -Exist
        }
    }
}
