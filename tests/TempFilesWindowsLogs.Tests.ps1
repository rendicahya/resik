BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')

    function New-TestAgedFile {
        # Writes a file and sets its creation and last-write times DaysOld
        # days back.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Writes only to TestDrive.')]
        param([string] $Path, [int] $Size = 100, [int] $DaysOld = 30)
        New-TestFile -Path $Path -Size $Size
        $time = (Get-Date).AddDays(-$DaysOld)
        [System.IO.File]::SetCreationTime($Path, $time)
        [System.IO.File]::SetLastWriteTime($Path, $time)
    }

    function Set-TestFolderAge {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Changes only TestDrive.')]
        param([string] $Path, [int] $DaysOld = 30)
        [System.IO.Directory]::SetCreationTime($Path, (Get-Date).AddDays(-$DaysOld))
    }
}

Describe 'Get-ResikAgedFile' {
    It 'finds only old files that match, without entering links' {
        $root = Join-Path $TestDrive ('aged-' + [guid]::NewGuid().ToString('N'))
        $elsewhere = Join-Path $TestDrive ('elsewhere-' + [guid]::NewGuid().ToString('N'))
        New-TestAgedFile -Path (Join-Path $root 'old.log') -Size 300
        New-TestAgedFile -Path (Join-Path $root 'sub\old.log') -Size 200
        New-TestAgedFile -Path (Join-Path $root 'old.txt') -Size 50
        New-TestAgedFile -Path (Join-Path $root 'new.log') -Size 70 -DaysOld 0
        New-TestAgedFile -Path (Join-Path $elsewhere 'old.log') -Size 9000
        New-Item -ItemType Junction -Path (Join-Path $root 'link') -Value $elsewhere | Out-Null

        $found = Get-ResikAgedFile -Path $root -Before (Get-Date).AddDays(-7) -Include '*.log' -Recurse
        $found.Bytes | Should -Be 500
        @($found.Files).Count | Should -Be 2

        (Get-ResikAgedFile -Path $root -Before (Get-Date).AddDays(-7) -Include '*.log').Bytes | Should -Be 300
    }

    It 'treats a recently created file as new even if its write time is old' {
        $root = Join-Path $TestDrive ('aged-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $root 'copied.bin') -Size 10
        [System.IO.File]::SetLastWriteTime((Join-Path $root 'copied.bin'), (Get-Date).AddDays(-30))
        (Get-ResikAgedFile -Path $root -Before (Get-Date).AddDays(-7)).Bytes | Should -Be 0
    }
}

Describe 'Remove-ResikEmptyFolder' {
    It 'removes old empty folders, deepest first, and keeps new ones and the root' {
        $root = Join-Path $TestDrive ('empty-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'a\b\c'), (Join-Path $root 'fresh'), (Join-Path $root 'full') | Out-Null
        New-TestFile -Path (Join-Path $root 'full\x') -Size 1
        foreach ($folder in 'a\b\c', 'a\b', 'a', 'full') { Set-TestFolderAge -Path (Join-Path $root $folder) }

        Remove-ResikEmptyFolder -Path $root -Before (Get-Date).AddDays(-7) -Confirm:$false | Should -Be 3
        Join-Path $root 'a' | Should -Not -Exist
        Join-Path $root 'fresh' | Should -Exist
        Join-Path $root 'full\x' | Should -Exist
        $root | Should -Exist
    }
}

Describe 'temp-files target' {
    BeforeEach {
        $script:base = Join-Path $TestDrive ('tmp-' + [guid]::NewGuid().ToString('N'))
        $script:temp = Join-Path $script:base 'Temp'
        $script:windowsTemp = Join-Path $script:base 'Windows\Temp'
        New-TestAgedFile -Path (Join-Path $script:temp 'old.tmp') -Size 1000
        New-TestAgedFile -Path (Join-Path $script:temp 'setup\old.cab') -Size 500
        New-TestAgedFile -Path (Join-Path $script:temp 'new.tmp') -Size 40 -DaysOld 1
        New-TestAgedFile -Path (Join-Path $script:temp 'mixed\new.dat') -Size 30 -DaysOld 0
        New-TestAgedFile -Path (Join-Path $script:temp 'mixed\old.dat') -Size 20
        New-TestAgedFile -Path (Join-Path $script:windowsTemp 'old.log') -Size 600
        Set-TestFolderAge -Path (Join-Path $script:temp 'setup')
        Set-TestFolderAge -Path (Join-Path $script:temp 'mixed')

        Mock Write-Host {}
        Mock Get-ResikUserTempPath { $script:temp }
        Mock Get-ResikWindowsTempPath { $script:windowsTemp }
        Mock Test-ResikAdministrator { $false }
    }

    It 'is Low risk and chosen by --all' {
        $target = New-ResikTempFileTarget
        $target.RiskLevel | Should -BeExactly 'Low'
        $target.ExplicitOnly | Should -BeFalse
    }

    It 'measures only files older than 7 days in the user temp folder' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikTempFileTarget)
        $result.EstimatedBytes | Should -Be 1520
        $result.Message | Should -BeLike '*needs administrator rights and is not included'
        Join-Path $script:temp 'old.tmp' | Should -Exist
    }

    It 'deletes old files and old empty folders and keeps new files' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikTempFileTarget)

        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 1520
        $result.Message | Should -BeExactly "Deleted 3 file(s) in the temp folders and 1 empty folder(s)"
        Join-Path $script:temp 'old.tmp' | Should -Not -Exist
        Join-Path $script:temp 'setup' | Should -Not -Exist
        Join-Path $script:temp 'new.tmp' | Should -Exist
        Join-Path $script:temp 'mixed\new.dat' | Should -Exist
        Join-Path $script:windowsTemp 'old.log' | Should -Exist
    }

    It 'includes %WINDIR%\Temp as administrator' {
        Mock Test-ResikAdministrator { $true }
        (Invoke-ResikTargetCleanup -Target (New-ResikTempFileTarget)).MeasuredBytes | Should -Be 2120
        Join-Path $script:windowsTemp 'old.log' | Should -Not -Exist
    }

    It 'does not follow a junction in the temp folder' {
        $elsewhere = Join-Path $TestDrive ('elsewhere-' + [guid]::NewGuid().ToString('N'))
        New-TestAgedFile -Path (Join-Path $elsewhere 'precious') -Size 9000
        New-Item -ItemType Junction -Path (Join-Path $script:temp 'link') -Value $elsewhere | Out-Null

        (Invoke-ResikTargetCleanup -Target (New-ResikTempFileTarget)).MeasuredBytes | Should -Be 1520
        Join-Path $elsewhere 'precious' | Should -Exist
        Join-Path $script:temp 'link' | Should -Exist
    }

    It 'reports a file in use and still deletes the others' {
        $stream = [System.IO.File]::Open((Join-Path $script:temp 'old.tmp'), 'Open', 'Read', 'None')
        try {
            $result = Invoke-ResikTargetCleanup -Target (New-ResikTempFileTarget)
        }
        finally {
            $stream.Dispose()
        }
        $result.Status | Should -BeExactly 'PartialSuccess'
        $result.MeasuredBytes | Should -Be 520
        $result.Message | Should -BeLike '*1 file(s) could not be deleted*'
    }

    It 'works although TEMP is a protected location' {
        Mock Get-ResikProtectedPath { $script:temp; Join-Path $script:base 'Windows' }
        (Invoke-ResikTargetCleanup -Target (New-ResikTempFileTarget)).Status | Should -BeExactly 'Success'
    }

    It 'refuses a temp folder not named Temp or Tmp' {
        $script:temp = Join-Path $script:base 'Documents'
        New-TestAgedFile -Path (Join-Path $script:temp 'thesis.docx') -Size 10
        (Invoke-ResikTargetCleanup -Target (New-ResikTempFileTarget)).Message | Should -BeLike '*is not a folder named Temp or Tmp*'
        Join-Path $script:temp 'thesis.docx' | Should -Exist
    }

    It 'still refuses another protected location' {
        $script:temp = Join-Path $script:base 'Temp'
        Mock Get-ResikProtectedPath { Join-Path $script:base 'Temp\inner' }
        New-Item -ItemType Directory -Force -Path (Join-Path $script:temp 'inner') | Out-Null
        (Invoke-ResikTargetCleanup -Target (New-ResikTempFileTarget)).Message | Should -BeLike '*contains the protected location*'
        Join-Path $script:temp 'old.tmp' | Should -Exist
    }
}

