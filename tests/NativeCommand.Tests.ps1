BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')

    # The running PowerShell executable serves as a harmless child process.
    $script:powershellPath = (Get-Process -Id $PID).Path
}

Describe 'Resolve-ResikExecutable' {
    It 'returns the full path of an executable on PATH' {
        $path = Resolve-ResikExecutable -Name 'cmd'
        $path | Should -Not -BeNullOrEmpty
        [System.IO.Path]::IsPathRooted($path) | Should -BeTrue
        $path | Should -BeLike '*\cmd.exe'
    }

    It 'returns $null for a missing executable' {
        Resolve-ResikExecutable -Name 'resik-no-such-tool' | Should -BeNullOrEmpty
    }

    It 'rejects a name that is not a plain command name: <_>' -ForEach @('a b', '..\uv', 'uv;calc', '') {
        { Resolve-ResikExecutable -Name $_ } | Should -Throw
    }
}

Describe 'ConvertTo-ResikProcessArgument' {
    It 'quotes <Argument> as <Expected>' -ForEach @(
        @{ Argument = 'plain'; Expected = 'plain' }
        @{ Argument = 'C:\no-space\'; Expected = 'C:\no-space\' }
        @{ Argument = ''; Expected = '""' }
        @{ Argument = 'has space'; Expected = '"has space"' }
        @{ Argument = 'a"b'; Expected = '"a\"b"' }
        @{ Argument = 'C:\with space\'; Expected = '"C:\with space\\"' }
        @{ Argument = 'a\"b'; Expected = '"a\\\"b"' }
    ) {
        ConvertTo-ResikProcessArgument -Argument $Argument | Should -BeExactly $Expected
    }

    It 'rejects NUL characters' {
        { ConvertTo-ResikProcessArgument -Argument "a$([char]0)b" } | Should -Throw
    }
}

Describe 'Invoke-ResikNativeCommand' {
    It 'passes arguments through unchanged' {
        $echoScript = Join-Path $TestDrive 'echo-args.ps1'
        Set-Content -LiteralPath $echoScript -Encoding ASCII -Value '$args | ForEach-Object { "[$_]" }'
        $values = @('plain', 'has space', 'quote"inside', 'C:\with space\', 'semi;colon&amp|pipe')

        $run = Invoke-ResikNativeCommand -FilePath $script:powershellPath `
            -ArgumentList (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $echoScript) + $values)

        $run.Status | Should -BeExactly 'Success'
        $run.ExitCode | Should -Be 0
        @($run.StdOut -split "`r?`n" | Where-Object { $_ }) | Should -Be @($values | ForEach-Object { "[$_]" })
    }

    It 'captures stdout, stderr, and a nonzero exit code' {
        $run = Invoke-ResikNativeCommand -FilePath $script:powershellPath -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-Command', "[Console]::Out.WriteLine('out'); [Console]::Error.WriteLine('err'); exit 3")

        $run.Status | Should -BeExactly 'NonZeroExit'
        $run.ExitCode | Should -Be 3
        $run.StdOut.Trim() | Should -BeExactly 'out'
        $run.StdErr.Trim() | Should -BeExactly 'err'
        $run.Message | Should -BeLike '*exited with code 3*'
        Get-ResikNativeCommandFailure $run | Should -BeLike '*exited with code 3. err'
    }

    It 'stops a process that exceeds its timeout' {
        $run = Invoke-ResikNativeCommand -FilePath $script:powershellPath -TimeoutSeconds 1 -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30')

        $run.Status | Should -BeExactly 'TimedOut'
        $run.ExitCode | Should -BeNullOrEmpty
        $run.Duration.TotalSeconds | Should -BeLessThan 15
    }

    It 'reports a missing executable as NotFound' {
        $run = Invoke-ResikNativeCommand -FilePath (Join-Path $TestDrive 'missing.exe')
        $run.Status | Should -BeExactly 'NotFound'
    }

    It 'reports a relative path as NotFound instead of searching for it' {
        $run = Invoke-ResikNativeCommand -FilePath 'cmd.exe'
        $run.Status | Should -BeExactly 'NotFound'
    }

    It 'runs a batch file with plain arguments' {
        $batch = Join-Path $TestDrive 'echo.cmd'
        Set-Content -LiteralPath $batch -Encoding ASCII -Value "@echo off`r`necho [%1] [%2] [%3]"

        $run = Invoke-ResikNativeCommand -FilePath $batch -ArgumentList @('cache', 'rm', '*')

        $run.Status | Should -BeExactly 'Success'
        $run.StdOut.Trim() | Should -BeExactly '[cache] [rm] [*]'
    }

    It 'refuses to pass <_> to a batch file' -ForEach @('a b', 'a&calc', 'a|b', '"q"', '%PATH%', 'a^b', 'x>y', '(a)', '!v!', '') {
        $batch = Join-Path $TestDrive 'never.cmd'
        Set-Content -LiteralPath $batch -Encoding ASCII -Value '@echo ran'

        $run = Invoke-ResikNativeCommand -FilePath $batch -ArgumentList @('ok', $_)

        $run.Status | Should -BeExactly 'StartFailed'
        $run.Message | Should -BeLike '*Refusing to pass*batch file*'
        $run.StdOut | Should -BeExactly ''
    }

    It 'stops the processes a batch file started when it times out' {
        $marker = Join-Path $TestDrive 'child-finished.txt'
        $batch = Join-Path $TestDrive 'slow.cmd'
        Set-Content -LiteralPath $batch -Encoding ASCII -Value (
            "@echo off`r`n`"$script:powershellPath`" -NoProfile -NonInteractive -Command `"Start-Sleep -Seconds 4; Set-Content -LiteralPath '$marker' -Value done`"")

        $run = Invoke-ResikNativeCommand -FilePath $batch -TimeoutSeconds 1

        $run.Status | Should -BeExactly 'TimedOut'
        Start-Sleep -Seconds 6
        $marker | Should -Not -Exist
    }

    It 'does not let the process wait for input' {
        $run = Invoke-ResikNativeCommand -FilePath $script:powershellPath -TimeoutSeconds 30 -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-Command', '$line = [Console]::In.ReadLine(); "got [$line]"')

        $run.Status | Should -BeExactly 'Success'
        $run.StdOut.Trim() | Should -BeExactly 'got []'
    }
}
