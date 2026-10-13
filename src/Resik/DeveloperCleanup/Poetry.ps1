# Poetry cache target (https://python-poetry.org/docs/cli/#cache).
#
# Uses Poetry's own commands:
#   poetry config cache-dir                          read-only; prints the cache directory
#   poetry cache list                                read-only; prints one cache name per line
#   poetry cache clear <name> --all --no-interaction removes that repository cache
# "poetry cache clear" works on <cache-dir>\cache\repositories\<name>; the
# artifacts folder (<cache-dir>\artifacts) is not touched by it, so Resik
# neither measures nor removes it. Each cache is cleared by name, because
# "poetry cache clear --all" without a name needs Poetry 2.3 or later.
# --no-interaction answers Poetry's "Delete N entries?" question with its
# default, yes; without it Poetry would wait for input.
# Verified against Poetry's documentation and its source (console/commands/
# cache/clear.py and list.py, config/config.py) only: Poetry was not installed
# on the development machine.

function Get-ResikPoetryExecutable {
    $poetry = Resolve-ResikExecutable -Name 'poetry'
    if (-not $poetry) { throw 'poetry was not found on PATH.' }
    $poetry
}

function Get-ResikPoetryRepositoryCacheDirectory {
    # Returns the validated <cache-dir>\cache\repositories folder.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $PoetryPath
    )

    $run = Invoke-ResikNativeCommand -FilePath $PoetryPath -ArgumentList @('config', 'cache-dir') -TimeoutSeconds 60
    if ($run.Status -ne 'Success') {
        throw (Get-ResikNativeCommandFailure $run)
    }
    $lines = @($run.StdOut -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -ne 1) {
        throw "Unexpected output from '$($run.Command)'."
    }
    $cacheDir = (Expand-ResikConfiguredPath -Path $lines[0]).TrimEnd('\')
    $issue = Get-ResikPathSafetyIssue -Path $cacheDir
    if ($issue) { throw "Refusing to clean the Poetry cache: $issue" }

    $repositories = Join-Path ([System.IO.Path]::GetFullPath($cacheDir)) 'cache\repositories'
    $issue = Get-ResikPathSafetyIssue -Path $repositories
    if ($issue) { throw "Refusing to clean the Poetry cache: $issue" }
    $repositories
}

function Get-ResikPoetryCacheName {
    # Emits the cache names that "poetry cache list" prints.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $PoetryPath
    )

    $run = Invoke-ResikNativeCommand -FilePath $PoetryPath -ArgumentList @('cache', 'list') -TimeoutSeconds 60
    if ($run.Status -ne 'Success') {
        throw (Get-ResikNativeCommandFailure $run)
    }
    # "No caches found" goes to stderr, so stdout holds only names.
    foreach ($line in @($run.StdOut -split "`r?`n")) {
        if ($line.Trim()) { $line.Trim() }
    }
}

function Test-ResikPoetryCacheName {
    # Poetry splits the cache argument at ':' and an option starts with '-', so
    # only plain names are passed back to it.
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Name)
    $Name -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$'
}

function Invoke-ResikPoetryDetection {
    $poetry = Resolve-ResikExecutable -Name 'poetry'
    if (-not $poetry) {
        return [pscustomobject]@{ Available = $false; Details = 'poetry was not found on PATH.' }
    }
    [pscustomobject]@{ Available = $true; Details = $poetry }
}

function Invoke-ResikPoetryAnalysis {
    $poetry = Get-ResikPoetryExecutable
    $repositories = Get-ResikPoetryRepositoryCacheDirectory -PoetryPath $poetry
    $names = @(Get-ResikPoetryCacheName -PoetryPath $poetry)
    if ($names.Count -eq 0) {
        return [pscustomobject]@{ EstimatedBytes = 0; Details = "No caches in $repositories" }
    }
    $size = Measure-ResikPathSet -Path @($repositories)
    $details = "$repositories ($($names -join ', '); $($size.Files) files)"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikPoetryCleanup {
    # Re-reads and re-validates the cache location instead of trusting the
    # earlier analysis, then clears each cache with its own command so a
    # failure in one is reported without hiding the others.
    $poetry = Get-ResikPoetryExecutable
    $repositories = Get-ResikPoetryRepositoryCacheDirectory -PoetryPath $poetry
    $names = @(Get-ResikPoetryCacheName -PoetryPath $poetry)
    if ($names.Count -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No caches in $repositories; nothing to clean." }
    }

    $outcomes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in $names) {
        if (-not (Test-ResikPoetryCacheName -Name $name)) {
            $outcomes.Add([pscustomobject]@{
                    Status = 'Failed'; Details = "Skipped the cache '$name': its name is not a plain name."
                    MeasuredBytes = $null; FreeSpaceChangeBytes = $null
                })
            continue
        }
        $outcomes.Add((Invoke-ResikMeasuredCommand -FilePath $poetry `
                    -ArgumentList @('cache', 'clear', $name, '--all', '--no-interaction') `
                    -MeasurePath @(Join-Path $repositories $name) -FreeSpacePath $repositories -TimeoutSeconds 1800))
    }
    Join-ResikPoetryOutcome -Outcome $outcomes.ToArray()
}

function Join-ResikPoetryOutcome {
    # Combines the outcomes of the per-cache commands into one. A total is
    # reported only when every part was measured.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Outcome
    )

    $statuses = @($Outcome | ForEach-Object { $_.Status })
    $status = if (@($statuses | Where-Object { $_ -ne 'Success' }).Count -eq 0) { 'Success' }
    elseif (@($statuses | Where-Object { $_ -ne 'Failed' }).Count -eq 0) { 'Failed' }
    else { 'PartialSuccess' }

    $measured = [long]0
    $freeChange = [long]0
    foreach ($item in $Outcome) {
        if ($null -eq $measured -or $null -eq $item.MeasuredBytes) { $measured = $null } else { $measured += $item.MeasuredBytes }
        if ($null -eq $freeChange -or $null -eq $item.FreeSpaceChangeBytes) { $freeChange = $null } else { $freeChange += $item.FreeSpaceChangeBytes }
    }

    [pscustomobject]@{
        Status               = $status
        Details              = (@($Outcome | ForEach-Object { $_.Details }) -join '; ')
        MeasuredBytes        = $measured
        FreeSpaceChangeBytes = $freeChange
    }
}

function New-ResikPoetryTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'poetry' -Name 'Poetry cache' -Category Developer -RiskLevel Low `
        -Description ('Removes Poetry''s repository caches (package metadata and downloads) by running ' +
            '"poetry cache clear <name> --all" for each cache that "poetry cache list" shows. Projects, ' +
            'lock files, and virtual environments are not touched; Poetry downloads packages again when ' +
            'it next needs them.') `
        -Detect { Invoke-ResikPoetryDetection } `
        -Analyze { Invoke-ResikPoetryAnalysis } `
        -Clean { Invoke-ResikPoetryCleanup }
}