Describe 'windows-logs target' {
    BeforeEach {
        $script:logs = Join-Path $TestDrive ('logs-' + [guid]::NewGuid().ToString('N'))
        New-TestAgedFile -Path (Join-Path $script:logs 'CBS\CbsPersist_20261110160005.log') -Size 3000 -DaysOld 7
        New-TestAgedFile -Path (Join-Path $script:logs 'CBS\CbsPersist_20261001000000.cab') -Size 2000 -DaysOld 40
        New-TestAgedFile -Path (Join-Path $script:logs 'CBS\CbsPersist_20261117000000.log') -Size 111 -DaysOld 0
        New-TestAgedFile -Path (Join-Path $script:logs 'CBS\CBS.log') -Size 222 -DaysOld 0
        New-TestAgedFile -Path (Join-Path $script:logs 'CBS\FilterList.log') -Size 5 -DaysOld 30
        New-TestAgedFile -Path (Join-Path $script:logs 'DISM\dism.log.bak') -Size 400 -DaysOld 30
        New-TestAgedFile -Path (Join-Path $script:logs 'DISM\dism.log') -Size 333 -DaysOld 0
        New-TestAgedFile -Path (Join-Path $script:logs 'WindowsUpdate\WindowsUpdate.20261001.etl') -Size 600 -DaysOld 30
        New-TestAgedFile -Path (Join-Path $script:logs 'MeasuredBoot\0000000001-0000000000.log') -Size 777 -DaysOld 30
        Mock Write-Host {}
        Mock Get-ResikWindowsLogRoot { $script:logs }
        Mock Test-ResikAdministrator { $true }
    }

    It 'is report-only without administrator rights' {
        Mock Test-ResikAdministrator { $false }
        $target = New-ResikWindowsLogTarget
        $target.Clean | Should -BeNullOrEmpty
        $result = Invoke-ResikTargetAnalysis -Target $target
        $result.EstimatedBytes | Should -Be 6000
        $result.Message | Should -BeLike '*Needs administrator rights*'
    }

    It 'deletes rotated CBS logs and old DISM and Windows Update logs only' {
        $result = Invoke-ResikTargetCleanup -Target (New-ResikWindowsLogTarget)

        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 6000
        foreach ($gone in 'CBS\CbsPersist_20261110160005.log', 'CBS\CbsPersist_20261001000000.cab',
            'DISM\dism.log.bak', 'WindowsUpdate\WindowsUpdate.20261001.etl') {
            Join-Path $script:logs $gone | Should -Not -Exist
        }
        foreach ($kept in 'CBS\CbsPersist_20261117000000.log', 'CBS\CBS.log', 'CBS\FilterList.log', 'DISM\dism.log',
            'MeasuredBoot\0000000001-0000000000.log') {
            Join-Path $script:logs $kept | Should -Exist
        }
    }

    It 'checks administrator rights again during cleanup' {
        $target = New-ResikWindowsLogTarget
        Mock Test-ResikAdministrator { $false }
        (Invoke-ResikTargetCleanup -Target $target).Status | Should -BeExactly 'Skipped'
        Join-Path $script:logs 'CBS\CbsPersist_20261001000000.cab' | Should -Exist
    }
}
