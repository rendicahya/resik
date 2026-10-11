# Scoop targets (https://scoop.sh/), verified against Scoop v0.6.0:
#   scoop-apps    "scoop cleanup *"    removes old versions of installed apps
#   scoop-cache   "scoop cache rm *"   removes downloaded installers
# These are two separate targets so that each reports its own result.
# Neither command has a preview mode, so analysis reads the filesystem:
#
# - Scoop's root is $env:SCOOP, else root_path in Scoop's config, else the
#   folder that holds Scoop's shims folder. The download cache is
#   $env:SCOOP_CACHE, else cache_path in the config, else <root>\cache.
#   The config is <root>\config.json if present (portable install), else
#   $env:XDG_CONFIG_HOME\scoop\config.json or ~\.config\scoop\config.json.
#   This mirrors Scoop's lib\core.ps1.
# - An app's old versions are the folders in <root>\apps\<app> other than
#   "current" and the version "current" links to. Apps whose "current" is not
#   a link are left out of the estimate.
#
# Global apps (installed with --global) need administrator rights and are not
# cleaned. Scoop ships as scoop.cmd, so only fixed arguments are passed to it.

function Get-ResikScoopExecutable {
    $scoop = Resolve-ResikExecutable -Name 'scoop' -Extension '.cmd'
    if (-not $scoop) { throw 'Scoop was not found on PATH.' }
    $scoop
}

function Get-ResikScoopConfigValue {
    # Reads a setting from Scoop's config file, or returns $null.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ShimRoot,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $configFile = Join-Path $ShimRoot 'config.json'
    if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
        $configHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $env:USERPROFILE '.config' }
        $configFile = Join-Path $configHome 'scoop\config.json'
    }
    if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) { return $null }
    try {
        $config = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "Could not read Scoop's config file ${configFile}: $($_.Exception.Message)"
    }
    $value = Get-ResikOptionalProperty $config $Name
    if ($value) { [string]$value } else { $null }
}

function Get-ResikScoopLocation {
    # Returns Root, Apps, and Cache, each checked with Get-ResikPathSafetyIssue.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ScoopPath
    )

    # The shim lives in <root>\shims\scoop.cmd.
    $shimRoot = Split-Path -Parent (Split-Path -Parent $ScoopPath)
    $root = $env:SCOOP
    if (-not $root) { $root = Get-ResikScoopConfigValue -ShimRoot $shimRoot -Name 'root_path' }
    if (-not $root) { $root = $shimRoot }

    $cache = $env:SCOOP_CACHE
    if (-not $cache) { $cache = Get-ResikScoopConfigValue -ShimRoot $shimRoot -Name 'cache_path' }
    if (-not $cache) { $cache = Join-Path $root 'cache' }

    $apps = Join-Path $root 'apps'
    foreach ($path in @($root, $apps, $cache)) {
        $issue = Get-ResikPathSafetyIssue -Path $path
        if ($issue) { throw "Refusing to clean Scoop: $issue" }
    }
    if (-not (Test-Path -LiteralPath $apps -PathType Container)) {
        throw "Scoop's apps folder was not found at $apps."
    }

    [pscustomobject]@{
        Root  = [System.IO.Path]::GetFullPath($root)
        Apps  = [System.IO.Path]::GetFullPath($apps)
        Cache = [System.IO.Path]::GetFullPath($cache)
    }
}

function Get-ResikScoopOldVersion {
    # Emits the folders that "scoop cleanup *" would remove, as far as can be
    # told from the filesystem, and counts apps that could not be checked.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $AppsPath
    )

    $unknown = 0
    $folders = New-Object System.Collections.Generic.List[string]
    foreach ($app in @(Get-ChildItem -LiteralPath $AppsPath -Directory -ErrorAction SilentlyContinue)) {
        $versions = @(Get-ChildItem -LiteralPath $app.FullName -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne 'current' })
        if ($versions.Count -eq 0) { continue }

        $current = Get-Item -LiteralPath (Join-Path $app.FullName 'current') -Force -ErrorAction SilentlyContinue
        $isLink = $null -ne $current -and ($current.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
        $target = if ($isLink) { @(Get-ResikOptionalProperty $current 'Target') | Select-Object -First 1 } else { $null }
        if (-not $target) {
            if ($versions.Count -gt 1 -or $null -eq $current) { $unknown++ }
            continue
        }
        $currentVersion = Split-Path -Leaf ([string]$target).TrimEnd('\')
        foreach ($version in $versions) {
            if ($version.Name -ne $currentVersion) { $folders.Add($version.FullName) }
        }
    }

    [pscustomobject]@{
        Folders     = $folders.ToArray()
        UnknownApps = $unknown
    }
}

