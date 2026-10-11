BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'Get-ResikPathSafetyIssue' {
    BeforeAll {
        $script:protected = @('C:\Windows', 'C:\Users\someone', 'C:\Users\someone\AppData\Local')
    }

    It 'rejects <Description>' -ForEach @(
        @{ Description = 'an empty path'; Path = '' }
        @{ Description = 'a relative path'; Path = 'cache' }
        @{ Description = 'a drive-relative path'; Path = 'C:cache' }
        @{ Description = 'a UNC path'; Path = '\\server\share\cache' }
        @{ Description = 'a device path'; Path = '\\?\C:\cache' }
        @{ Description = 'a wildcard'; Path = 'C:\cache\*' }
        @{ Description = 'an alternate data stream'; Path = 'C:\cache:stream' }
        @{ Description = 'a drive root'; Path = 'C:\' }
        @{ Description = 'a drive root written with ..'; Path = 'C:\cache\..' }
        @{ Description = 'a protected location'; Path = 'C:\Windows' }
        @{ Description = 'a protected location in another case'; Path = 'c:\users\SOMEONE\appdata\local\' }
        @{ Description = 'a folder that contains a protected location'; Path = 'C:\Users' }
        @{ Description = 'a parent reached with ..'; Path = 'C:\Users\someone\AppData\Local\uv\..\..' }
    ) {
        Get-ResikPathSafetyIssue -Path $Path -ProtectedPath $script:protected | Should -Not -BeNullOrEmpty
    }

    It 'accepts a folder inside a protected location' {
        Get-ResikPathSafetyIssue -Path 'C:\Users\someone\AppData\Local\uv\cache' -ProtectedPath $script:protected |
            Should -BeNullOrEmpty
    }

    It 'does not treat a sibling with a common prefix as a parent' {
        Get-ResikPathSafetyIssue -Path 'C:\Users\someone\AppData\Loc' -ProtectedPath $script:protected |
            Should -BeNullOrEmpty
    }

    It 'rejects a junction' {
        $realDir = Join-Path $TestDrive 'real'
        $junction = Join-Path $TestDrive 'link'
        New-Item -ItemType Directory -Path $realDir | Out-Null
        New-Item -ItemType Junction -Path $junction -Value $realDir | Out-Null

        Get-ResikPathSafetyIssue -Path $junction -ProtectedPath @() | Should -BeLike '*symbolic link or junction*'
        Get-ResikPathSafetyIssue -Path $realDir -ProtectedPath @() | Should -BeNullOrEmpty
    }

    It 'protects the real user profile and local app data by default' {
        Get-ResikPathSafetyIssue -Path $env:USERPROFILE | Should -Not -BeNullOrEmpty
        Get-ResikPathSafetyIssue -Path $env:LOCALAPPDATA | Should -Not -BeNullOrEmpty
        Get-ResikPathSafetyIssue -Path (Split-Path -Parent $env:LOCALAPPDATA) | Should -Not -BeNullOrEmpty
        Get-ResikPathSafetyIssue -Path $env:SystemRoot | Should -Not -BeNullOrEmpty
        Get-ResikPathSafetyIssue -Path (Join-Path $env:LOCALAPPDATA 'uv\cache') | Should -BeNullOrEmpty
    }
}

Describe 'Expand-ResikConfiguredPath' {
    It 'expands <Value>' -ForEach @(
        @{ Value = '%USERPROFILE%\cache'; Expected = '{profile}\cache' }
        @{ Value = '~/cache/hub'; Expected = '{profile}\cache\hub' }
        @{ Value = ' C:\data\cache '; Expected = 'C:\data\cache' }
    ) {
        Expand-ResikConfiguredPath -Path $Value | Should -BeExactly ($Expected.Replace('{profile}', $env:USERPROFILE))
    }

    It 'does not make a relative path absolute' {
        Expand-ResikConfiguredPath -Path 'cache' | Should -BeExactly 'cache'
        Get-ResikPathSafetyIssue -Path (Expand-ResikConfiguredPath -Path '~x\cache') | Should -BeLike '*not a fully qualified*'
    }
}

Describe 'Measure-ResikDirectory' {
    It 'adds up file sizes in nested folders' {
        $root = Join-Path $TestDrive 'measure'
        New-Item -ItemType Directory -Path (Join-Path $root 'a\b') | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $root 'one.bin'), (New-Object byte[] 100))
        [System.IO.File]::WriteAllBytes((Join-Path $root 'a\b\two.bin'), (New-Object byte[] 250))

        $size = Measure-ResikDirectory -Path $root

        $size.Bytes | Should -Be 350
        $size.Files | Should -Be 2
        $size.Unreadable | Should -Be 0
    }

    It 'does not follow junctions' {
        $root = Join-Path $TestDrive 'withlink'
        $outside = Join-Path $TestDrive 'outside'
        New-Item -ItemType Directory -Path $root, $outside | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $outside 'big.bin'), (New-Object byte[] 1000))
        New-Item -ItemType Junction -Path (Join-Path $root 'link') -Value $outside | Out-Null

        (Measure-ResikDirectory -Path $root).Bytes | Should -Be 0
    }

    It 'counts a missing folder as unreadable instead of failing' {
        $size = Measure-ResikDirectory -Path (Join-Path $TestDrive 'missing')
        $size.Bytes | Should -Be 0
        $size.Unreadable | Should -Be 1
    }
}

Describe 'Get-ResikFreeSpace' {
    It 'returns the free space of the drive holding a path' {
        Get-ResikFreeSpace -Path $TestDrive | Should -BeGreaterThan 0
    }

    It 'returns $null for a path without a drive' {
        Get-ResikFreeSpace -Path 'relative\path' | Should -BeNullOrEmpty
    }
}
