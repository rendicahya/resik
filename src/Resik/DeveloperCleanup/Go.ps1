# Go build cache and module cache targets
# (https://pkg.go.dev/cmd/go#hdr-Remove_object_files_and_cached_files).
#
# Uses Go's own commands:
#   go env GOCACHE         read-only; prints the build cache directory
#   go clean -cache        removes the entire build cache
#   go env GOMODCACHE      read-only; prints the module cache directory
#   go clean -modcache     removes the entire module download cache
# They are separate targets: the build cache only holds compiler output, while
# the module cache holds downloaded source that offline builds and replace
# directives may depend on. GOCACHE=off disables the build cache. All commands
# run in the user profile folder, so a go.mod or go.work in the current folder
# cannot make Go download a different toolchain first.
# Verified against Go's documentation only: Go was not installed on the
# development machine.

function Get-ResikGoExecutable {
    $go = Resolve-ResikExecutable -Name 'go'
    if (-not $go) { throw 'go was not found on PATH.' }
    $go
}

function Get-ResikGoCacheDirectory {
    # Returns the validated folder for GOCACHE or GOMODCACHE, or $null when
    # the build cache is turned off.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $GoPath,

        [Parameter(Mandatory)]
        [ValidateSet('GOCACHE', 'GOMODCACHE')]
        [string] $Variable
    )

    $run = Invoke-ResikNativeCommand -FilePath $GoPath -ArgumentList @('env', $Variable) -TimeoutSeconds 60 `
        -WorkingDirectory (Get-ResikToolWorkingDirectory)
    if ($run.Status -ne 'Success') {
        throw (Get-ResikNativeCommandFailure $run)
    }
    $lines = @($run.StdOut -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -ne 1) {
        throw "Unexpected output from '$($run.Command)'."
    }
    $value = $lines[0].Trim()
    if ($Variable -eq 'GOCACHE' -and $value -eq 'off') { return $null }
    $issue = Get-ResikPathSafetyIssue -Path $value
    if ($issue) { throw "Refusing to clean ${Variable}: $issue" }
    $value
}

function Invoke-ResikGoDetection {
    $go = Resolve-ResikExecutable -Name 'go'
    if (-not $go) {
        return [pscustomobject]@{ Available = $false; Details = 'go was not found on PATH.' }
    }
    [pscustomobject]@{ Available = $true; Details = $go }
}

function Invoke-ResikGoAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GOCACHE', 'GOMODCACHE')]
        [string] $Variable
    )

    $cacheDir = Get-ResikGoCacheDirectory -GoPath (Get-ResikGoExecutable) -Variable $Variable
    if (-not $cacheDir) {
        return [pscustomobject]@{ EstimatedBytes = 0; Details = 'The Go build cache is turned off (GOCACHE=off).' }
    }
    $size = Measure-ResikPathSet -Path @($cacheDir)
    $details = "$cacheDir ($($size.Files) files)"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikGoCleanup {
    # Re-reads and re-validates the folder instead of trusting the earlier
    # analysis.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GOCACHE', 'GOMODCACHE')]
        [string] $Variable
    )

    $go = Get-ResikGoExecutable
    $cacheDir = Get-ResikGoCacheDirectory -GoPath $go -Variable $Variable
    if (-not $cacheDir -or -not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No $Variable folder; nothing to clean." }
    }
    $flag = if ($Variable -eq 'GOCACHE') { '-cache' } else { '-modcache' }
    Invoke-ResikMeasuredCommand -FilePath $go -ArgumentList @('clean', $flag) `
        -MeasurePath @($cacheDir) -TimeoutSeconds 1800 -WorkingDirectory (Get-ResikToolWorkingDirectory)
}

function New-ResikGoBuildTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'go-build' -Name 'Go build cache' -Category Developer -RiskLevel Low `
        -Description ('Removes the Go build cache (GOCACHE) by running "go clean -cache". ' +
            'Projects and downloaded modules are not touched; the next builds and tests are slower while Go rebuilds it.') `
        -Detect { Invoke-ResikGoDetection } `
        -Analyze { Invoke-ResikGoAnalysis -Variable GOCACHE } `
        -Clean { Invoke-ResikGoCleanup -Variable GOCACHE }
}

function New-ResikGoModulesTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'go-modules' -Name 'Go module cache' -Category Developer -RiskLevel Medium `
        -Description ('Removes every downloaded Go module (GOMODCACHE) by running "go clean -modcache". ' +
            'Projects are not touched, but builds download their modules again and fail while offline.') `
        -Detect { Invoke-ResikGoDetection } `
        -Analyze { Invoke-ResikGoAnalysis -Variable GOMODCACHE } `
        -Clean { Invoke-ResikGoCleanup -Variable GOMODCACHE }
}
