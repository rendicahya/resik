# Yarn Classic cache target (https://classic.yarnpkg.com/en/docs/cli/cache).
#
# Uses Yarn's own commands:
#   yarn --version      read-only; only Yarn 1 (Classic) is supported
#   yarn cache dir      read-only; prints the global cache directory
#   yarn cache clean    clears the global cache
# Yarn 2 and later keep a cache per project and clean a different one
# depending on the folder they run in, so they are reported as not supported.
# All commands run in the user profile folder, so a project's .yarnrc,
# .npmrc, or Corepack "packageManager" field in the current folder cannot
# change which Yarn runs or which cache is read and cleared.
# Verified against Yarn Classic's documentation only: Yarn was not installed on
# the development machine. Yarn ships as yarn.cmd (npm, Corepack, the
# installer, Scoop), so only fixed arguments are passed to it.

function Get-ResikYarnExecutable {
    Resolve-ResikExecutable -Name 'yarn' -Extension '.cmd'
}

function Get-ResikYarnOutputLine {
    # Runs yarn with fixed arguments and returns its single line of output.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $YarnPath,

        [Parameter(Mandatory)]
        [string[]] $ArgumentList
    )

    $run = Invoke-ResikNativeCommand -FilePath $YarnPath -ArgumentList $ArgumentList -TimeoutSeconds 60 `
        -WorkingDirectory (Get-ResikToolWorkingDirectory)
    if ($run.Status -ne 'Success') {
        throw (Get-ResikNativeCommandFailure $run)
    }
    $lines = @($run.StdOut -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -ne 1) {
        throw "Unexpected output from '$($run.Command)'."
    }
    $lines[0].Trim()
}

function Get-ResikYarnCacheDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $YarnPath
    )

    $cacheDir = Get-ResikYarnOutputLine -YarnPath $YarnPath -ArgumentList @('cache', 'dir')
    $issue = Get-ResikPathSafetyIssue -Path $cacheDir
    if ($issue) { throw "Refusing to clean the Yarn cache: $issue" }
    $cacheDir
}

function Invoke-ResikYarnDetection {
    $yarn = Get-ResikYarnExecutable
    if (-not $yarn) {
        return [pscustomobject]@{ Available = $false; Details = 'yarn was not found on PATH.' }
    }
    $version = Get-ResikYarnOutputLine -YarnPath $yarn -ArgumentList @('--version')
    if ($version -notmatch '^1\.') {
        return [pscustomobject]@{
            Available = $false
            Details   = "Yarn $version keeps its cache per project; only Yarn 1 (Classic) is supported."
        }
    }
    [pscustomobject]@{ Available = $true; Details = "$yarn (Yarn $version)" }
}

function Invoke-ResikYarnAnalysis {
    $yarn = Get-ResikYarnExecutable
    if (-not $yarn) { throw 'yarn was not found on PATH.' }
    $cacheDir = Get-ResikYarnCacheDirectory -YarnPath $yarn
    $size = Measure-ResikPathSet -Path @($cacheDir)
    $details = "$cacheDir ($($size.Files) files)"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikYarnCleanup {
    # Re-reads and re-validates the cache folder instead of trusting the
    # earlier analysis.
    $yarn = Get-ResikYarnExecutable
    if (-not $yarn) { throw 'yarn was not found on PATH.' }
    $cacheDir = Get-ResikYarnCacheDirectory -YarnPath $yarn
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No cache at $cacheDir; nothing to clean." }
    }
    Invoke-ResikMeasuredCommand -FilePath $yarn -ArgumentList @('cache', 'clean') `
        -MeasurePath @($cacheDir) -TimeoutSeconds 1800 -WorkingDirectory (Get-ResikToolWorkingDirectory)
}

function New-ResikYarnTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'yarn' -Name 'Yarn cache' -Category Developer -RiskLevel Low `
        -Description ('Clears the global Yarn Classic (1.x) cache by running "yarn cache clean". ' +
            'node_modules folders and projects are not touched; Yarn downloads packages again when it next needs them.') `
        -Detect { Invoke-ResikYarnDetection } `
        -Analyze { Invoke-ResikYarnAnalysis } `
        -Clean { Invoke-ResikYarnCleanup }
}
