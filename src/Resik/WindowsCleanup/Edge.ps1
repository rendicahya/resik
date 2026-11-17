# Microsoft Edge targets: edge-cache and edge-profile.
#
# Edge has no command-line option for clearing its data, so Resik deletes
# files itself, only in %LOCALAPPDATA%\Microsoft\Edge\User Data (Edge stable;
# Beta, Dev, and Canary are not touched) and only while no msedge.exe process
# runs: Edge holds these files open, and Startup boost can keep it running in
# the background with no window.
#
# edge-cache (Low) empties the same kind of data as Edge's "Cached images and
# files", plus GPU shader caches:
#   <profile>\Cache, Code Cache, GPUCache, DawnCache, DawnGraphiteCache,
#   DawnWebGPUCache
#   User Data\ShaderCache, GrShaderCache, GraphiteDawnCache, GPUPersistentCache
# A profile is a folder in User Data that contains a Preferences file. History,
# cookies, passwords, site data (Service Worker, IndexedDB, Local Storage),
# extensions, and settings are kept.
#
# edge-profile (High, -ExplicitOnly) deletes the whole User Data folder, which
# resets Edge as if it had just been installed: every profile with its
# history, cookies, saved passwords, extensions, and settings. It asks first,
# like scoop-persist, and --force never answers that question. Data that Edge
# sync has stored in a Microsoft account comes back after signing in again.
# Microsoft Edge WebView2, which Windows and other apps use, keeps its data in
# the apps' own folders and runs as msedgewebview2.exe, so neither target
# affects it.

function Get-ResikEdgeRoot {
    # %LOCALAPPDATA%\Microsoft\Edge, the scope edge-profile deletes inside.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Get-ResikLocalAppDataPath) 'Microsoft\Edge'
}

function Get-ResikEdgeUserDataPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Get-ResikEdgeRoot) 'User Data'
}

function Test-ResikEdgeRunning {
    # True while a Microsoft Edge browser process (msedge.exe) runs. WebView2
    # processes are named msedgewebview2 and are not counted.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    @(Get-Process -Name 'msedge' -ErrorAction SilentlyContinue).Count -gt 0
}

function Get-ResikEdgeCacheFolder {
    # Emits the cache folders that exist, as full paths.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $UserData
    )

    $profileCaches = @('Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache')
    $sharedCaches = @('ShaderCache', 'GrShaderCache', 'GraphiteDawnCache', 'GPUPersistentCache')

    $candidates = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $sharedCaches) { $candidates.Add((Join-Path $UserData $name)) }
    foreach ($folder in @(Get-ChildItem -LiteralPath $UserData -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if ($folder.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $folder.FullName 'Preferences') -PathType Leaf)) { continue }
        foreach ($name in $profileCaches) { $candidates.Add((Join-Path $folder.FullName $name)) }
    }
    foreach ($candidate in $candidates) {
        if (Test-ResikRealFolder -Path $candidate -Base $UserData) { $candidate }
    }
}

function Get-ResikEdgeCheckedUserData {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $userData = Get-ResikEdgeUserDataPath
    $issue = Get-ResikPathSafetyIssue -Path $userData
    if ($issue) { throw "Refusing to clean Microsoft Edge data: $issue" }
    if ((Test-Path -LiteralPath $userData) -and -not (Test-ResikRealFolder -Path $userData -Base (Get-ResikEdgeRoot))) {
        throw "Refusing to clean Microsoft Edge data: $userData is a link."
    }
    $userData
}

function Invoke-ResikEdgeDetection {
    $userData = Get-ResikEdgeUserDataPath
    if (-not (Test-Path -LiteralPath $userData -PathType Container)) {
        return [pscustomobject]@{ Available = $false; Details = "No Microsoft Edge data at $userData." }
    }
    [pscustomobject]@{ Available = $true; Details = $userData }
}

function Get-ResikEdgeRunningNote {
    'Close Microsoft Edge before cleaning (Startup boost can keep it running in the background)'
}

