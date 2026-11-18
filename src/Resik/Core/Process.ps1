# Closing running apps whose files a target deletes.
#
# Apps keep their caches open, so a target that deletes an app's files can ask
# to close the app first instead of being skipped. An app is described by
# New-ResikAppSpec:
#   ProcessName      process names without .exe ('*' for any name, with PathLike)
#   PathLike         wildcard patterns the executable path must match, because
#                    a name alone can be ambiguous: Playwright's Chromium is
#                    chrome.exe, and the Claude Code CLI is claude.exe like the
#                    Claude desktop app
#   LockFile         a file the app keeps locked while it runs (Chromium's
#                    User Data\lockfile), which finds the app wherever it is
#                    installed
#   IncludeChildren  also stop child processes (NetBeans runs in java.exe,
#                    started by its launcher)
# Only processes in this Windows session are counted or stopped, so another
# signed-in user's apps are never touched.
#
# The question is always asked: "accept all" answers questions about what to
# delete, not about closing apps, and --force never answers it. Without a
# terminal the target is skipped.

function New-ResikAppSpec {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $DisplayName,

        [Parameter(Mandatory)]
        [string[]] $ProcessName,

        [string[]] $PathLike = @(),

        [string] $LockFile = '',

        [switch] $IncludeChildren
    )
    if ($ProcessName -contains '*' -and $PathLike.Count -eq 0) {
        throw "An app matched by any process name needs PathLike ($DisplayName)."
    }
    [pscustomobject]@{
        DisplayName     = $DisplayName
        ProcessName     = $ProcessName
        PathLike        = $PathLike
        LockFile        = $LockFile
        IncludeChildren = [bool]$IncludeChildren
    }
}

function Test-ResikFileLocked {
    # True when Path exists and another process holds it open without sharing.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        $stream.Dispose()
        $false
    }
    catch [System.IO.FileNotFoundException] {
        $false
    }
    catch {
        $true
    }
}

function Get-ResikAppProcess {
    # Emits the app's processes in this session. A process whose path cannot
    # be read does not match PathLike.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $App
    )
    $session = (Get-Process -Id $PID).SessionId
    foreach ($process in @(Get-Process -Name $App.ProcessName -ErrorAction SilentlyContinue)) {
        if ($process.SessionId -ne $session -or $process.Id -eq $PID) { continue }
        if (@($App.PathLike).Count -gt 0) {
            $path = $null
            try { $path = $process.Path } catch { $path = $null }
            if (-not $path) { continue }
            $matched = $false
            foreach ($pattern in $App.PathLike) {
                if ($path -like $pattern) { $matched = $true }
            }
            if (-not $matched) { continue }
        }
        $process
    }
}

function Get-ResikChildProcessId {
    # The IDs of the processes started by ParentId.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [int] $ParentId
    )
    @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $ParentId" -ErrorAction SilentlyContinue |
            ForEach-Object { [int]$_.ProcessId })
}

function Test-ResikAppRunning {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [object] $App
    )
    if (@(Get-ResikAppProcess -App $App).Count -gt 0) { return $true }
    $App.LockFile -and (Test-ResikFileLocked -Path $App.LockFile)
}

function Stop-ResikAppProcess {
    # Stops the app's processes (and their children with IncludeChildren) and
    # waits up to ten seconds for the app to stop running.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [object] $App
    )
    foreach ($process in @(Get-ResikAppProcess -App $App)) {
        $ids = @($process.Id)
        if ($App.IncludeChildren) { $ids += @(Get-ResikChildProcessId -ParentId $process.Id) }
        foreach ($id in $ids) {
            if ($PSCmdlet.ShouldProcess("$($App.DisplayName) (process $id)", 'Stop')) {
                Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
            }
        }
    }
    $deadline = (Get-Date).AddSeconds(10)
    while ((Test-ResikAppRunning -App $App) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
    }
}

function Get-ResikAppRunningNote {
    # The sentence an analysis adds while the app runs.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $App
    )
    "$($App.DisplayName) is running; Resik will ask to close it before cleaning"
}

function Close-ResikAppForCleanup {
    # Returns $null when the app is not running, or was closed after the user
    # agreed; otherwise a Skipped result for the target to return.
    [CmdletBinding()]
    param(
        [object] $Context,

        [Parameter(Mandatory)]
        [object] $App,

        # What cannot be deleted while the app runs, such as 'its cache'.
        [Parameter(Mandatory)]
        [string] $Label,

        # What closing the app costs the user.
        [string] $Consequence = 'Unsaved work in it is lost.'
    )
    $name = $App.DisplayName
    if (-not (Test-ResikAppRunning -App $App)) { return $null }
    $canPrompt = $null -ne $Context -and [bool](Get-ResikOptionalProperty $Context 'CanPrompt')
    if (-not $canPrompt) {
        return [pscustomobject]@{
            Status  = 'Skipped'
            Details = "$name is running. Close $name first, or run Resik in a terminal so it can offer to. Nothing was removed."
        }
    }
    if (-not (Read-ResikConfirmation -Prompt "$name is running, so $Label cannot be deleted. Close $name now? $Consequence [y/N]")) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "You kept $name open. Nothing was removed." }
    }
    Write-Host "Closing $name..."
    Stop-ResikAppProcess -App $App -Confirm:$false
    if (Test-ResikAppRunning -App $App) {
        return [pscustomobject]@{
            Status  = 'Skipped'
            Details = "$name could not be closed. Close it yourself, then try again. Nothing was removed."
        }
    }
    $null
}
