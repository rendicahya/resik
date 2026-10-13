BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'Remove-ResikDirectoryTree' {
    BeforeEach {
        $script:scope = Join-Path $TestDrive ('scope-' + [guid]::NewGuid().ToString('N'))
        $script:target = Join-Path $script:scope 'app'
        $script:outside = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $script:target 'settings.ini') -Size 100
        New-TestFile -Path (Join-Path $script:target 'data\deep\file.bin') -Size 200
        New-TestFile -Path (Join-Path $script:outside 'precious.txt') -Size 50
    }

    It 'deletes the folder and everything in it' {
        $result = Remove-ResikDirectoryTree -Path $script:target -Scope $script:scope -Confirm:$false

        $result.Removed | Should -BeTrue
        @($result.Errors).Count | Should -Be 0
        $script:target | Should -Not -Exist
        $script:scope | Should -Exist
    }

    It 'removes a junction inside the folder without touching what it points to' {
        New-Item -ItemType Junction -Path (Join-Path $script:target 'data\link') -Value $script:outside | Out-Null

        $result = Remove-ResikDirectoryTree -Path $script:target -Scope $script:scope -Confirm:$false

        $result.Removed | Should -BeTrue
        Join-Path $script:outside 'precious.txt' | Should -Exist
    }

    It 'deletes read-only files' {
        $file = Join-Path $script:target 'settings.ini'
        Set-ItemProperty -LiteralPath $file -Name IsReadOnly -Value $true

        (Remove-ResikDirectoryTree -Path $script:target -Scope $script:scope -Confirm:$false).Removed | Should -BeTrue
    }

    It 'refuses a folder that is a junction' {
        $link = Join-Path $script:scope 'linked'
        New-Item -ItemType Junction -Path $link -Value $script:outside | Out-Null

        { Remove-ResikDirectoryTree -Path $link -Scope $script:scope -Confirm:$false } |
            Should -Throw '*symbolic link or junction*'
        Join-Path $script:outside 'precious.txt' | Should -Exist
    }

    It 'refuses a folder outside the scope, and the scope itself' {
        { Remove-ResikDirectoryTree -Path $script:outside -Scope $script:scope -Confirm:$false } | Should -Throw '*is not inside*'
        { Remove-ResikDirectoryTree -Path $script:scope -Scope $script:scope -Confirm:$false } | Should -Throw '*is not inside*'
        { Remove-ResikDirectoryTree -Path "$script:scope\app\..\..\x" -Scope $script:scope -Confirm:$false } | Should -Throw '*is not inside*'
        Join-Path $script:outside 'precious.txt' | Should -Exist
    }

    It 'refuses a protected location' {
        { Remove-ResikDirectoryTree -Path $env:USERPROFILE -Scope (Split-Path -Parent $env:USERPROFILE) -Confirm:$false } |
            Should -Throw '*Refusing to delete*'
    }

    It 'reports a file it cannot delete and still deletes the rest' {
        $locked = Join-Path $script:target 'data\locked.db'
        New-TestFile -Path $locked -Size 10
        $stream = [System.IO.File]::Open($locked, 'Open', 'Read', 'None')
        try {
            $result = Remove-ResikDirectoryTree -Path $script:target -Scope $script:scope -Confirm:$false
        }
        finally {
            $stream.Dispose()
        }

        $result.Removed | Should -BeFalse
        @($result.Errors).Count | Should -Be 1
        $result.Errors[0] | Should -BeLike "$locked*"
        Join-Path $script:target 'settings.ini' | Should -Not -Exist
        Join-Path $script:target 'data\deep' | Should -Not -Exist
    }

    It 'deletes nothing with -WhatIf' {
        Remove-ResikDirectoryTree -Path $script:target -Scope $script:scope -WhatIf | Out-Null
        Join-Path $script:target 'settings.ini' | Should -Exist
    }
}
