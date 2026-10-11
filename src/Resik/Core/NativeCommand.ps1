# Running external tools safely.
#
# Executables are resolved to a full path first, arguments are passed as a list
# and quoted for the target process (never built into a shell command string),
# and every run reports one of these statuses:
#   Success      The process exited with code 0.
#   NotFound     The executable does not exist.
#   StartFailed  The process could not be started.
#   TimedOut     The process exceeded its timeout and was stopped.
#   NonZeroExit  The process exited with a nonzero code.

function Resolve-ResikExecutable {
    # Returns the full path of the first <Name><Extension> found on PATH, or
    # $null. Use '.cmd' only for tools that ship as batch files (Scoop, npm);
    # Invoke-ResikNativeCommand restricts the arguments passed to them.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
        [string] $Name,

        [ValidateSet('.exe', '.cmd')]
        [string] $Extension = '.exe'
    )

    $commands = @(Get-Command -Name "$Name$Extension" -CommandType Application -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
        if ($command.Path -and [System.IO.Path]::IsPathRooted($command.Path)) {
            return $command.Path
        }
    }
    $null
}

function Test-ResikBatchArgument {
    # cmd.exe re-parses the arguments of .cmd and .bat files, so only plain
    # tokens without spaces, quotes, or cmd.exe metacharacters are allowed.
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Argument)
    $Argument -cmatch '^[A-Za-z0-9_.:\\/*=+,@~-]+$'
}

function Stop-ResikProcessTree {
    # Stops a process and the processes it started. Batch files start further
    # processes (cmd.exe runs powershell.exe or node.exe), which Kill() alone
    # would leave running.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Only stops a process that Resik itself started.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.Process] $Process
    )

    $taskkill = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::System)) 'taskkill.exe'
    try {
        if (Test-Path -LiteralPath $taskkill -PathType Leaf) {
            Start-Process -FilePath $taskkill -ArgumentList @('/PID', $Process.Id, '/T', '/F') -WindowStyle Hidden -Wait
        }
    }
    catch {
        Write-Verbose "taskkill failed: $($_.Exception.Message)"
    }
    try {
        if (-not $Process.HasExited) { $Process.Kill() }
    }
    catch {
        Write-Verbose "Could not stop process $($Process.Id): $($_.Exception.Message)"
    }
}

function ConvertTo-ResikProcessArgument {
    # Quotes one argument so that the standard Windows (MSVC) command-line
    # parser reads it back unchanged.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Argument
    )

    if ($Argument.Contains([char]0)) {
        throw [System.ArgumentException]::new('Arguments cannot contain NUL characters.')
    }
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') {
        return $Argument
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($char in $Argument.ToCharArray()) {
        if ($char -eq [char]'\') {
            $backslashes++
            continue
        }
        if ($char -eq [char]'"') {
            # Backslashes before a quote are escaped, and so is the quote.
            [void]$builder.Append([char]'\', (2 * $backslashes) + 1)
        }
        elseif ($backslashes -gt 0) {
            [void]$builder.Append([char]'\', $backslashes)
        }
        [void]$builder.Append($char)
        $backslashes = 0
    }
    # Backslashes before the closing quote are escaped.
    [void]$builder.Append([char]'\', 2 * $backslashes)
    [void]$builder.Append('"')
    $builder.ToString()
}

function Invoke-ResikNativeCommand {
    <#
    .SYNOPSIS
        Runs an executable and captures its output, exit code, and duration.
    .DESCRIPTION
        FilePath must be the full path of an executable, usually from
        Resolve-ResikExecutable. Standard input is closed so the process cannot
        wait for input. Output is decoded as UTF-8. If the caller is stopped
        (for example with Ctrl+C), the process is stopped too.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [AllowEmptyCollection()]
        [string[]] $ArgumentList = @(),

        [ValidateRange(1, 86400)]
        [int] $TimeoutSeconds = 60
    )

    $arguments = (@($ArgumentList) | ForEach-Object { ConvertTo-ResikProcessArgument $_ }) -join ' '
    $display = (@((Split-Path -Leaf $FilePath)) + @($ArgumentList)) -join ' '

    $result = [ordered]@{
        PSTypeName = 'Resik.NativeCommandResult'
        Command    = $display
        FilePath   = $FilePath
        Status     = 'Unknown'
        ExitCode   = $null
        StdOut     = ''
        StdErr     = ''
        Message    = ''
        Duration   = [timespan]::Zero
    }

    if (-not [System.IO.Path]::IsPathRooted($FilePath) -or -not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        $result.Status = 'NotFound'
        $result.Message = "Executable not found: $FilePath"
        return [pscustomobject]$result
    }
    if ([System.IO.Path]::GetExtension($FilePath) -in @('.cmd', '.bat')) {
        $unsafe = @($ArgumentList | Where-Object { -not (Test-ResikBatchArgument $_) })
        if ($unsafe.Count -gt 0) {
            $result.Status = 'StartFailed'
            $result.Message = "Refusing to pass '$($unsafe[0])' to a batch file, because cmd.exe would re-parse it."
            return [pscustomobject]$result
        }
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        try {
            [void]$process.Start()
        }
        catch {
            $result.Status = 'StartFailed'
            $result.Message = "Could not start ${display}: $($_.Exception.Message)"
            return [pscustomobject]$result
        }

        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        # Wait in short steps so that Ctrl+C can interrupt the wait.
        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        $exited = $false
        while (-not $exited -and [datetime]::UtcNow -lt $deadline) {
            $exited = $process.WaitForExit(200)
        }

        if (-not $exited) {
            Stop-ResikProcessTree -Process $process
            [void]$process.WaitForExit(5000)
            $result.Status = 'TimedOut'
            $result.Message = "$display did not finish within $TimeoutSeconds seconds and was stopped."
        }
        else {
            # The parameterless overload also waits for redirected output to close.
            $process.WaitForExit()
            $result.ExitCode = $process.ExitCode
            if ($process.ExitCode -eq 0) {
                $result.Status = 'Success'
            }
            else {
                $result.Status = 'NonZeroExit'
                $result.Message = "$display exited with code $($process.ExitCode)."
            }
        }

        if ($stdoutTask.Wait(5000)) { $result.StdOut = $stdoutTask.Result }
        if ($stderrTask.Wait(5000)) { $result.StdErr = $stderrTask.Result }
    }
    finally {
        $stopwatch.Stop()
        $result.Duration = $stopwatch.Elapsed
        # Reached early when the caller is stopped, for example with Ctrl+C.
        try {
            if (-not $process.HasExited) { Stop-ResikProcessTree -Process $process }
        }
        catch {
            Write-Verbose "Could not check or stop ${display}: $($_.Exception.Message)"
        }
        $process.Dispose()
    }

    [pscustomobject]$result
}

function Get-ResikNativeCommandFailure {
    # Describes a failed run in one line, including the last line of stderr.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Run
    )

    $message = $Run.Message
    $lastError = @($Run.StdErr -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -Last 1
    if ($lastError) { $message += " $($lastError.Trim())" }
    $message
}
