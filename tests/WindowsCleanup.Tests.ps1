BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')

    function New-TestFolder {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Writes only to TestDrive.')]
        param()
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $path | Out-Null
        $path
    }
}

Describe 'Remove-ResikDirectoryContent' {
    It 'deletes only matching items and keeps the folder' {
        $folder = New-TestFolder
        New-TestFile -Path (Join-Path $folder 'thumbcache_96.db')
        New-TestFile -Path (Join-Path $folder 'iconcache_32.db')

        $result = Remove-ResikDirectoryContent -Path $folder -Filter 'thumbcache_*.db' -Confirm:$false

        @($result.Errors).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $folder 'thumbcache_96.db') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $folder 'iconcache_32.db') | Should -BeTrue
        Test-Path -LiteralPath $folder | Should -BeTrue
    }

    It 'removes a junction without deleting what it points to' {
        $folder = New-TestFolder
        $outside = New-TestFolder
        New-TestFile -Path (Join-Path $outside 'keep.txt')
        New-TestFile -Path (Join-Path $folder 'sub\a.bin')
        New-Item -ItemType Junction -Path (Join-Path $folder 'link') -Target $outside | Out-Null

        Remove-ResikDirectoryContent -Path $folder -Confirm:$false | Out-Null

        @(Get-ChildItem -LiteralPath $folder -Force).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $outside 'keep.txt') | Should -BeTrue
    }

    It 'reports a file in use and deletes the rest' {
        $folder = New-TestFolder
        New-TestFile -Path (Join-Path $folder 'a.bin')
        New-TestFile -Path (Join-Path $folder 'b.bin')
        $stream = [System.IO.File]::Open((Join-Path $folder 'a.bin'), 'Open', 'Read', 'None')
        try {
            $result = Remove-ResikDirectoryContent -Path $folder -Confirm:$false
        }
        finally {
            $stream.Dispose()
        }

        @($result.Errors).Count | Should -Be 1
        $result.Errors[0] | Should -BeLike "*a.bin: *"
        Test-Path -LiteralPath (Join-Path $folder 'b.bin') | Should -BeFalse
    }

    It 'refuses a protected folder' {
        { Remove-ResikDirectoryContent -Path $env:LOCALAPPDATA -Confirm:$false } | Should -Throw '*protected location*'
    }
}

Describe 'directx-shaders target' {
    BeforeEach {
        $script:appData = New-TestFolder
        $script:cache = Join-Path $script:appData 'D3DSCache'
        New-TestFile -Path (Join-Path $script:cache 'game1\shaders.idx') -Size 1000
        New-TestFile -Path (Join-Path $script:cache 'game2\shaders.val') -Size 500
        Mock Get-ResikLocalAppDataPath { $script:appData }
        Mock Write-Host {}
    }

    It 'is not detected without a D3DSCache folder' {
        Remove-Item -LiteralPath $script:cache -Recurse -Force
        (Invoke-ResikTargetAnalysis -Target (New-ResikShaderCacheTarget)).Message | Should -BeLike 'Not detected: *'
    }

    It 'measures the cache without changing it' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikShaderCacheTarget)

        $result.Status | Should -BeExactly 'AnalysisOnly'
        $result.EstimatedBytes | Should -Be 1500
        Test-Path -LiteralPath (Join-Path $script:cache 'game1\shaders.idx') | Should -BeTrue
    }

    It 'empties the cache and measures what was removed' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikShaderCacheTarget)

        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 1500
        @(Get-ChildItem -LiteralPath $script:cache -Force).Count | Should -Be 0
        Test-Path -LiteralPath $script:cache | Should -BeTrue
    }

    It 'reports partial success when a shader file is in use' {
        $stream = [System.IO.File]::Open((Join-Path $script:cache 'game1\shaders.idx'), 'Open', 'Read', 'None')
        try {
            $result = Invoke-ResikTargetCleanup -Target (New-ResikShaderCacheTarget)
        }
        finally {
            $stream.Dispose()
        }

        $result.Status | Should -BeExactly 'PartialSuccess'
        $result.MeasuredBytes | Should -Be 500
        $result.Message | Should -BeLike '*could not be deleted*Close running games*'
    }
}

