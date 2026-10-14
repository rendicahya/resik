# pnpm store target (https://pnpm.io/cli/store).
#
# Uses pnpm's own commands:
#   pnpm store path     read-only; prints the active store directory
#   pnpm store prune    removes packages that no project references
# Pruning keeps every package a project still uses, so the amount it frees
# cannot be known in advance and pnpm has no preview: the analysis reports the
# store's size but no estimate. Both commands run in the user profile folder,
# so a project's .npmrc in the current folder cannot change which store is
# read and pruned.
# Verified against pnpm's documentation only: pnpm was not installed on the
# development machine. pnpm is pnpm.exe (standalone, Scoop) or pnpm.cmd (npm,
# Corepack); only fixed arguments are passed to it.

function Get-ResikPnpmExecutable {
    $pnpm = Resolve-ResikExecutable -Name 'pnpm'
    if (-not $pnpm) { $pnpm = Resolve-ResikExecutable -Name 'pnpm' -Extension '.cmd' }
    $pnpm
}

function Get-ResikPnpmStoreDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $PnpmPath
    )

    $run = Invoke-ResikNativeCommand -FilePath $PnpmPath -ArgumentList @('store', 'path') -TimeoutSeconds 60 `
        -WorkingDirectory (Get-ResikToolWorkingDirectory)
    if ($run.Status -ne 'Success') {
        throw (Get-ResikNativeCommandFailure $run)
    }
    $lines = @($run.StdOut -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -ne 1) {
        throw "Unexpected output from '$($run.Command)'."
    }
    $storeDir = $lines[0].Trim()
    $issue = Get-ResikPathSafetyIssue -Path $storeDir
    if ($issue) { throw "Refusing to prune the pnpm store: $issue" }
    $storeDir
}

function Invoke-ResikPnpmDetection {
    $pnpm = Get-ResikPnpmExecutable
    if (-not $pnpm) {
        return [pscustomobject]@{ Available = $false; Details = 'pnpm was not found on PATH.' }
    }
    [pscustomobject]@{ Available = $true; Details = $pnpm }
}

function Invoke-ResikPnpmAnalysis {
    $pnpm = Get-ResikPnpmExecutable
    if (-not $pnpm) { throw 'pnpm was not found on PATH.' }
    $storeDir = Get-ResikPnpmStoreDirectory -PnpmPath $pnpm
    $size = Measure-ResikPathSet -Path @($storeDir)
    $details = "$storeDir ($(Format-ResikSize $size.Bytes) in $($size.Files) files); " +
    'pruning removes only packages no project uses, which cannot be previewed'
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $null; Details = $details }
}

function Invoke-ResikPnpmCleanup {
    $pnpm = Get-ResikPnpmExecutable
    if (-not $pnpm) { throw 'pnpm was not found on PATH.' }
    $storeDir = Get-ResikPnpmStoreDirectory -PnpmPath $pnpm
    if (-not (Test-Path -LiteralPath $storeDir -PathType Container)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No store at $storeDir; nothing to prune." }
    }
    Invoke-ResikMeasuredCommand -FilePath $pnpm -ArgumentList @('store', 'prune') `
        -MeasurePath @($storeDir) -TimeoutSeconds 1800 -WorkingDirectory (Get-ResikToolWorkingDirectory)
}

function New-ResikPnpmTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'pnpm' -Name 'pnpm store' -Category Developer -RiskLevel Low `
        -Description ('Removes packages that no project uses from the pnpm store by running "pnpm store prune". ' +
            'Packages your projects use are kept; pnpm downloads removed ones again if a project needs them.') `
        -Detect { Invoke-ResikPnpmDetection } `
        -Analyze { Invoke-ResikPnpmAnalysis } `
        -Clean { Invoke-ResikPnpmCleanup }
}
