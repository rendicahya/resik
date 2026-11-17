# Deno cache target (https://docs.deno.com/runtime/reference/cli/clean/).
#
#   deno info --json    read-only; "denoDir" is the cache folder (DENO_DIR)
#   deno clean          removes the whole DENO_DIR folder
#
# DENO_DIR holds downloaded remote modules, npm packages, and compiled
# TypeScript, but also the localStorage data of Deno scripts, so the target is
# Medium risk. Scripts installed with "deno install -g" live elsewhere and are
# kept. Commands run in the user profile folder, so a deno.json in the folder
# Resik was started in is not read.
# Verified against Deno's documentation and source only: Deno was not
# installed on the development machine.

function Get-ResikDenoExecutable {
    $deno = Resolve-ResikExecutable -Name 'deno'
    if (-not $deno) { throw 'deno was not found on PATH.' }
    $deno
}

function Get-ResikDenoCacheDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $DenoPath
    )

    $run = Invoke-ResikNativeCommand -FilePath $DenoPath -ArgumentList @('info', '--json') -TimeoutSeconds 60 `
        -WorkingDirectory (Get-ResikToolWorkingDirectory)
    if ($run.Status -ne 'Success') {
        throw (Get-ResikNativeCommandFailure $run)
    }
    try {
        $info = $run.StdOut | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Unexpected output from '$($run.Command)'."
    }
    $denoDir = Get-ResikOptionalProperty -InputObject $info -Name 'denoDir'
    if (-not ($denoDir -is [string]) -or -not $denoDir.Trim()) {
        throw "Unexpected output from '$($run.Command)'."
    }
    $denoDir = $denoDir.Trim().TrimEnd('\', '/').Replace('/', '\')
    $issue = Get-ResikPathSafetyIssue -Path $denoDir
    if ($issue) { throw "Refusing to clean DENO_DIR: $issue" }
    $denoDir
}

function Invoke-ResikDenoDetection {
    $deno = Resolve-ResikExecutable -Name 'deno'
    if (-not $deno) {
        return [pscustomobject]@{ Available = $false; Details = 'deno was not found on PATH.' }
    }
    [pscustomobject]@{ Available = $true; Details = $deno }
}

function Invoke-ResikDenoAnalysis {
    $denoDir = Get-ResikDenoCacheDirectory -DenoPath (Get-ResikDenoExecutable)
    $size = Measure-ResikPathSet -Path @($denoDir)
    $details = "$denoDir ($($size.Files) files)"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikDenoCleanup {
    # Re-reads and re-validates the folder instead of trusting the analysis.
    $deno = Get-ResikDenoExecutable
    $denoDir = Get-ResikDenoCacheDirectory -DenoPath $deno
    if (-not (Test-Path -LiteralPath $denoDir -PathType Container)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No cache at $denoDir; nothing to clean." }
    }
    Invoke-ResikMeasuredCommand -FilePath $deno -ArgumentList @('clean') `
        -MeasurePath @($denoDir) -TimeoutSeconds 1800 -WorkingDirectory (Get-ResikToolWorkingDirectory)
}

function New-ResikDenoTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'deno' -Name 'Deno cache' -Category Developer -RiskLevel Medium `
        -Description ('Removes Deno''s cache folder (DENO_DIR) by running "deno clean": downloaded modules, ' +
            'npm packages, compiled TypeScript, and the localStorage data of Deno scripts. Projects and ' +
            'installed scripts are not touched, but scripts download their dependencies again and fail while offline.') `
        -Detect { Invoke-ResikDenoDetection } `
        -Analyze { Invoke-ResikDenoAnalysis } `
        -Clean { Invoke-ResikDenoCleanup }
}