Describe 'thumbnails target' {
    BeforeEach {
        $script:appData = New-TestFolder
        $script:explorer = Join-Path $script:appData 'Microsoft\Windows\Explorer'
        New-TestFile -Path (Join-Path $script:explorer 'thumbcache_256.db') -Size 800
        New-TestFile -Path (Join-Path $script:explorer 'thumbcache_idx.db') -Size 200
        New-TestFile -Path (Join-Path $script:explorer 'iconcache_32.db') -Size 400
        Mock Get-ResikLocalAppDataPath { $script:appData }
        Mock Write-Host {}
    }

    It 'counts only thumbcache files' {
        (Invoke-ResikTargetAnalysis -Target (New-ResikThumbnailCacheTarget)).EstimatedBytes | Should -Be 1000
    }

    It 'deletes the thumbcache files and keeps the icon cache' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikThumbnailCacheTarget)

        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 1000
        @(Get-ChildItem -LiteralPath $script:explorer | ForEach-Object Name) | Should -Be @('iconcache_32.db')
    }

    It 'skips when there are no thumbcache files' {
        Remove-Item -Path (Join-Path $script:explorer 'thumbcache_*.db')
        (Invoke-ResikTargetCleanup -Target (New-ResikThumbnailCacheTarget)).Status | Should -BeExactly 'Skipped'
    }
}

Describe 'recycle-bin target' {
    BeforeEach {
        $script:bin = New-TestFolder
        New-TestFile -Path (Join-Path $script:bin '$IABC123.txt') -Size 100
        New-TestFile -Path (Join-Path $script:bin '$RABC123.txt') -Size 900
        New-TestFile -Path (Join-Path $script:bin '$RDEF456\inner.bin') -Size 1000
        New-TestFile -Path (Join-Path $script:bin 'desktop.ini') -Size 50
        $script:cleared = 0
        Mock Get-ResikRecycleBinFolder { $script:bin }
        Mock Clear-ResikRecycleBin {
            $script:cleared++
            Get-ChildItem -LiteralPath $script:bin -Filter '$*' -Force | Remove-Item -Recurse -Force
        }
        Mock Write-Host {}
    }

    It 'is never chosen by --all' {
        $target = New-ResikRecycleBinTarget
        $target.ExplicitOnly | Should -BeTrue
        $target.RiskLevel | Should -BeExactly 'High'
        @(Resolve-ResikSelection -Targets @($target) -All).Count | Should -Be 0
    }

    It 'measures deleted items but not desktop.ini, without emptying the bin' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikRecycleBinTarget)

        $result.EstimatedBytes | Should -Be 2000
        $script:cleared | Should -Be 0
    }

    It 'empties the bin and measures the result' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikRecycleBinTarget)

        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 2000
        $script:cleared | Should -Be 1
    }

    It 'does nothing when the bin is already empty' {
        Get-ChildItem -LiteralPath $script:bin -Filter '$*' -Force | Remove-Item -Recurse -Force

        (Invoke-ResikTargetCleanup -Target (New-ResikRecycleBinTarget)).Status | Should -BeExactly 'Skipped'
        $script:cleared | Should -Be 0
    }

    It 'reports a failure when nothing was removed' {
        Mock Clear-ResikRecycleBin { throw 'Access is denied.' }

        $result = Invoke-ResikTargetCleanup -Target (New-ResikRecycleBinTarget)

        $result.Status | Should -BeExactly 'Failed'
        $result.Message | Should -BeExactly '3 file(s) are still in the Recycle Bin: Access is denied.'
    }
}

Describe 'windows-update target' {
    BeforeEach {
        $script:dismArgs = $null
        Mock Write-Host {}
        Mock Get-ResikDismPath { Join-Path $TestDrive 'Dism.exe' }
        New-TestFile -Path (Join-Path $TestDrive 'Dism.exe')
        Mock Invoke-ResikNativeCommand {
            $script:dismArgs = $ArgumentList
            New-TestRunResult
        }
    }

    It 'is report-only without administrator rights' {
        Mock Test-ResikAdministrator { $false }
        $target = New-ResikWindowsUpdateTarget

        $target.Clean | Should -BeNullOrEmpty
        $result = Invoke-ResikTargetAnalysis -Target $target
        $result.Status | Should -BeExactly 'AnalysisOnly'
        $result.Message | Should -BeLike 'Needs administrator rights*'
        (Get-ResikAnalysisGroup -Result $result -Target $target) | Should -BeExactly 'ReportOnly'
    }

    It 'runs no DISM command during analysis' {
        Mock Test-ResikAdministrator { $true }
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikWindowsUpdateTarget)

        $result.EstimatedBytes | Should -BeNullOrEmpty
        $script:dismArgs | Should -BeNullOrEmpty
    }

    It 'runs DISM component cleanup without /ResetBase when elevated' {
        Mock Test-ResikAdministrator { $true }

        $result = Invoke-ResikTargetCleanup -Target (New-ResikWindowsUpdateTarget)

        $result.Status | Should -BeExactly 'Success'
        $script:dismArgs | Should -Be @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    }

    It 'skips cleanup if administrator rights are gone' {
        Mock Test-ResikAdministrator { $true }
        $target = New-ResikWindowsUpdateTarget
        Mock Test-ResikAdministrator { $false }

        (Invoke-ResikTargetCleanup -Target $target).Status | Should -BeExactly 'Skipped'
        $script:dismArgs | Should -BeNullOrEmpty
    }
}
