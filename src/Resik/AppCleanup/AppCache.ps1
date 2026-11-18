# Shared helpers for app cache targets (AppCleanup/ and a few developer
# tools): analysis and cleanup of a set of cache folders that belong to one
# app, asking to close the app first when it runs (Core/Process.ps1).
#
# Callers find the folders themselves, each checked with Test-ResikRealFolder
# so a link cannot redirect the deletion, and find them again in Clean rather
# than trusting the analysis. The folders are emptied (and with -RemoveFolder
# deleted) through Invoke-ResikMeasuredFolderSetDeletion, which runs
# Get-ResikPathSafetyIssue on each and skips files in use.

function Get-ResikRoamingAppDataPath {
    # %APPDATA%, as a function so tests can point it at TestDrive.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
}

function Get-ResikLocalLowPath {
    # %USERPROFILE%\AppData\LocalLow, next to %LOCALAPPDATA%. .NET has no
    # special folder for it.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Split-Path -Parent (Get-ResikLocalAppDataPath)) 'LocalLow'
}

function Get-ResikExistingFolder {
    # Emits each Path that is a real folder inside Base (no link on the way).
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [string[]] $Path = @(),

        [Parameter(Mandatory)]
        [string] $Base
    )
    foreach ($candidate in $Path) {
        if (Test-ResikRealFolder -Path $candidate -Base $Base) { $candidate }
    }
}

function Get-ResikCheckedAppRoot {
    # Returns Root after the path safety checks; throws when it is unsafe.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $AppName
    )
    $issue = Get-ResikPathSafetyIssue -Path $Root
    if ($issue) { throw "Refusing to clean $AppName data: $issue" }
    if (Test-Path -LiteralPath $Root) {
        $item = Get-Item -LiteralPath $Root -Force
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to clean $AppName data: $Root is a link."
        }
    }
    $Root
}

function Invoke-ResikAppRootDetection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $AppName
    )
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return [pscustomobject]@{ Available = $false; Details = "No $AppName data at $Root." }
    }
    [pscustomobject]@{ Available = $true; Details = $Root }
}

function Invoke-ResikAppFolderAnalysis {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]] $Path = @(),

        # Where the folders are, for the details, such as the User Data path.
        [Parameter(Mandatory)]
        [string] $Where,

        [object] $App = $null
    )
    $folders = @($Path)
    if ($folders.Count -eq 0) {
        return [pscustomobject]@{ EstimatedBytes = 0; Details = "Nothing to clean in $Where." }
    }
    $size = Measure-ResikPathSet -Path $folders
    $details = "$($folders.Count) folder(s) in $Where ($($size.Files) files)"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    if ($null -ne $App -and (Test-ResikAppRunning -App $App)) { $details += ". $(Get-ResikAppRunningNote -App $App)" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikAppFolderCleanup {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]] $Path = @(),

        [Parameter(Mandatory)]
        [string] $Where,

        # Names the cache in messages, such as 'the Comet cache'.
        [Parameter(Mandatory)]
        [string] $Label,

        [object] $App = $null,

        [object] $Context = $null,

        # What closing the app costs the user (Close-ResikAppForCleanup).
        [string] $Consequence = 'Unsaved work in it is lost.',

        [switch] $RemoveFolder
    )
    $folders = @($Path)
    if ($folders.Count -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "Nothing to clean in $Where." }
    }
    $hint = ''
    if ($null -ne $App) {
        $refusal = Close-ResikAppForCleanup -Context $Context -App $App -Label $Label -Consequence $Consequence
        if ($refusal) { return $refusal }
        $hint = "Close $($App.DisplayName), then try again."
    }
    Invoke-ResikMeasuredFolderSetDeletion -Path $folders -Label $Label -InUseHint $hint -RemoveFolder:$RemoveFolder
}
