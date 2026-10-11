# uv cache target (https://docs.astral.sh/uv/concepts/cache/).
#
# Uses uv's own commands, verified against uv 0.11:
#   uv cache dir                           read-only; prints the cache directory
#   uv cache clean --cache-dir <dir>       removes the cache directory
# The validated directory is passed back with --cache-dir so uv cleans exactly
# the directory Resik checked. "uv cache size" is not used because uv marks it
# as experimental; Resik measures the directory itself.
#
# Before cleaning, the directory must pass Get-ResikPathSafetyIssue and contain
# the CACHEDIR.TAG file that uv writes to its cache root.

function Get-ResikUvExecutable {
    $uv = Resolve-ResikExecutable -Name 'uv'
    if (-not $uv) { throw 'uv was not found on PATH.' }
    $uv
}

function Get-ResikUvCacheDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $UvPath
    )

    $run = Invoke-ResikNativeCommand -FilePath $UvPath -ArgumentList @('cache', 'dir') -TimeoutSeconds 60
    if ($run.Status -ne 'Success') {
        throw (Get-ResikNativeCommandFailure $run)
    }
    $lines = @($run.StdOut -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -ne 1) {
        throw "Unexpected output from '$($run.Command)'."
    }
    $lines[0].Trim()
}

function Test-ResikCacheDirTag {
    # True when the directory holds a CACHEDIR.TAG file with the standard
    # signature (https://bford.info/cachedir/).
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $tag = Join-Path $Path 'CACHEDIR.TAG'
    if (-not (Test-Path -LiteralPath $tag -PathType Leaf)) { return $false }
    $firstLine = Get-Content -LiteralPath $tag -TotalCount 1 -ErrorAction SilentlyContinue
    "$firstLine".StartsWith('Signature: 8a477f597d28d172789f06886806bc55')
}

function Get-ResikUvCacheIssue {
    # Explains why the reported cache directory must not be cleaned, or $null.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $issue = Get-ResikPathSafetyIssue -Path $Path
    if ($issue) { return "Refusing to clean the uv cache: $issue" }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        if (-not (Test-ResikCacheDirTag -Path $Path)) {
            return "Refusing to clean '$Path': it has no CACHEDIR.TAG file, so it does not look like a uv cache."
        }
    }
    elseif (Test-Path -LiteralPath $Path) {
        return "Refusing to clean '$Path': it is not a directory."
    }
    $null
}

function Invoke-ResikUvDetection {
    $uv = Resolve-ResikExecutable -Name 'uv'
    if (-not $uv) {
        return [pscustomobject]@{ Available = $false; Details = 'uv was not found on PATH.' }
    }
    [pscustomobject]@{ Available = $true; Details = $uv }
}

function Invoke-ResikUvAnalysis {
    $uv = Get-ResikUvExecutable
    $cacheDir = Get-ResikUvCacheDirectory -UvPath $uv
    $issue = Get-ResikUvCacheIssue -Path $cacheDir
    if ($issue) { throw $issue }

    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return [pscustomobject]@{ EstimatedBytes = 0; Details = "No cache at $cacheDir" }
    }

    $size = Measure-ResikDirectory -Path $cacheDir
    $details = "$cacheDir ($($size.Files) files)"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikUvCleanup {
    # Re-reads and re-validates the cache directory instead of trusting the
    # earlier analysis, because configuration could have changed in between.
    $uv = Get-ResikUvExecutable
    $cacheDir = Get-ResikUvCacheDirectory -UvPath $uv
    $issue = Get-ResikUvCacheIssue -Path $cacheDir
    if ($issue) { throw $issue }

    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No cache at $cacheDir; nothing to clean." }
    }

    # A large cache can take a while to delete, and uv waits while another uv
    # process holds the cache.
    Invoke-ResikMeasuredCommand -FilePath $uv -ArgumentList @('cache', 'clean', '--cache-dir', $cacheDir) `
        -MeasurePath @($cacheDir) -TimeoutSeconds 1800
}

function New-ResikUvTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'uv' -Name 'uv cache' -Category Developer -RiskLevel Low `
        -Description ('Removes everything in the uv cache by running "uv cache clean". Projects and virtual ' +
            'environments are not deleted, but environments created with --link-mode=symlink point into ' +
            'the cache and stop working. uv downloads or rebuilds packages again when it next needs them.') `
        -Detect { Invoke-ResikUvDetection } `
        -Analyze { Invoke-ResikUvAnalysis } `
        -Clean { Invoke-ResikUvCleanup }
}