function Invoke-ResikEdgeCacheAnalysis {
    $userData = Get-ResikEdgeCheckedUserData
    $folders = @(Get-ResikEdgeCacheFolder -UserData $userData)
    if ($folders.Count -eq 0) {
        return [pscustomobject]@{ EstimatedBytes = 0; Details = "No Edge cache folders in $userData." }
    }
    $size = Measure-ResikPathSet -Path $folders
    $details = "$($folders.Count) cache folder(s) in $userData ($($size.Files) files)"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    if (Test-ResikEdgeRunning) { $details += ". $(Get-ResikEdgeRunningNote)" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikEdgeCacheCleanup {
    # Re-reads and re-validates the folders instead of trusting the analysis.
    if (Test-ResikEdgeRunning) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "Microsoft Edge is running. $(Get-ResikEdgeRunningNote). Nothing was removed." }
    }
    $userData = Get-ResikEdgeCheckedUserData
    $folders = @(Get-ResikEdgeCacheFolder -UserData $userData)
    if ($folders.Count -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'No Edge cache folders; nothing to clean.' }
    }
    Invoke-ResikMeasuredFolderSetDeletion -Path $folders -Label 'the Microsoft Edge cache' `
        -InUseHint 'Close Microsoft Edge, then try again.'
}

function Invoke-ResikEdgeProfileAnalysis {
    $userData = Get-ResikEdgeCheckedUserData
    $size = Measure-ResikPathSet -Path @($userData)
    $profiles = @(Get-ChildItem -LiteralPath $userData -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Preferences') -PathType Leaf })
    $details = "$userData ($($size.Files) files, $($profiles.Count) profile(s)): history, cookies, saved passwords, extensions, and settings"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    if (Test-ResikEdgeRunning) { $details += ". $(Get-ResikEdgeRunningNote)" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikEdgeProfileCleanup {
    # Deletes the whole User Data folder, only after the user confirms it.
    # --force does not answer this question.
    [CmdletBinding()]
    param(
        [object] $Context
    )

    $canPrompt = $null -ne $Context -and [bool](Get-ResikOptionalProperty $Context 'CanPrompt')
    $acceptAll = $canPrompt -and [bool](Get-ResikOptionalProperty $Context 'AcceptAll')
    if (-not $canPrompt) {
        return [pscustomobject]@{
            Status  = 'Skipped'
            Details = 'Microsoft Edge data is removed only after you confirm it, which needs a terminal. Nothing was removed.'
        }
    }
    if (Test-ResikEdgeRunning) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "Microsoft Edge is running. $(Get-ResikEdgeRunningNote). Nothing was removed." }
    }
    $root = Get-ResikEdgeRoot
    $userData = Get-ResikEdgeCheckedUserData
    if (-not (Test-Path -LiteralPath $userData -PathType Container)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No Microsoft Edge data at $userData; nothing to clean." }
    }

    $before = Measure-ResikPathSet -Path @($userData)
    $what = "all Microsoft Edge data ($(Format-ResikSize $before.Bytes)) in $userData, including history, cookies, " +
        'saved passwords, extensions, and settings of every profile'
    if ($acceptAll) {
        Write-Host "Deleting $what (you answered yes to all)."
    }
    elseif (-not (Read-ResikConfirmation -Prompt "Delete ${what}? It cannot be recovered. [y/N]")) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'You kept the Microsoft Edge data. Nothing was removed.' }
    }
    # Edge could have been started while the question was open.
    if (Test-ResikEdgeRunning) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "Microsoft Edge was started. $(Get-ResikEdgeRunningNote). Nothing was removed." }
    }

    $errors = New-Object 'System.Collections.Generic.List[string]'
    $freeBefore = Get-ResikFreeSpace -Path $root
    $spinner = Start-ResikSpinner -Message 'Deleting Microsoft Edge data'
    try {
        $deletion = Remove-ResikDirectoryTree -Path $userData -Scope $root -Confirm:$false
        foreach ($line in @($deletion.Errors)) { $errors.Add($line) }
    }
    catch {
        $errors.Add($_.Exception.Message)
    }
    finally {
        Stop-ResikSpinner -Spinner $spinner
    }
    $after = Measure-ResikPathSet -Path @($userData)
    $freeAfter = Get-ResikFreeSpace -Path $root

    $measured = if ($before.Unreadable -eq 0 -and $after.Unreadable -eq 0) { $before.Bytes - $after.Bytes } else { $null }
    if ($errors.Count -eq 0) {
        $status = 'Success'
        $details = "Deleted $userData. Edge starts as if newly installed."
    }
    else {
        $status = if ($null -ne $measured -and $measured -gt 0) { 'PartialSuccess' } else { 'Failed' }
        $details = "$($errors.Count) item(s) in $userData could not be deleted, for example $($errors[0]). Close Microsoft Edge, then try again."
    }
    [pscustomobject]@{
        Status               = $status
        Details              = $details
        MeasuredBytes        = $measured
        FreeSpaceChangeBytes = $(if ($null -ne $freeBefore -and $null -ne $freeAfter) { $freeAfter - $freeBefore } else { $null })
    }
}

function New-ResikEdgeCacheTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'edge-cache' -Name 'Microsoft Edge cache' -Category Windows -RiskLevel Low `
        -Description ('Deletes Microsoft Edge''s cached web files and GPU shader caches in every profile. History, ' +
            'cookies, passwords, site data, extensions, and settings are kept; Edge downloads the files again. ' +
            'Refused while Edge is running.') `
        -Detect { Invoke-ResikEdgeDetection } `
        -Analyze { Invoke-ResikEdgeCacheAnalysis } `
        -Clean { Invoke-ResikEdgeCacheCleanup }
}

function New-ResikEdgeProfileTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'edge-profile' -Name 'Microsoft Edge data (reset)' -Category Windows -RiskLevel High `
        -ExplicitOnly `
        -Description ('Deletes all Microsoft Edge data in %LOCALAPPDATA%\Microsoft\Edge\User Data: every profile ' +
            'with its history, cookies, saved passwords, extensions, and settings, so Edge starts as if newly ' +
            'installed. Only data synced to a Microsoft account comes back. It cannot be recovered, so Resik asks ' +
            'first. Refused while Edge is running. Never chosen by --all or "select all".') `
        -Detect { Invoke-ResikEdgeDetection } `
        -Analyze { Invoke-ResikEdgeProfileAnalysis } `
        -Clean { param($Context) Invoke-ResikEdgeProfileCleanup -Context $Context }
}
