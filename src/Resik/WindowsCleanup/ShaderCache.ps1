# DirectX shader cache target.
#
# Windows keeps compiled DirectX shaders in %LOCALAPPDATA%\D3DSCache; this is
# the folder Disk Cleanup's "DirectX Shader Cache" item empties. There is no
# command for it, so Resik deletes the folder's contents itself with
# Remove-ResikDirectoryContent (links are not followed). Shaders in use by a
# running game or app are skipped and reported. Windows rebuilds the cache, so
# games may stutter or load slowly the first time afterwards. Driver-specific
# caches (NVIDIA DXCache, AMD DxCache) are not touched.

function Get-ResikShaderCachePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Get-ResikLocalAppDataPath) 'D3DSCache'
}

function Invoke-ResikShaderCacheDetection {
    $path = Get-ResikShaderCachePath
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        return [pscustomobject]@{ Available = $false; Details = "No DirectX shader cache at $path." }
    }
    [pscustomobject]@{ Available = $true; Details = $path }
}

function Invoke-ResikShaderCacheAnalysis {
    $path = Get-ResikShaderCachePath
    $issue = Get-ResikPathSafetyIssue -Path $path
    if ($issue) { throw "Refusing to clean the DirectX shader cache: $issue" }
    $size = Measure-ResikDirectoryContent -Path $path
    $details = "$path ($($size.Files) files)"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikShaderCacheCleanup {
    $path = Get-ResikShaderCachePath
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No DirectX shader cache at $path; nothing to clean." }
    }
    Invoke-ResikMeasuredDeletion -Path $path -InUseHint 'Close running games and 3D apps, then try again.'
}

function New-ResikShaderCacheTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'directx-shaders' -Name 'DirectX shader cache' -Category Windows -RiskLevel Low `
        -Description ('Deletes the compiled shaders Windows keeps in %LOCALAPPDATA%\D3DSCache. Windows rebuilds ' +
            'them, so games and 3D apps may load slowly or stutter the first time afterwards.') `
        -Detect { Invoke-ResikShaderCacheDetection } `
        -Analyze { Invoke-ResikShaderCacheAnalysis } `
        -Clean { Invoke-ResikShaderCacheCleanup }
}
