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
        Mock Test-ResikEdgeRunning { $false }
        Mock Read-ResikConfirmation { $true }
    }

    It 'registers edge-cache as Low risk and edge-profile as High risk and explicit-only' {
        $catalog = @(Get-ResikTargetCatalog)
        $cache = $catalog | Where-Object Id -eq 'edge-cache'
        $reset = $catalog | Where-Object Id -eq 'edge-profile'
        $cache.RiskLevel | Should -BeExactly 'Low'
        $cache.ExplicitOnly | Should -BeFalse
        $reset.RiskLevel | Should -BeExactly 'High'
        $reset.ExplicitOnly | Should -BeTrue
    }

    It 'is not detected without Edge data' {
        Mock Get-ResikLocalAppDataPath { Join-Path $TestDrive 'no-edge' }
        (Invoke-ResikTargetAnalysis -Target (New-ResikEdgeCacheTarget)).Message | Should -BeLike 'Not detected: *'
        (Invoke-ResikTargetAnalysis -Target (New-ResikEdgeProfileTarget)).Message | Should -BeLike 'Not detected: *'
    }

    It 'measures only the cache folders of real profiles' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikEdgeCacheTarget)
        $result.EstimatedBytes | Should -Be 1900
        $result.Message | Should -BeLike '4 cache folder(s) in *'
        Join-Path $script:userData 'Default\Cache\Cache_Data\data_1' | Should -Exist
    }

    It 'says to close Edge while it runs' {
        Mock Test-ResikEdgeRunning { $true }
        (Invoke-ResikTargetAnalysis -Target (New-ResikEdgeCacheTarget)).Message | Should -BeLike '*Close Microsoft Edge before cleaning*'
    }

    It 'empties the cache folders and keeps everything else' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikEdgeCacheTarget)

        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 1900
        Join-Path $script:userData 'Default\Cache' | Should -Exist
        Join-Path $script:userData 'Default\Cache\Cache_Data' | Should -Not -Exist
        Join-Path $script:userData 'Default\Code Cache\js' | Should -Not -Exist
        Join-Path $script:userData 'Profile 1\GPUCache\data_0' | Should -Not -Exist
        Join-Path $script:userData 'GrShaderCache\data_0' | Should -Not -Exist
        foreach ($kept in 'Default\Preferences', 'Default\History', 'Default\Network\Cookies',
            'Default\Service Worker\CacheStorage\x', 'Not a profile\Cache\x', 'Local State') {
            Join-Path $script:userData $kept | Should -Exist
        }
    }

    It 'does not follow a cache folder that is a junction' {
        $elsewhere = Join-Path $TestDrive ('elsewhere-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $elsewhere 'precious') -Size 9000
        New-Item -ItemType Junction -Path (Join-Path $script:userData 'Default\DawnCache') -Value $elsewhere | Out-Null

        (Invoke-ResikTargetCleanup -Target (New-ResikEdgeCacheTarget)).MeasuredBytes | Should -Be 1900
        Join-Path $elsewhere 'precious' | Should -Exist
    }

    It 'refuses to clean the cache while Edge runs' {
        Mock Test-ResikEdgeRunning { $true }
        (Invoke-ResikTargetCleanup -Target (New-ResikEdgeCacheTarget)).Status | Should -BeExactly 'Skipped'
        Join-Path $script:userData 'Default\Cache\Cache_Data\data_1' | Should -Exist
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

    It 'refuses the reset while Edge runs, even after "accept all"' {
        Mock Test-ResikEdgeRunning { $true }
        (Invoke-ResikTargetCleanup -Target (New-ResikEdgeProfileTarget) -CanPrompt $true -AcceptAll $true).Status | Should -BeExactly 'Skipped'
        Join-Path $script:userData 'Default\History' | Should -Exist
    }

    It 'refuses the reset when Edge was started during the question' {
        $script:edgeChecks = 0
        Mock Test-ResikEdgeRunning { $script:edgeChecks++; $script:edgeChecks -gt 1 }
        $result = Invoke-ResikTargetCleanup -Target (New-ResikEdgeProfileTarget) -CanPrompt $true
        $result.Status | Should -BeExactly 'Skipped'
        $result.Message | Should -BeLike 'Microsoft Edge was started*'
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
