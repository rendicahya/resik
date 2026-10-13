# Composer cache target (https://getcomposer.org/doc/03-cli.md#clear-cache-clearcache-cc).
#
# Uses Composer's own commands:
#   composer global config <key> --absolute     read-only; prints a cache directory
#   composer global clear-cache --no-interaction
#                                               empties cache-vcs-dir, cache-repo-dir,
#                                               cache-files-dir, and cache-dir
# "global" runs both in COMPOSER_HOME, so a composer.json in the current
# directory cannot change which caches are read and cleared. cache-dir
# defaults to %LOCALAPPDATA%\Composer (COMPOSER_CACHE_DIR overrides it) and the
# other three default to folders inside it. A cache set to "nul" is disabled
# and skipped by Composer, and by Resik.
# Verified against Composer's documentation and its source
# (src/Composer/Command/ClearCacheCommand.php) only: Composer was not installed
# on the development machine. Composer ships as composer.bat (Composer-Setup)
# or a .cmd shim (Scoop), so only fixed arguments are passed to it.

function Get-ResikComposerExecutable {
    $composer = Resolve-ResikExecutable -Name 'composer' -Extension '.bat'
    if (-not $composer) { $composer = Resolve-ResikExecutable -Name 'composer' -Extension '.cmd' }
    $composer
}

function Get-ResikComposerCacheDirectory {
    # Emits the validated cache folders that "composer clear-cache" empties,
    # cache-dir first and without folders that are inside it.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $ComposerPath
    )

    $folders = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in @('cache-dir', 'cache-files-dir', 'cache-repo-dir', 'cache-vcs-dir')) {
        $run = Invoke-ResikNativeCommand -FilePath $ComposerPath `
            -ArgumentList @('global', 'config', $key, '--absolute', '--no-interaction') -TimeoutSeconds 60
        if ($run.Status -ne 'Success') {
            throw (Get-ResikNativeCommandFailure $run)
        }
        $lines = @($run.StdOut -split "`r?`n" | Where-Object { $_.Trim() })
        if ($lines.Count -ne 1) {
            throw "Unexpected output from '$($run.Command)'."
        }
        $value = $lines[0].Trim()
        if ($value -ieq 'nul' -or $value -eq '/dev/null') { continue }

        $path = (Expand-ResikConfiguredPath -Path $value).TrimEnd('\')
        $issue = Get-ResikPathSafetyIssue -Path $path
        if ($issue) { throw "Refusing to clean the Composer cache ($key): $issue" }
        $path = [System.IO.Path]::GetFullPath($path)

        $inside = @($folders | Where-Object {
                $path -ieq $_ -or $path.StartsWith("$_\", [System.StringComparison]::OrdinalIgnoreCase)
            })
        if ($inside.Count -eq 0) { $folders.Add($path) }
    }
    $folders
}

function Invoke-ResikComposerDetection {
    $composer = Get-ResikComposerExecutable
    if (-not $composer) {
        return [pscustomobject]@{ Available = $false; Details = 'composer was not found on PATH.' }
    }
    [pscustomobject]@{ Available = $true; Details = $composer }
}

function Invoke-ResikComposerAnalysis {
    $composer = Get-ResikComposerExecutable
    if (-not $composer) { throw 'composer was not found on PATH.' }
    $folders = @(Get-ResikComposerCacheDirectory -ComposerPath $composer)
    if ($folders.Count -eq 0) {
        return [pscustomobject]@{ EstimatedBytes = 0; Details = 'The Composer cache is disabled.' }
    }
    $size = Measure-ResikPathSet -Path $folders
    $details = "$($folders -join ', ') ($($size.Files) files)"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikComposerCleanup {
    # Re-reads and re-validates the cache folders instead of trusting the
    # earlier analysis, because configuration could have changed in between.
    $composer = Get-ResikComposerExecutable
    if (-not $composer) { throw 'composer was not found on PATH.' }
    $folders = @(Get-ResikComposerCacheDirectory -ComposerPath $composer)
    $existing = @($folders | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    if ($existing.Count -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'No Composer cache to clean.' }
    }
    Invoke-ResikMeasuredCommand -FilePath $composer -ArgumentList @('global', 'clear-cache', '--no-interaction') `
        -MeasurePath $existing -TimeoutSeconds 1800
}

function New-ResikComposerTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'composer' -Name 'Composer cache' -Category Developer -RiskLevel Low `
        -Description ('Empties Composer''s cache (downloaded packages, repository metadata, and VCS clones) ' +
            'by running "composer global clear-cache". vendor folders and projects are not touched; ' +
            'Composer downloads packages again when it next needs them.') `
        -Detect { Invoke-ResikComposerDetection } `
        -Analyze { Invoke-ResikComposerAnalysis } `
        -Clean { Invoke-ResikComposerCleanup }
}
