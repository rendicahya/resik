# node-gyp target (node-gyp): downloaded Node.js headers and import libraries.
#
# Verified against node-gyp's source (bin/node-gyp.js, lib/remove.js) only.
# node-gyp keeps one folder per Node.js version in its devdir: --devdir or
# npm_config_devdir when set, otherwise env-paths('node-gyp').cache, which is
# %LOCALAPPDATA%\node-gyp\Cache on Windows. `node-gyp remove <version>` deletes
# that version's folder (fs.rm recursive), but node-gyp is usually only bundled
# inside npm and not on PATH, so Resik deletes the same folders itself: only
# folders named like a version (26.1.0). node-gyp downloads them again the next
# time a native module is built.

function Get-ResikNodeGypCachePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $configured = [Environment]::GetEnvironmentVariable('npm_config_devdir')
    if (-not [string]::IsNullOrWhiteSpace($configured)) { return Expand-ResikConfiguredPath -Path $configured }
    Join-Path (Get-ResikLocalAppDataPath) 'node-gyp\Cache'
}

function Get-ResikNodeGypFolder {
    # The version folders, after the safety checks.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $root = Get-ResikCheckedAppRoot -Root (Get-ResikNodeGypCachePath) -AppName 'node-gyp'
    $candidates = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } | Sort-Object Name | ForEach-Object { $_.FullName })
    Get-ResikExistingFolder -Path $candidates -Base $root
}

function New-ResikNodeGypTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'node-gyp' -Name 'node-gyp headers' -Category Developer -RiskLevel Low `
        -Description ('Deletes the Node.js headers node-gyp downloaded to build native modules (one folder per ' +
            'Node.js version in %LOCALAPPDATA%\node-gyp\Cache), like node-gyp remove. They are downloaded again ' +
            'when needed.') `
        -Detect { Invoke-ResikAppRootDetection -Root (Get-ResikNodeGypCachePath) -AppName 'node-gyp' } `
        -Analyze { Invoke-ResikAppFolderAnalysis -Path @(Get-ResikNodeGypFolder) -Where (Get-ResikNodeGypCachePath) } `
        -Clean {
            Invoke-ResikAppFolderCleanup -Path @(Get-ResikNodeGypFolder) -Where (Get-ResikNodeGypCachePath) `
                -Label 'the node-gyp headers' -RemoveFolder
        }
}
