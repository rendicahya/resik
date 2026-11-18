# Microsoft Edge: edge-profile, which resets Edge. Edge's caches are cleaned by
# the edge-cache, edge-code-cache, edge-gpu-cache, and edge-service-workers
# targets (AppCleanup/Chromium.ps1), which use Get-ResikEdgeUserDataPath.
#
# edge-profile (High, -ExplicitOnly) deletes the whole
# %LOCALAPPDATA%\Microsoft\Edge\User Data folder (Edge stable; Beta, Dev, and
# Canary are not touched), which resets Edge as if it had just been installed:
# every profile with its history, cookies, saved passwords, extensions, and
# settings. It asks first, like scoop-persist, and --force never answers that
# question. Edge keeps these files open (Startup boost can keep it running with
# no window), so it then asks to close Edge (Core/Process.ps1). Data that Edge
# sync has stored in a Microsoft account comes back after signing in again.
# Microsoft Edge WebView2, which Windows and other apps use, keeps its data in
# the apps' own folders and runs as msedgewebview2.exe, so it is not affected.
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

function Get-ResikEdgeApp {
    [CmdletBinding()]
    param()
    (Get-ResikChromiumSpec -Id 'edge').App
}

function Test-ResikEdgeRunning {
    # True while Edge (msedge.exe, or its locked User Data\lockfile) runs in
    # this session. WebView2 processes are named msedgewebview2.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    Test-ResikAppRunning -App (Get-ResikEdgeApp)
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
function Invoke-ResikEdgeProfileAnalysis {
    $userData = Get-ResikEdgeCheckedUserData
    $size = Measure-ResikPathSet -Path @($userData)
    $profiles = @(Get-ChildItem -LiteralPath $userData -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Preferences') -PathType Leaf })
    $details = "$userData ($($size.Files) files, $($profiles.Count) profile(s)): history, cookies, saved passwords, extensions, and settings"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    if (Test-ResikEdgeRunning) { $details += ". $(Get-ResikAppRunningNote -App (Get-ResikEdgeApp))" }
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
    # Asked after the deletion question, so Edge is closed only when the data
    # is really going to be deleted.
    $refusal = Close-ResikAppForCleanup -Context $Context -App (Get-ResikEdgeApp) -Label 'its data' `
        -Consequence 'Open tabs are closed without asking, and downloads in progress stop.'
    if ($refusal) { return $refusal }

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
            'first, and asks to close Edge if it is running. Never chosen by --all or "select all".') `
        -Detect { Invoke-ResikEdgeDetection } `
        -Analyze { Invoke-ResikEdgeProfileAnalysis } `
        -Clean { param($Context) Invoke-ResikEdgeProfileCleanup -Context $Context }
}
