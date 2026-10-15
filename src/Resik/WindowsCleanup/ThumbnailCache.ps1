# Thumbnail cache target.
#
# File Explorer keeps picture and video thumbnails in thumbcache_*.db files in
# %LOCALAPPDATA%\Microsoft\Windows\Explorer; these are the files Disk
# Cleanup's "Thumbnails" item removes. There is no command for it, so Resik
# deletes only files matching thumbcache_*.db in that one folder. The icon
# cache (iconcache_*.db) and everything else there is kept. Explorer keeps
# some of these files open, and those are skipped and reported.

function Get-ResikThumbnailCachePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path (Get-ResikLocalAppDataPath) 'Microsoft\Windows\Explorer'
}

function Get-ResikThumbnailCacheFilter { 'thumbcache_*.db' }

function Invoke-ResikThumbnailCacheDetection {
    $path = Get-ResikThumbnailCachePath
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        return [pscustomobject]@{ Available = $false; Details = "No thumbnail cache folder at $path." }
    }
    [pscustomobject]@{ Available = $true; Details = $path }
}

function Invoke-ResikThumbnailCacheAnalysis {
    $path = Get-ResikThumbnailCachePath
    $issue = Get-ResikPathSafetyIssue -Path $path
    if ($issue) { throw "Refusing to clean the thumbnail cache: $issue" }
    $size = Measure-ResikDirectoryContent -Path $path -Filter (Get-ResikThumbnailCacheFilter)
    [pscustomobject]@{
        EstimatedBytes = $size.Bytes
        Details        = "$(Join-Path $path (Get-ResikThumbnailCacheFilter)) ($($size.Files) files; files File Explorer is using are kept)"
    }
}

function Invoke-ResikThumbnailCacheCleanup {
    $path = Get-ResikThumbnailCachePath
    $filter = Get-ResikThumbnailCacheFilter
    if ((Measure-ResikDirectoryContent -Path $path -Filter $filter).Files -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No thumbnail cache files in $path; nothing to clean." }
    }
    Invoke-ResikMeasuredDeletion -Path $path -Filter $filter `
        -InUseHint 'File Explorer keeps some of them open; closing Explorer windows can free more.'
}

function New-ResikThumbnailCacheTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'thumbnails' -Name 'Thumbnail cache' -Category Windows -RiskLevel Low `
        -Description ('Deletes the thumbnail cache files (thumbcache_*.db) of File Explorer. Your pictures and ' +
            'videos are not touched; Explorer creates the thumbnails again as you browse folders.') `
        -Detect { Invoke-ResikThumbnailCacheDetection } `
        -Analyze { Invoke-ResikThumbnailCacheAnalysis } `
        -Clean { Invoke-ResikThumbnailCacheCleanup }
}
