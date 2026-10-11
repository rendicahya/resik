# A console spinner shown while Resik measures caches or waits for a tool.
#
# PowerShell runs one command at a time, and long steps (a native command, a
# recursive size measurement) block the main thread. The spinner therefore
# draws from a separate runspace, on one console line, with "\r". While it is
# running the main thread must not write to the console: stop it first.
# Callers stop it in a finally block so Ctrl+C never leaves it drawing.
#
# The spinner is shown only in a console host whose output is not redirected,
# so redirected output and logs never contain spinner frames.

function Test-ResikSpinnerSupported {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($Host.Name -ne 'ConsoleHost' -or [Console]::IsOutputRedirected) { return $false }
    # Never give the spinner more language than Resik itself has (for
    # example under an application control policy).
    if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { return $false }
    try {
        (Get-ResikConsoleWidth) -gt 10
    }
    catch {
        $false
    }
}

function Get-ResikConsoleWidth {
    # Separate so tests can run without a console window.
    [CmdletBinding()]
    [OutputType([int])]
    param()
    [Console]::WindowWidth
}

function Get-ResikSpinnerScript {
    # Runs in the spinner's runspace, which has no Resik functions and no
    # cmdlets, so it uses .NET calls only. Elapsed time restarts whenever the
    # message changes, so it shows how long the current step has taken.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    @'
param($State)
$frames = @('|', '/', '-', '\')
$frame = 0
$message = $null
$watch = [System.Diagnostics.Stopwatch]::StartNew()
while (-not $State.Stop) {
    if ($State.Message -ne $message) {
        $message = $State.Message
        $watch.Restart()
    }
    $text = '{0} {1}' -f $frames[$frame % $frames.Count], $message
    if ($watch.Elapsed.TotalSeconds -ge 1) { $text += (' ({0}s)' -f [int][Math]::Floor($watch.Elapsed.TotalSeconds)) }
    if ($text.Length -gt $State.Width) { $text = $text.Substring(0, $State.Width) }
    [Console]::Write("`r" + $text.PadRight($State.Width))
    $frame++
    [System.Threading.Thread]::Sleep(100)
}
[Console]::Write("`r" + (' ' * $State.Width) + "`r")
'@
}

function Start-ResikSpinner {
    <#
    .SYNOPSIS
        Starts a spinner with a message and returns a handle, or $null when
        the console cannot show one. Stop it with Stop-ResikSpinner.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Draws on the console only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Message
    )

    if (-not (Test-ResikSpinnerSupported)) { return $null }

    $runspace = $null
    $shell = $null
    try {
        # One column less than the window, so the line never wraps.
        $state = [hashtable]::Synchronized(@{ Message = $Message; Stop = $false; Width = (Get-ResikConsoleWidth) - 1 })
        # An empty session state starts fast; it needs a language mode to run
        # the script. Test-ResikSpinnerSupported requires FullLanguage here.
        $sessionState = [initialsessionstate]::Create()
        $sessionState.LanguageMode = [System.Management.Automation.PSLanguageMode]::FullLanguage
        $runspace = [runspacefactory]::CreateRunspace($sessionState)
        $runspace.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        [void]$shell.AddScript((Get-ResikSpinnerScript)).AddArgument($state)
        $handle = $shell.BeginInvoke()
    }
    catch {
        # A spinner is a convenience; Resik works the same without one.
        Write-Verbose "Could not start the spinner: $($_.Exception.Message)"
        if ($null -ne $shell) { $shell.Dispose() }
        if ($null -ne $runspace) { $runspace.Dispose() }
        return $null
    }

    try { $cursorWasVisible = [Console]::CursorVisible; [Console]::CursorVisible = $false } catch { $cursorWasVisible = $null }
    [pscustomobject]@{
        State            = $state
        Shell            = $shell
        Runspace         = $runspace
        Handle           = $handle
        CursorWasVisible = $cursorWasVisible
    }
}

function Set-ResikSpinnerMessage {
    # Changes the message of a running spinner; does nothing without one.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Draws on the console only.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Spinner,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if ($null -ne $Spinner) { $Spinner.State.Message = $Message }
}

function Stop-ResikSpinner {
    # Stops the spinner, clears its line, and restores the cursor. Safe to
    # call with $null or more than once.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Draws on the console only.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object] $Spinner
    )

    if ($null -eq $Spinner -or $Spinner.State.Stop) { return }
    $Spinner.State.Stop = $true
    try {
        # The loop checks the flag every 100 ms and clears its line on exit.
        if (-not $Spinner.Handle.AsyncWaitHandle.WaitOne(2000)) { $Spinner.Shell.Stop() }
        else { [void]$Spinner.Shell.EndInvoke($Spinner.Handle) }
    }
    catch {
        Write-Verbose "Could not stop the spinner cleanly: $($_.Exception.Message)"
    }
    finally {
        $Spinner.Shell.Dispose()
        $Spinner.Runspace.Dispose()
        if ($null -ne $Spinner.CursorWasVisible) {
            try { [Console]::CursorVisible = $Spinner.CursorWasVisible } catch { Write-Verbose 'Could not restore the cursor.' }
        }
    }
}
