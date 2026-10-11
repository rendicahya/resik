BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
    # TestSetup turns the spinner off; restore the real check.
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Resik\UI\Spinner.ps1')
}

Describe 'Test-ResikSpinnerSupported' {
    It 'is false when output is redirected' {
        # A child process with redirected output, as in a log or a pipe.
        $source = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Resik\UI\Spinner.ps1'
        $output = & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -Command ". '$source'; Test-ResikSpinnerSupported"
        $output | Should -BeExactly 'False'
    }
}

Describe 'Start-ResikSpinner' {
    It 'returns $null when the console cannot show a spinner' {
        Mock Test-ResikSpinnerSupported { $false }
        Start-ResikSpinner -Message 'Working' | Should -BeNullOrEmpty
    }

    It 'returns $null instead of failing when the console size cannot be read' {
        Mock Test-ResikSpinnerSupported { $true }
        Mock Get-ResikConsoleWidth { throw [System.IO.IOException] 'The handle is invalid.' }
        Start-ResikSpinner -Message 'Working' | Should -BeNullOrEmpty
    }

    It 'accepts $null in Set-ResikSpinnerMessage and Stop-ResikSpinner' {
        { Set-ResikSpinnerMessage -Spinner $null -Message 'x'; Stop-ResikSpinner -Spinner $null } | Should -Not -Throw
    }
}

Describe 'Spinner thread' {
    It 'runs the spinner script until it is told to stop' {
        # Runs the same script in the same kind of runspace as Start-ResikSpinner,
        # with output captured instead of drawn.
        $state = [hashtable]::Synchronized(@{ Message = 'Analyzing uv cache'; Stop = $false; Width = 40 })
        $sessionState = [initialsessionstate]::Create()
        $sessionState.LanguageMode = [System.Management.Automation.PSLanguageMode]::FullLanguage
        $runspace = [runspacefactory]::CreateRunspace($sessionState)
        $runspace.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        $writer = New-Object System.IO.StringWriter
        $originalOut = [Console]::Out
        try {
            [Console]::SetOut($writer)
            [void]$shell.AddScript((Get-ResikSpinnerScript)).AddArgument($state)
            $handle = $shell.BeginInvoke()
            Start-Sleep -Milliseconds 350
            $state.Message = 'Analyzing pip cache'
            Start-Sleep -Milliseconds 250
            $state.Stop = $true
            $handle.AsyncWaitHandle.WaitOne(2000) | Should -BeTrue
            [void]$shell.EndInvoke($handle)
            $shell.HadErrors | Should -BeFalse
        }
        finally {
            [Console]::SetOut($originalOut)
            $shell.Dispose()
            $runspace.Dispose()
        }

        $drawn = $writer.ToString()
        $drawn | Should -Match '\r[|/\\-] Analyzing uv cache'
        $drawn | Should -Match '\r[|/\\-] Analyzing pip cache'
        # Every frame is exactly one line wide, and the last write clears it.
        @($drawn -split "`r" | Where-Object { $_ -ne '' } | Where-Object { $_.Length -ne 40 }).Count | Should -Be 0
        $drawn | Should -Match ('\r {40}\r$')
    }

    It 'stops a running spinner and can be stopped twice' {
        Mock Test-ResikSpinnerSupported { $true }
        Mock Get-ResikConsoleWidth { 80 }
        Mock Get-ResikSpinnerScript { 'param($State) while (-not $State.Stop) { [System.Threading.Thread]::Sleep(20) }' }

        $spinner = Start-ResikSpinner -Message 'Working'
        try {
            $spinner | Should -Not -BeNullOrEmpty
            Set-ResikSpinnerMessage -Spinner $spinner -Message 'Still working'
            $spinner.State.Message | Should -BeExactly 'Still working'
        }
        finally {
            Stop-ResikSpinner -Spinner $spinner
        }

        $spinner.Handle.IsCompleted | Should -BeTrue
        $spinner.Runspace.RunspaceStateInfo.State | Should -Be 'Closed'
        { Stop-ResikSpinner -Spinner $spinner } | Should -Not -Throw
    }
}

Describe 'Spinner use' {
    BeforeEach {
        Mock Write-Host {}
        Mock Start-ResikSpinner { [pscustomobject]@{ State = @{ Message = $Message } } }
        Mock Set-ResikSpinnerMessage {}
        Mock Stop-ResikSpinner {}
    }

    It 'names each target during analysis' {
        $targets = @((New-TestTarget -Id 'one'), (New-TestTarget -Id 'two'))

        $results = @(Invoke-ResikAnalysisWithSpinner -Targets $targets)

        $results.Count | Should -Be 2
        Should -Invoke Set-ResikSpinnerMessage -Times 1 -Exactly -ParameterFilter { $Message -ceq 'Analyzing Fake one (1 of 2)' }
        Should -Invoke Set-ResikSpinnerMessage -Times 1 -Exactly -ParameterFilter { $Message -ceq 'Analyzing Fake two (2 of 2)' }
        Should -Invoke Stop-ResikSpinner -Times 1 -Exactly
    }

    It 'stops the spinner when analysis is interrupted' {
        Mock Invoke-ResikAnalysis { throw 'interrupted' }
        { Invoke-ResikAnalysisWithSpinner -Targets @(New-TestTarget) } | Should -Throw 'interrupted'
        Should -Invoke Stop-ResikSpinner -Times 1 -Exactly
    }

    It 'shows the command while a cleanup command runs, and stops before reporting' {
        Mock Invoke-ResikNativeCommand { New-TestRunResult }

        $outcome = Invoke-ResikMeasuredCommand -FilePath 'C:\fake\tool.exe' -ArgumentList @('cache', 'clean')

        $outcome.Status | Should -BeExactly 'Success'
        Should -Invoke Set-ResikSpinnerMessage -Times 1 -Exactly -ParameterFilter { $Message -ceq 'Waiting for tool.exe cache clean' }
        Should -Invoke Stop-ResikSpinner -Times 1 -Exactly
    }

    It 'stops the spinner when a cleanup command throws' {
        Mock Invoke-ResikNativeCommand { throw 'boom' }
        { Invoke-ResikMeasuredCommand -FilePath 'C:\fake\tool.exe' } | Should -Throw 'boom'
        Should -Invoke Stop-ResikSpinner -Times 1 -Exactly
    }
}
