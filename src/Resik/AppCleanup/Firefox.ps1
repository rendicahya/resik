# Firefox target (firefox-cache): Firefox's web cache.
#
# Firefox keeps each profile's disk cache in a local profile folder,
# %LOCALAPPDATA%\Mozilla\Firefox\Profiles\<profile>, apart from the profile
# itself in %APPDATA%: the network cache (cache2) and the startup cache
# (startupCache), the same folders as Zotero, which is built on Firefox. Both
# are rebuilt as needed. Bookmarks, history, cookies, passwords, extensions,
# and settings are in the profile in %APPDATA% and are not touched. Firefox
# has no command for this, so Resik empties the two folders itself, asking to
# close Firefox first. A profile created in another folder is not cleaned.
#
# Firefox is matched by path, because Playwright's Firefox is also
# firefox.exe.

function Get-ResikFirefoxProfileRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Get-ResikLocalAppDataPath) 'Mozilla\Firefox\Profiles'
}

function Get-ResikFirefoxApp {
    [CmdletBinding()]
    param()
    New-ResikAppSpec -DisplayName 'Firefox' -ProcessName 'firefox' -PathLike @(
        '*\Mozilla Firefox\firefox.exe', '*\Firefox Developer Edition\firefox.exe', '*\Firefox Nightly\firefox.exe',
        '*\scoop\apps\firefox*', '*\WindowsApps\Mozilla.Firefox*')
}

function Get-ResikFirefoxFolder {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $root = Get-ResikCheckedAppRoot -Root (Get-ResikFirefoxProfileRoot) -AppName 'Firefox'
    $candidates = foreach ($profileFolder in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
        Join-Path $profileFolder.FullName 'cache2'
        Join-Path $profileFolder.FullName 'startupCache'
    }
    Get-ResikExistingFolder -Path @($candidates) -Base $root
}

function New-ResikFirefoxTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'firefox-cache' -Name 'Firefox cache' -Category Apps -RiskLevel Low `
        -Description ('Deletes Firefox''s cached web pages, images, and scripts, and its startup cache (cache2 and ' +
            'startupCache in %LOCALAPPDATA%\Mozilla\Firefox\Profiles), like "Cached Web Content" in its settings. ' +
            'Bookmarks, history, cookies, passwords, extensions, and settings are kept. If Firefox is running, ' +
            'Resik asks to close it first.') `
        -Detect { Invoke-ResikAppRootDetection -Root (Get-ResikFirefoxProfileRoot) -AppName 'Firefox' } `
        -Analyze { Invoke-ResikAppFolderAnalysis -Path @(Get-ResikFirefoxFolder) -Where (Get-ResikFirefoxProfileRoot) -App (Get-ResikFirefoxApp) } `
        -Clean {
            param($Context)
            Invoke-ResikAppFolderCleanup -Path @(Get-ResikFirefoxFolder) -Where (Get-ResikFirefoxProfileRoot) `
                -Label 'the Firefox cache' -App (Get-ResikFirefoxApp) -Context $Context `
                -Consequence 'Open tabs are closed without asking (Firefox offers to restore them), and downloads in progress stop.'
        }
}
