# Zotero target (zotero-cache): Zotero's web cache.
#
# Zotero is built on Firefox and keeps Firefox's network cache (cache2) and
# startup cache (startupCache) in its local profile,
# %LOCALAPPDATA%\Zotero\Zotero\Profiles\<profile>. Both are rebuilt as needed.
# Your library (zotero.sqlite and storage, in the Zotero data folder) and the
# profile in %APPDATA% are not touched. Zotero has no command for this, so
# Resik empties the two folders itself, asking to close Zotero first.

function Get-ResikZoteroProfileRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Get-ResikLocalAppDataPath) 'Zotero\Zotero\Profiles'
}

function Get-ResikZoteroApp {
    [CmdletBinding()]
    param()
    New-ResikAppSpec -DisplayName 'Zotero' -ProcessName 'zotero'
}

function Get-ResikZoteroFolder {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $root = Get-ResikCheckedAppRoot -Root (Get-ResikZoteroProfileRoot) -AppName 'Zotero'
    $candidates = foreach ($profileFolder in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
        Join-Path $profileFolder.FullName 'cache2'
        Join-Path $profileFolder.FullName 'startupCache'
    }
    Get-ResikExistingFolder -Path @($candidates) -Base $root
}

function New-ResikZoteroTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'zotero-cache' -Name 'Zotero cache' -Category Apps -RiskLevel Low `
        -Description ('Deletes Zotero''s web and startup caches (cache2 and startupCache in ' +
            '%LOCALAPPDATA%\Zotero\Zotero\Profiles). Your library, attachments, and settings are kept. If Zotero ' +
            'is running, Resik asks to close it first.') `
        -Detect { Invoke-ResikAppRootDetection -Root (Get-ResikZoteroProfileRoot) -AppName 'Zotero' } `
        -Analyze { Invoke-ResikAppFolderAnalysis -Path @(Get-ResikZoteroFolder) -Where (Get-ResikZoteroProfileRoot) -App (Get-ResikZoteroApp) } `
        -Clean {
            param($Context)
            Invoke-ResikAppFolderCleanup -Path @(Get-ResikZoteroFolder) -Where (Get-ResikZoteroProfileRoot) `
                -Label 'the Zotero cache' -App (Get-ResikZoteroApp) -Context $Context `
                -Consequence 'A sync or citation in progress stops.'
        }
}
