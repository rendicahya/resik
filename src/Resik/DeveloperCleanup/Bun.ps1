# Bun package cache target (https://bun.com/docs/pm/cli/pm).
#
#   bun pm cache        read-only; prints the path of Bun's global cache
#   bun pm cache rm     removes everything in the global cache
#
# Both commands run in the user profile folder, so a bunfig.toml in the folder
# Resik was started in cannot change which cache is reported. Projects keep
# their node_modules; Bun downloads packages again when needed.
# Verified against Bun's documentation only: Bun was not installed on the
# development machine.

function Get-ResikBunExecutable {
    $bun = Resolve-ResikExecutable -Name 'bun'
    if (-not $bun) { throw 'bun was not found on PATH.' }
    $bun
}

function Get-ResikBunCacheDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $BunPath
    )

    $run = Invoke-ResikNativeCommand -FilePath $BunPath -ArgumentList @('pm', 'cache') -TimeoutSeconds 60 `
        -WorkingDirectory (Get-ResikToolWorkingDirectory)
    if ($run.Status -ne 'Success') {
        throw (Get-ResikNativeCommandFailure $run)
    }
    $lines = @($run.StdOut -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -ne 1) {
        throw "Unexpected output from '$($run.Command)'."
    }
    $cacheDir = $lines[0].Trim().TrimEnd('\', '/').Replace('/', '\')
    $issue = Get-ResikPathSafetyIssue -Path $cacheDir
    if ($issue) { throw "Refusing to clean the Bun cache: $issue" }
    $cacheDir
}

function Invoke-ResikBunDetection {
    $bun = Resolve-ResikExecutable -Name 'bun'
    if (-not $bun) {
        return [pscustomobject]@{ Available = $false; Details = 'bun was not found on PATH.' }
    }
    [pscustomobject]@{ Available = $true; Details = $bun }
}

function Invoke-ResikBunAnalysis {
    $cacheDir = Get-ResikBunCacheDirectory -BunPath (Get-ResikBunExecutable)
    $size = Measure-ResikPathSet -Path @($cacheDir)
    $details = "$cacheDir ($($size.Files) files)"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikBunCleanup {
    # Re-reads and re-validates the folder instead of trusting the analysis.
    $bun = Get-ResikBunExecutable
    $cacheDir = Get-ResikBunCacheDirectory -BunPath $bun
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No cache at $cacheDir; nothing to clean." }
    }
    Invoke-ResikMeasuredCommand -FilePath $bun -ArgumentList @('pm', 'cache', 'rm') `
        -MeasurePath @($cacheDir) -TimeoutSeconds 1800 -WorkingDirectory (Get-ResikToolWorkingDirectory)
}

function New-ResikBunTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'bun' -Name 'Bun package cache' -Category Developer -RiskLevel Low `
        -Description ('Removes downloaded packages from Bun''s global cache by running "bun pm cache rm". ' +
            'Projects and their node_modules folders are not touched; Bun downloads packages again when needed.') `
        -Detect { Invoke-ResikBunDetection } `
        -Analyze { Invoke-ResikBunAnalysis } `
        -Clean { Invoke-ResikBunCleanup }
}
