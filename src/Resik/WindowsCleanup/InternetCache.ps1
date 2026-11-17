# Internet Explorer temporary files target (ie-cache).
#
# Internet Explorer is retired, but its download cache (WinINet's "Temporary
# Internet Files") is still used by apps that download through WinINet. It is
# %LOCALAPPDATA%\Microsoft\Windows\INetCache\IE (and INetCache\Low\IE for
# low-integrity processes), split into folders with 8-character names. Resik
# empties those folders and keeps them and container.dat, so WinINet treats
# the deleted entries as not cached and downloads them again.
#
# Microsoft documents no command for this (RunDll32 InetCpl.cpl,
# ClearMyTracksByProcess is undocumented), so Resik deletes the files itself.
# Nothing else in INetCache is touched: Content.MSO and Content.Word belong to
# Office, and Content.IE5 is a link. Cookies (INetCookies) and history are
# kept, so apps that sign in through WinINet stay signed in.

function Get-ResikInternetCacheRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Get-ResikLocalAppDataPath) 'Microsoft\Windows\INetCache'
}

function Get-ResikInternetCacheFolder {
    # Emits the WinINet cache folders (INetCache\IE\XXXXXXXX and
    # INetCache\Low\IE\XXXXXXXX) that exist and are not links.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    foreach ($container in @((Join-Path $Root 'IE'), (Join-Path $Root 'Low\IE'))) {
        if (-not (Test-ResikRealFolder -Path $container -Base $Root)) { continue }
        foreach ($folder in @(Get-ChildItem -LiteralPath $container -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if ($folder.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($folder.Name -cnotmatch '^[A-Z0-9]{8}$') { continue }
            $folder.FullName
        }
    }
}

function Get-ResikCheckedInternetCacheRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $root = Get-ResikInternetCacheRoot
    $issue = Get-ResikPathSafetyIssue -Path $root
    if ($issue) { throw "Refusing to clean temporary internet files: $issue" }
    $root
}

function Invoke-ResikInternetCacheDetection {
    $root = Get-ResikInternetCacheRoot
    if (@(Get-ResikInternetCacheFolder -Root $root).Count -eq 0) {
        return [pscustomobject]@{ Available = $false; Details = "No temporary internet files in $root." }
    }
    [pscustomobject]@{ Available = $true; Details = $root }
}

function Invoke-ResikInternetCacheAnalysis {
    $root = Get-ResikCheckedInternetCacheRoot
    $folders = @(Get-ResikInternetCacheFolder -Root $root)
    $size = Measure-ResikPathSet -Path $folders
    $details = "$($folders.Count) cache folder(s) in $root ($($size.Files) files)"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikInternetCacheCleanup {
    # Re-reads and re-validates the folders instead of trusting the analysis.
    $root = Get-ResikCheckedInternetCacheRoot
    $folders = @(Get-ResikInternetCacheFolder -Root $root)
    if ($folders.Count -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'No temporary internet files; nothing to clean.' }
    }
    Invoke-ResikMeasuredFolderSetDeletion -Path $folders -Label 'the temporary internet files' `
        -InUseHint 'Files in use by a running app were skipped; close it and try again.'
}

function New-ResikInternetCacheTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'ie-cache' -Name 'Internet Explorer temporary files' -Category Windows -RiskLevel Low `
        -Description ('Deletes the temporary internet files that Internet Explorer and apps using its download ' +
            'cache (WinINet) keep in %LOCALAPPDATA%\Microsoft\Windows\INetCache\IE. Cookies, history, and ' +
            'Office''s files in INetCache are kept; the files are downloaded again when needed.') `
        -Detect { Invoke-ResikInternetCacheDetection } `
        -Analyze { Invoke-ResikInternetCacheAnalysis } `
        -Clean { Invoke-ResikInternetCacheCleanup }
}