function Invoke-ResikScoopDetection {
    $scoop = Resolve-ResikExecutable -Name 'scoop' -Extension '.cmd'
    if (-not $scoop) {
        return [pscustomobject]@{ Available = $false; Details = 'Scoop was not found on PATH.' }
    }
    [pscustomobject]@{ Available = $true; Details = $scoop }
}

function Invoke-ResikScoopAppsAnalysis {
    $location = Get-ResikScoopLocation -ScoopPath (Get-ResikScoopExecutable)
    $old = Get-ResikScoopOldVersion -AppsPath $location.Apps
    $size = Measure-ResikPathSet -Path $old.Folders
    $details = "$($old.Folders.Count) old version folder(s) in $($location.Apps)"
    if ($old.UnknownApps -gt 0) { $details += "; $($old.UnknownApps) app(s) could not be checked" }
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikScoopAppsCleanup {
    $scoop = Get-ResikScoopExecutable
    $location = Get-ResikScoopLocation -ScoopPath $scoop
    $old = Get-ResikScoopOldVersion -AppsPath $location.Apps
    if ($old.Folders.Count -eq 0 -and $old.UnknownApps -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'No old app versions; nothing to clean.' }
    }
    $outcome = Invoke-ResikMeasuredCommand -FilePath $scoop -ArgumentList @('cleanup', '*') `
        -MeasurePath $old.Folders -FreeSpacePath $location.Apps -TimeoutSeconds 1800
    # Scoop stops at the first folder it cannot delete (an app that is running).
    $left = @($old.Folders | Where-Object { Test-Path -LiteralPath $_ })
    if ($outcome.Status -eq 'Success' -and $left.Count -gt 0) {
        $outcome.Status = 'PartialSuccess'
        $outcome.Details += "; $($left.Count) old version folder(s) remain, possibly because the app is running"
    }
    $outcome
}

function Invoke-ResikScoopCacheAnalysis {
    $location = Get-ResikScoopLocation -ScoopPath (Get-ResikScoopExecutable)
    $size = Measure-ResikPathSet -Path @($location.Cache)
    $details = "$($location.Cache) ($($size.Files) files)"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikScoopCacheCleanup {
    $scoop = Get-ResikScoopExecutable
    $location = Get-ResikScoopLocation -ScoopPath $scoop
    $files = @(Get-ChildItem -LiteralPath $location.Cache -File -Force -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No downloads in $($location.Cache); nothing to clean." }
    }
    # Scoop reports success even when it cannot delete a file, hence ExpectEmpty.
    Invoke-ResikMeasuredCommand -FilePath $scoop -ArgumentList @('cache', 'rm', '*') `
        -MeasurePath @($location.Cache) -TimeoutSeconds 1800 -ExpectEmpty
}

function New-ResikScoopAppsTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'scoop-apps' -Name 'Scoop old app versions' -Category Developer -RiskLevel Low `
        -Description ('Removes old versions of installed Scoop apps by running "scoop cleanup *". The current ' +
            'version of every app and its persisted data are kept, but you can no longer switch back to an old ' +
            'version with "scoop reset". Global apps are not cleaned.') `
        -Detect { Invoke-ResikScoopDetection } `
        -Analyze { Invoke-ResikScoopAppsAnalysis } `
        -Clean { Invoke-ResikScoopAppsCleanup }
}

function New-ResikScoopCacheTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'scoop-cache' -Name 'Scoop download cache' -Category Developer -RiskLevel Low `
        -Description ('Removes downloaded installers from the Scoop cache by running "scoop cache rm *". ' +
            'Installed apps are not touched; Scoop downloads installers again if you reinstall an app.') `
        -Detect { Invoke-ResikScoopDetection } `
        -Analyze { Invoke-ResikScoopCacheAnalysis } `
        -Clean { Invoke-ResikScoopCacheCleanup }
}
