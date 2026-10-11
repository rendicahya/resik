# Hugging Face Hub cache target
# (https://huggingface.co/docs/huggingface_hub/guides/manage-cache).
#
# Uses the hf CLI, verified against huggingface_hub 2.2.0:
#   hf cache prune --dry-run --cache-dir <dir> --format json   read-only preview
#   hf cache prune --yes --cache-dir <dir> --format json       removes them
# "hf cache prune" removes revisions that no branch or tag refers to, partial
# downloads (*.incomplete), and shared blobs that no cached repo uses. Models
# and datasets that a branch or tag still points to are kept. --format json
# is passed because the default output depends on whether hf thinks an AI
# agent is running it. In JSON mode the preview prints one line such as
# {"dry_run": true, "revisions": 1, "incomplete": 1, "shared_blobs": 0,
# "size": "3.5K"} (sizes in powers of 1000), and nothing when there is
# nothing to prune.
#
# The cache directory is resolved the way huggingface_hub's constants.py does:
# HF_HUB_CACHE, else HUGGINGFACE_HUB_CACHE, else <HF_HOME>\hub, where HF_HOME
# defaults to <XDG_CACHE_HOME or ~\.cache>\huggingface. The validated path is
# passed with --cache-dir so hf cleans exactly what Resik checked. Tokens in
# HF_HOME are outside the hub cache and are never touched.

function Get-ResikHuggingFaceExecutable {
    $hf = Resolve-ResikExecutable -Name 'hf'
    if (-not $hf) { throw 'hf (the Hugging Face CLI) was not found on PATH.' }
    $hf
}

function Get-ResikHuggingFaceCacheDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $configured = $env:HF_HUB_CACHE
    if (-not $configured) { $configured = $env:HUGGINGFACE_HUB_CACHE }
    if (-not $configured) {
        $hfHome = $env:HF_HOME
        if (-not $hfHome) {
            $cacheHome = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } else { Join-Path $env:USERPROFILE '.cache' }
            $hfHome = Join-Path $cacheHome 'huggingface'
        }
        $configured = Join-Path $hfHome 'hub'
    }

    $cacheDir = (Expand-ResikConfiguredPath -Path $configured).TrimEnd('\')
    $issue = Get-ResikPathSafetyIssue -Path $cacheDir
    if ($issue) { throw "Refusing to clean the Hugging Face cache: $issue" }
    if ((Test-Path -LiteralPath $cacheDir) -and -not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        throw "Refusing to clean '$cacheDir': it is not a directory."
    }
    [System.IO.Path]::GetFullPath($cacheDir)
}

function ConvertFrom-ResikHuggingFaceSize {
    # Parses hf's size text ("500.0", "3.5K", "2.5M", "1.9G"), which uses
    # powers of 1000. The result is approximate because hf rounds it.
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)]
        [string] $Text
    )

    if ($Text.Trim() -notmatch '^(\d+(?:\.\d+)?)([KMGTPEZ]?)$') {
        throw "Unexpected size '$Text' from hf."
    }
    $power = 'KMGTPEZ'.IndexOf($Matches[2]) + 1
    if (-not $Matches[2]) { $power = 0 }
    [long]([double]::Parse($Matches[1], [System.Globalization.CultureInfo]::InvariantCulture) * [math]::Pow(1000, $power))
}

function Get-ResikHuggingFacePrunePreview {
    # Runs the read-only preview. Returns Revisions, Incomplete, SharedBlobs,
    # and Bytes (approximate), all zero when there is nothing to prune.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $HfPath,

        [Parameter(Mandatory)]
        [string] $CacheDir
    )

    $run = Invoke-ResikNativeCommand -FilePath $HfPath -TimeoutSeconds 300 `
        -ArgumentList @('cache', 'prune', '--dry-run', '--cache-dir', $CacheDir, '--format', 'json')
    if ($run.Status -ne 'Success') {
        throw (Get-ResikNativeCommandFailure $run)
    }
    $json = @($run.StdOut -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') }) | Select-Object -Last 1
    if (-not $json) {
        if ($run.StdOut.Trim()) { throw "Unexpected output from '$($run.Command)'." }
        return [pscustomobject]@{ Revisions = 0; Incomplete = 0; SharedBlobs = 0; Bytes = [long]0 }
    }
    try {
        $preview = $json | ConvertFrom-Json
    }
    catch {
        throw "Unexpected output from '$($run.Command)'."
    }
    if ((Get-ResikOptionalProperty $preview 'dry_run') -ne $true -or $null -eq (Get-ResikOptionalProperty $preview 'size')) {
        throw "Unexpected output from '$($run.Command)'."
    }
    [pscustomobject]@{
        Revisions   = [int](Get-ResikOptionalProperty $preview 'revisions')
        Incomplete  = [int](Get-ResikOptionalProperty $preview 'incomplete')
        SharedBlobs = [int](Get-ResikOptionalProperty $preview 'shared_blobs')
        Bytes       = ConvertFrom-ResikHuggingFaceSize -Text ([string]$preview.size)
    }
}

function Invoke-ResikHuggingFaceDetection {
    $hf = Resolve-ResikExecutable -Name 'hf'
    if (-not $hf) {
        return [pscustomobject]@{ Available = $false; Details = 'hf (the Hugging Face CLI) was not found on PATH.' }
    }
    [pscustomobject]@{ Available = $true; Details = $hf }
}

function Invoke-ResikHuggingFaceAnalysis {
    $hf = Get-ResikHuggingFaceExecutable
    $cacheDir = Get-ResikHuggingFaceCacheDirectory
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return [pscustomobject]@{ EstimatedBytes = 0; Details = "No cache at $cacheDir" }
    }
    $preview = Get-ResikHuggingFacePrunePreview -HfPath $hf -CacheDir $cacheDir
    $details = "$cacheDir ($($preview.Revisions) unused revision(s), $($preview.Incomplete) incomplete download(s)"
    if ($preview.SharedBlobs -gt 0) { $details += ", $($preview.SharedBlobs) unused shared file(s)" }
    [pscustomobject]@{ EstimatedBytes = $preview.Bytes; Details = "$details)" }
}

function Invoke-ResikHuggingFaceCleanup {
    $hf = Get-ResikHuggingFaceExecutable
    $cacheDir = Get-ResikHuggingFaceCacheDirectory
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No cache at $cacheDir; nothing to clean." }
    }
    $preview = Get-ResikHuggingFacePrunePreview -HfPath $hf -CacheDir $cacheDir
    if ($preview.Revisions + $preview.Incomplete + $preview.SharedBlobs -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'No unused revisions or incomplete downloads; nothing to clean.' }
    }
    # The whole cache is measured, because the revisions hf removes share
    # files with the ones it keeps.
    Invoke-ResikMeasuredCommand -FilePath $hf -MeasurePath @($cacheDir) -TimeoutSeconds 1800 `
        -ArgumentList @('cache', 'prune', '--yes', '--cache-dir', $cacheDir, '--format', 'json')
}

function New-ResikHuggingFaceTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'huggingface' -Name 'Hugging Face unused revisions' -Category Developer -RiskLevel Low `
        -Description ('Removes cached model and dataset revisions that no branch or tag refers to anymore, and ' +
            'interrupted downloads, by running "hf cache prune". The revisions your branches and tags point to ' +
            'are kept, and so are your login tokens. A removed revision is downloaded again if you ask for it ' +
            'by its commit hash.') `
        -Detect { Invoke-ResikHuggingFaceDetection } `
        -Analyze { Invoke-ResikHuggingFaceAnalysis } `
        -Clean { Invoke-ResikHuggingFaceCleanup }
}
