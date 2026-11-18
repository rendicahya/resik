BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')

    function New-TestProcess {
        # A stand-in for a Process object.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Creates an in-memory object only.')]
        param([int] $Id, [string] $Name, [string] $Path, [int] $SessionId)
        [pscustomobject]@{ Id = $Id; ProcessName = $Name; Path = $Path; SessionId = $SessionId }
    }
}

Describe 'New-ResikAppSpec' {
    It 'refuses to match any process name without a path pattern' {
        { New-ResikAppSpec -DisplayName 'App' -ProcessName '*' } | Should -Throw '*needs PathLike*'
    }
}

Describe 'Get-ResikAppProcess' {
    BeforeEach {
        $script:session = (Get-Process -Id $PID).SessionId
        Mock Get-Process -ParameterFilter { $null -ne $Id } { [pscustomobject]@{ SessionId = $script:session } }
        Mock Get-Process -ParameterFilter { $null -ne $Name } {
            New-TestProcess -Id 1 -Name 'chrome' -Path 'C:\Program Files\Google\Chrome\Application\chrome.exe' -SessionId $script:session
            New-TestProcess -Id 2 -Name 'chrome' -Path 'C:\Users\u\AppData\Local\ms-playwright\chromium-1\chrome.exe' -SessionId $script:session
            New-TestProcess -Id 3 -Name 'chrome' -Path 'C:\Program Files\Google\Chrome\Application\chrome.exe' -SessionId ($script:session + 1)
            New-TestProcess -Id 4 -Name 'chrome' -Path $null -SessionId $script:session
        }
    }

    It 'counts only processes in this session' {
        $app = New-ResikAppSpec -DisplayName 'Chrome' -ProcessName 'chrome'
        @(Get-ResikAppProcess -App $app | ForEach-Object Id) | Should -Be @(1, 2, 4)
    }

    It 'keeps only executables matching the path patterns' {
        $app = New-ResikAppSpec -DisplayName 'Chrome' -ProcessName 'chrome' -PathLike '*\Google\Chrome\Application\chrome.exe'
        @(Get-ResikAppProcess -App $app | ForEach-Object Id) | Should -Be @(1)
    }
}

Describe 'Test-ResikAppRunning' {
    BeforeEach {
        Mock Get-ResikAppProcess {}
    }

    It 'is true while the lock file is held open' {
        $lock = Join-Path $TestDrive ('lockfile-' + [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $lock -Value 'x'
        $app = New-ResikAppSpec -DisplayName 'App' -ProcessName 'app' -LockFile $lock
        $stream = [System.IO.File]::Open($lock, 'Open', 'ReadWrite', 'None')
        try {
            Test-ResikAppRunning -App $app | Should -BeTrue
        }
        finally {
            $stream.Dispose()
        }
        Test-ResikAppRunning -App $app | Should -BeFalse
    }

    It 'is false when the lock file is missing' {
        $app = New-ResikAppSpec -DisplayName 'App' -ProcessName 'app' -LockFile (Join-Path $TestDrive 'missing-lockfile')
        Test-ResikAppRunning -App $app | Should -BeFalse
    }
}

Describe 'Stop-ResikAppProcess' {
    BeforeEach {
        Mock Start-Sleep {}
    }

    It 'stops each matching process and waits for it to exit' {
        $script:running = @(101, 202)
        Mock Get-ResikAppProcess { foreach ($id in $script:running) { New-TestProcess -Id $id -Name 'app' } }
        Mock Stop-Process { $script:running = @($script:running | Where-Object { $Id -notcontains $_ }) }

        Stop-ResikAppProcess -App (New-ResikAppSpec -DisplayName 'App' -ProcessName 'app') -Confirm:$false

        Should -Invoke Stop-Process -Times 2 -Exactly -ParameterFilter { $Force }
    }

    It 'stops child processes only with IncludeChildren' {
        $script:running = @(101)
        Mock Get-ResikAppProcess { foreach ($id in $script:running) { New-TestProcess -Id $id -Name 'app' } }
        Mock Get-ResikChildProcessId { 555 }
        Mock Stop-Process { $script:running = @() }

        Stop-ResikAppProcess -App (New-ResikAppSpec -DisplayName 'App' -ProcessName 'app' -IncludeChildren) -Confirm:$false
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -contains 555 }

        $script:running = @(101)
        Stop-ResikAppProcess -App (New-ResikAppSpec -DisplayName 'App' -ProcessName 'app') -Confirm:$false
        Should -Invoke Get-ResikChildProcessId -Times 1 -Exactly
    }
}

Describe 'Close-ResikAppForCleanup' {
    BeforeEach {
        $script:open = $true
        Mock Test-ResikAppRunning { $script:open }
        Mock Stop-ResikAppProcess { $script:open = $false }
        Mock Read-ResikConfirmation { $true }
        Mock Write-Host {}
        $script:app = New-ResikAppSpec -DisplayName 'App' -ProcessName 'app'
        $script:prompting = [pscustomobject]@{ CanPrompt = $true; AcceptAll = $false }
    }

    It 'does nothing when the app is not running' {
        $script:open = $false
        Close-ResikAppForCleanup -Context $script:prompting -App $script:app -Label 'its cache' | Should -BeNullOrEmpty
        Should -Invoke Read-ResikConfirmation -Times 0 -Exactly
    }

    It 'closes the app after the user agrees' {
        Close-ResikAppForCleanup -Context $script:prompting -App $script:app -Label 'its cache' | Should -BeNullOrEmpty
        Should -Invoke Read-ResikConfirmation -Times 1 -Exactly -ParameterFilter {
            $Prompt -eq 'App is running, so its cache cannot be deleted. Close App now? Unsaved work in it is lost. [y/N]'
        }
        Should -Invoke Stop-ResikAppProcess -Times 1 -Exactly
    }

    It 'keeps the app open when declined' {
        Mock Read-ResikConfirmation { $false }
        (Close-ResikAppForCleanup -Context $script:prompting -App $script:app -Label 'its cache').Details |
            Should -BeExactly 'You kept App open. Nothing was removed.'
        Should -Invoke Stop-ResikAppProcess -Times 0 -Exactly
    }

    It 'asks even after "accept all"' {
        $all = [pscustomobject]@{ CanPrompt = $true; AcceptAll = $true }
        Close-ResikAppForCleanup -Context $all -App $script:app -Label 'its cache' | Out-Null
        Should -Invoke Read-ResikConfirmation -Times 1 -Exactly
    }

    It 'never stops the app without a terminal' {
        (Close-ResikAppForCleanup -Context $null -App $script:app -Label 'its cache').Status | Should -BeExactly 'Skipped'
        Should -Invoke Read-ResikConfirmation -Times 0 -Exactly
        Should -Invoke Stop-ResikAppProcess -Times 0 -Exactly
    }

    It 'reports an app that would not close' {
        Mock Stop-ResikAppProcess {}
        (Close-ResikAppForCleanup -Context $script:prompting -App $script:app -Label 'its cache').Details |
            Should -BeLike 'App could not be closed.*'
    }
}
