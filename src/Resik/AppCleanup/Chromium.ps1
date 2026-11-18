# Chromium-based browsers and apps: Microsoft Edge, Google Chrome, Brave,
# Comet, and the apps built on Electron or CEF (the Claude desktop app,
# ClickUp, Visual Studio Code, Google Play Games).
#
# None of them has a command-line option for clearing caches, so Resik empties
# the cache folders itself. A browser keeps one folder per profile (a folder in
# User Data with a Preferences file) and a few shared folders in User Data; an
# app keeps the same folders directly in its data folder. Each browser is split
# into parts that can be chosen separately:
#   <browser>-cache            <profile>\Cache: "Cached images and files"
#   <browser>-code-cache       <profile>\Code Cache: compiled JavaScript/WASM
#   <browser>-gpu-cache        <profile>\GPUCache and Dawn caches, and the
#                              shared ShaderCache, GrShaderCache,
#                              GraphiteDawnCache, GPUPersistentCache
#   <browser>-service-workers  <profile>\Service Worker: offline copies of web
#                              apps and the service workers sites installed
#                              (Medium and -ExplicitOnly: offline use and site
#                              push notifications stop until the site is
#                              visited again)
# An app has one target, <app>-cache, with the first three parts (and, for VS
# Code, CachedData and CachedExtensionVSIXs, which VS Code rebuilds or
# downloads again). History, cookies, passwords, site storage, extensions, and
# settings are never touched.
#
# The browser or app keeps these files open, so while it runs Resik asks to
# close it (Core/Process.ps1). Chromium keeps User Data\lockfile locked while it
# runs, which finds the browser wherever it is installed; process names are
# matched by path where they are ambiguous (chrome.exe is also Playwright's
# Chromium, and claude.exe is also the Claude Code CLI).

function Get-ResikChromiumPartId {
    'cache', 'code-cache', 'gpu-cache', 'service-workers'
}

function Get-ResikChromiumBrowserId {
    'edge', 'chrome', 'brave', 'comet'
}

function Get-ResikChromiumAppId {
    'claude-desktop', 'clickup', 'vscode', 'play-games'
}

function Get-ResikChromiumPart {
    # The folders of one part; ProfileFolders are inside each profile,
    # SharedFolders directly in User Data.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Id
    )
    switch ($Id) {
        'cache' {
            [pscustomobject]@{ Id = $Id; Title = 'cached images and files'; RiskLevel = 'Low'
                ProfileFolders = @('Cache'); SharedFolders = @()
                What = 'cached web pages, images, and scripts (the Cache folder of every profile), like "Cached images and files" in its settings. Pages load a little slower until the cache fills again' }
        }
        'code-cache' {
            [pscustomobject]@{ Id = $Id; Title = 'compiled script cache'; RiskLevel = 'Low'
                ProfileFolders = @('Code Cache'); SharedFolders = @()
                What = 'compiled JavaScript and WebAssembly (the Code Cache folder of every profile). Sites compile their scripts again' }
        }
        'gpu-cache' {
            [pscustomobject]@{ Id = $Id; Title = 'GPU shader cache'; RiskLevel = 'Low'
                ProfileFolders = @('GPUCache', 'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache')
                SharedFolders = @('ShaderCache', 'GrShaderCache', 'GraphiteDawnCache', 'GPUPersistentCache')
                What = 'compiled GPU shaders (GPUCache and the Dawn caches of every profile, and the shared shader caches). They are rebuilt as needed' }
        }
        'service-workers' {
            [pscustomobject]@{ Id = $Id; Title = 'service worker data'; RiskLevel = 'Medium'
                ProfileFolders = @('Service Worker'); SharedFolders = @()
                What = 'service worker data (the Service Worker folder of every profile): offline copies of web apps and the service workers sites installed. Sites install them again when you visit; until then, offline use and push notifications from those sites stop' }
        }
        default { throw "Unknown Chromium part '$Id'." }
    }
}

