# NetBeans target (netbeans-cache): the IDE's cache folders.
#
# NetBeans keeps a cache folder per version (or user directory) in
# %LOCALAPPDATA%\NetBeans\Cache, such as Cache\28. The IDE rebuilds it (scanning
# projects again) on the next start; deleting it while the IDE is closed is the
# usual fix for a broken index. Settings live in %APPDATA%\NetBeans and are kept.
# NetBeans has no command for this, so Resik deletes the version folders
# itself. The IDE runs in java.exe started by its launcher (netbeans64.exe), so
# closing it stops the launcher's child processes too.

function Get-ResikNetBeansCachePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Get-ResikLocalAppDataPath) 'NetBeans\Cache'
}

function Get-ResikNetBeansApp {
    [CmdletBinding()]
    param()
    New-ResikAppSpec -DisplayName 'NetBeans' -ProcessName @('netbeans64', 'netbeans') -IncludeChildren
}

function Get-ResikNetBeansFolder {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $root = Get-ResikCheckedAppRoot -Root (Get-ResikNetBeansCachePath) -AppName 'NetBeans'
    $candidates = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
            Sort-Object Name | ForEach-Object { $_.FullName })
    Get-ResikExistingFolder -Path $candidates -Base $root
}

function New-ResikNetBeansTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'netbeans-cache' -Name 'NetBeans cache' -Category Developer -RiskLevel Low `
        -Description ('Deletes the NetBeans cache folders in %LOCALAPPDATA%\NetBeans\Cache (one per version). ' +
            'NetBeans rebuilds them, scanning your projects again, on its next start. Settings are kept. If ' +
            'NetBeans is running, Resik asks to close it first.') `
        -Detect { Invoke-ResikAppRootDetection -Root (Get-ResikNetBeansCachePath) -AppName 'NetBeans' } `
        -Analyze { Invoke-ResikAppFolderAnalysis -Path @(Get-ResikNetBeansFolder) -Where (Get-ResikNetBeansCachePath) -App (Get-ResikNetBeansApp) } `
        -Clean {
            param($Context)
            Invoke-ResikAppFolderCleanup -Path @(Get-ResikNetBeansFolder) -Where (Get-ResikNetBeansCachePath) `
                -Label 'the NetBeans cache' -App (Get-ResikNetBeansApp) -Context $Context `
                -Consequence 'Unsaved changes in the IDE may be lost.' -RemoveFolder
        }
}
