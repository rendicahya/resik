# npm cache target (https://docs.npmjs.com/cli/commands/npm-cache).
#
# Uses npm's own commands, verified against npm 11:
#   npm config get cache       read-only; prints the cache directory
#   npm cache clean --force    removes <cache>\_cacache, npm's package cache
# npm derives "<cache>\_cacache" from the cache setting, so the npx cache
# (_npx) and logs (_logs) in the same folder are left alone. npm ships as
# npm.cmd, so only fixed arguments are passed to it.

function Get-ResikNpmExecutable {
    $npm = Resolve-ResikExecutable -Name 'npm' -Extension '.cmd'
    if (-not $npm) { throw 'npm was not found on PATH.' }
    $npm
}

function Get-ResikNpmCacheDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $NpmPath
    )

    $run = Invoke-ResikNativeCommand -FilePath $NpmPath -ArgumentList @('config', 'get', 'cache') -TimeoutSeconds 60
    if ($run.Status -ne 'Success') {
        throw (Get-ResikNativeCommandFailure $run)
    }
    $lines = @($run.StdOut -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -ne 1) {
        throw "Unexpected output from '$($run.Command)'."
    }
    $cacheDir = $lines[0].Trim()
    $issue = Get-ResikPathSafetyIssue -Path $cacheDir
    if ($issue) { throw "Refusing to clean the npm cache: $issue" }
    $cacheDir
}

function Invoke-ResikNpmDetection {
    $npm = Resolve-ResikExecutable -Name 'npm' -Extension '.cmd'
    if (-not $npm) {
        return [pscustomobject]@{ Available = $false; Details = 'npm was not found on PATH.' }
    }
    [pscustomobject]@{ Available = $true; Details = $npm }
}

function Invoke-ResikNpmAnalysis {
    $cacheDir = Get-ResikNpmCacheDirectory -NpmPath (Get-ResikNpmExecutable)
    $content = Join-Path $cacheDir '_cacache'
    $size = Measure-ResikPathSet -Path @($content)
    $details = "$content ($($size.Files) files)"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikNpmCleanup {
    $npm = Get-ResikNpmExecutable
    $cacheDir = Get-ResikNpmCacheDirectory -NpmPath $npm
    $content = Join-Path $cacheDir '_cacache'
    if (-not (Test-Path -LiteralPath $content -PathType Container)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No cache at $content; nothing to clean." }
    }
    Invoke-ResikMeasuredCommand -FilePath $npm -ArgumentList @('cache', 'clean', '--force') `
        -MeasurePath @($content) -TimeoutSeconds 1800
}

function New-ResikNpmTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'npm' -Name 'npm cache' -Category Developer -RiskLevel Low `
        -Description ('Removes the npm package cache (_cacache) by running "npm cache clean --force". ' +
            'node_modules folders and projects are not touched; npm downloads packages again when it next needs them.') `
        -Detect { Invoke-ResikNpmDetection } `
        -Analyze { Invoke-ResikNpmAnalysis } `
        -Clean { Invoke-ResikNpmCleanup }
}