function Get-ResikChromiumSpec {
    # Describes one browser or app: where its data is and how to find it
    # running. Built on each call so tests can move the data folders.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Id
    )
    $local = Get-ResikLocalAppDataPath
    $roaming = Get-ResikRoamingAppDataPath
    $tabs = 'Open tabs are closed without asking ({0} offers to restore them), and downloads in progress stop.'
    switch ($Id) {
        'edge' {
            $root = Get-ResikEdgeUserDataPath
            [pscustomobject]@{ Id = $Id; Name = 'Microsoft Edge'; Category = 'Windows'; Browser = $true; Root = $root
                App = New-ResikAppSpec -DisplayName 'Microsoft Edge' -ProcessName 'msedge' -LockFile (Join-Path $root 'lockfile')
                Consequence = $tabs -f 'Edge'; ExtraFolders = @() }
        }
        'chrome' {
            $root = Join-Path $local 'Google\Chrome\User Data'
            [pscustomobject]@{ Id = $Id; Name = 'Google Chrome'; Category = 'Apps'; Browser = $true; Root = $root
                App = New-ResikAppSpec -DisplayName 'Google Chrome' -ProcessName 'chrome' -LockFile (Join-Path $root 'lockfile') `
                    -PathLike @('*\Google\Chrome\Application\chrome.exe', '*\scoop\apps\googlechrome\*')
                Consequence = $tabs -f 'Chrome'; ExtraFolders = @() }
        }
        'brave' {
            $root = Join-Path $local 'BraveSoftware\Brave-Browser\User Data'
            [pscustomobject]@{ Id = $Id; Name = 'Brave'; Category = 'Apps'; Browser = $true; Root = $root
                App = New-ResikAppSpec -DisplayName 'Brave' -ProcessName 'brave' -LockFile (Join-Path $root 'lockfile')
                Consequence = $tabs -f 'Brave'; ExtraFolders = @() }
        }
        'comet' {
            $root = Join-Path $local 'Perplexity\Comet\User Data'
            [pscustomobject]@{ Id = $Id; Name = 'Comet'; Category = 'Apps'; Browser = $true; Root = $root
                App = New-ResikAppSpec -DisplayName 'Comet' -ProcessName 'comet' -LockFile (Join-Path $root 'lockfile')
                Consequence = $tabs -f 'Comet'; ExtraFolders = @() }
        }
        'claude-desktop' {
            $root = Join-Path $roaming 'Claude'
            [pscustomobject]@{ Id = $Id; Name = 'Claude desktop app'; Category = 'Apps'; Browser = $false; Root = $root
                App = New-ResikAppSpec -DisplayName 'the Claude desktop app' -ProcessName 'claude' -LockFile (Join-Path $root 'lockfile') `
                    -PathLike @('*\WindowsApps\Claude_*', '*\AnthropicClaude\*')
                Consequence = 'Chats are kept on your account; a reply being written stops.'; ExtraFolders = @() }
        }
        'clickup' {
            $root = Join-Path $roaming 'ClickUp'
            [pscustomobject]@{ Id = $Id; Name = 'ClickUp'; Category = 'Apps'; Browser = $false; Root = $root
                App = New-ResikAppSpec -DisplayName 'ClickUp' -ProcessName 'ClickUp' -LockFile (Join-Path $root 'lockfile')
                Consequence = 'Unsaved edits in it may be lost.'; ExtraFolders = @() }
        }
        'vscode' {
            $root = Join-Path $roaming 'Code'
            [pscustomobject]@{ Id = $Id; Name = 'Visual Studio Code'; Category = 'Apps'; Browser = $false; Root = $root
                App = New-ResikAppSpec -DisplayName 'Visual Studio Code' -ProcessName 'Code' -LockFile (Join-Path $root 'lockfile')
                Consequence = 'Its terminals and running tasks stop, and unsaved changes may be lost.'
                ExtraFolders = @('CachedData', 'CachedExtensionVSIXs') }
        }
        'play-games' {
            $root = Join-Path $local 'Google\Play Games\CEF\cache'
            [pscustomobject]@{ Id = $Id; Name = 'Google Play Games'; Category = 'Apps'; Browser = $false; Root = $root
                App = New-ResikAppSpec -DisplayName 'Google Play Games' -ProcessName '*' -LockFile (Join-Path $root 'lockfile') `
                    -PathLike @('*\Google\Play Games\*')
                Consequence = 'A running game stops without saving.'; ExtraFolders = @() }
        }
        default { throw "Unknown Chromium browser or app '$Id'." }
    }
}

function Get-ResikChromiumProfileFolder {
    # Emits the profile folders in a browser's User Data folder, links left out.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )
    foreach ($folder in @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if ($folder.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        if (Test-Path -LiteralPath (Join-Path $folder.FullName 'Preferences') -PathType Leaf) { $folder.FullName }
    }
}

function Get-ResikChromiumFolder {
    # Emits the existing, link-free folders of the given parts.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Spec,

        [Parameter(Mandatory)]
        [string[]] $PartId
    )
    $root = Get-ResikCheckedAppRoot -Root $Spec.Root -AppName $Spec.Name
    $parts = @($PartId | ForEach-Object { Get-ResikChromiumPart -Id $_ })
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $profiles = if ($Spec.Browser) { @(Get-ResikChromiumProfileFolder -Root $root) } else { @($root) }
    foreach ($part in $parts) {
        foreach ($name in $part.SharedFolders) { $candidates.Add((Join-Path $root $name)) }
    }
    foreach ($profileFolder in $profiles) {
        foreach ($part in $parts) {
            foreach ($name in $part.ProfileFolders) { $candidates.Add((Join-Path $profileFolder $name)) }
        }
    }
    foreach ($name in $Spec.ExtraFolders) { $candidates.Add((Join-Path $root $name)) }
    Get-ResikExistingFolder -Path @($candidates | Select-Object -Unique) -Base $root
}

function Get-ResikChromiumTargetPart {
    # The parts a target covers: one for a browser part, the caches for an app.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Spec,

        [string] $PartId = ''
    )
    if ($Spec.Browser) { $PartId } else { 'cache', 'code-cache', 'gpu-cache' }
}

function Get-ResikChromiumLabel {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Spec,

        [string] $PartId = ''
    )
    if ($Spec.Browser) { "$($Spec.Name) $((Get-ResikChromiumPart -Id $PartId).Title)" } else { "the $($Spec.Name) cache" }
}

function Invoke-ResikChromiumDetection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SpecId
    )
    $spec = Get-ResikChromiumSpec -Id $SpecId
    Invoke-ResikAppRootDetection -Root $spec.Root -AppName $spec.Name
}

function Invoke-ResikChromiumAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SpecId,

        [string] $PartId = ''
    )
    $spec = Get-ResikChromiumSpec -Id $SpecId
    $folders = @(Get-ResikChromiumFolder -Spec $spec -PartId @(Get-ResikChromiumTargetPart -Spec $spec -PartId $PartId))
    Invoke-ResikAppFolderAnalysis -Path $folders -Where $spec.Root -App $spec.App
}

function Invoke-ResikChromiumCleanup {
    # Finds the folders again instead of trusting the analysis.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SpecId,

        [string] $PartId = '',

        [object] $Context = $null
    )
    $spec = Get-ResikChromiumSpec -Id $SpecId
    $folders = @(Get-ResikChromiumFolder -Spec $spec -PartId @(Get-ResikChromiumTargetPart -Spec $spec -PartId $PartId))
    Invoke-ResikAppFolderCleanup -Path $folders -Where $spec.Root -Label (Get-ResikChromiumLabel -Spec $spec -PartId $PartId) `
        -App $spec.App -Context $Context -Consequence $spec.Consequence
}

function New-ResikChromiumTarget {
    # One target: a part of a browser (PartId), or an app's caches.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z-]+$')]
        [string] $SpecId,

        [ValidatePattern('^[a-z-]*$')]
        [string] $PartId = ''
    )
    $spec = Get-ResikChromiumSpec -Id $SpecId
    $kept = 'History, cookies, passwords, site storage, extensions, and settings are kept.'
    if ($spec.Browser) {
        $part = Get-ResikChromiumPart -Id $PartId
        $id = "$SpecId-$PartId"
        $name = "$($spec.Name) $($part.Title)"
        $risk = $part.RiskLevel
        $description = "Deletes $($spec.Name)'s $($part.What). $kept"
    }
    else {
        $id = "$SpecId-cache"
        $name = "$($spec.Name) cache"
        $risk = 'Low'
        $extra = if (@($spec.ExtraFolders).Count -gt 0) { ", and $($spec.ExtraFolders -join ' and ')" } else { '' }
        $description = "Deletes $($spec.Name)'s cached web files, compiled scripts, and GPU shader caches$extra. " +
            'They are rebuilt or downloaded again. Sign-in, settings, and app data are kept.'
    }
    $description += " If $($spec.Name) is running, Resik asks to close it first."
    # Service worker data is more than a cache, so --all never picks it.
    $explicitOnly = $spec.Browser -and $PartId -eq 'service-workers'
    if ($explicitOnly) { $description += ' Never chosen by --all or "select all".' }

    # The scriptblocks are created from text holding only these validated IDs,
    # so they call the module's functions in whatever scope runs the target.
    $arguments = "-SpecId '$SpecId' -PartId '$PartId'"
    New-ResikTarget -Id $id -Name $name -Category $spec.Category -RiskLevel $risk -Description $description -ExplicitOnly:$explicitOnly `
        -Detect ([scriptblock]::Create("Invoke-ResikChromiumDetection -SpecId '$SpecId'")) `
        -Analyze ([scriptblock]::Create("Invoke-ResikChromiumAnalysis $arguments")) `
        -Clean ([scriptblock]::Create("param(`$Context) Invoke-ResikChromiumCleanup $arguments -Context `$Context"))
}

function New-ResikChromiumBrowserTarget {
    # Emits one target per part of the browser.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates in-memory objects only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $BrowserId
    )
    foreach ($part in Get-ResikChromiumPartId) { New-ResikChromiumTarget -SpecId $BrowserId -PartId $part }
}
