# Conda package cache target
# (https://docs.conda.io/projects/conda/en/latest/commands/clean.html).
#
#   conda clean --all --dry-run --json   read-only; lists what would be removed
#   conda clean --all --yes --json       removes it
# --all removes the index cache, unused packages and tarballs in writable
# package caches, temporary files, and log files. --force-pkgs-dirs is never
# used. Conda treats a package as unused when no file in it has more than one
# hard link and no known environment links to it with a symbolic link.
# Environments that "conda info --envs" does not list are not checked for
# symbolic links into the package cache, which is why the risk is Medium.
#
# In the --json preview, "tarballs" and "packages" each have "total_size"
# (bytes) and "pkgs_dirs" (an object whose names are the package cache
# directories that have something to remove), and "index_cache" has "files".
# Verified against conda's documentation and its source (conda/cli/
# main_clean.py) only: conda was not installed on the development machine.
#
# conda is found as conda.exe on PATH, or through CONDA_EXE, which conda's
# shell integration sets (condabin\conda.bat is not used).

function Get-ResikCondaExecutable {
    $conda = Resolve-ResikExecutable -Name 'conda'
    if ($conda) { return $conda }
    $fromEnv = $env:CONDA_EXE
    if ($fromEnv -and [System.IO.Path]::IsPathRooted($fromEnv) -and
        (Split-Path -Leaf $fromEnv) -ieq 'conda.exe' -and (Test-Path -LiteralPath $fromEnv -PathType Leaf)) {
        return [System.IO.Path]::GetFullPath($fromEnv)
    }
    $null
}

function ConvertFrom-ResikFirstJson {
    # Parses the first JSON object in Text. Conda can print a second object
    # after it (for example when a dry run exits).
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string] $Text
    )

    $start = $Text.IndexOf('{')
    if ($start -lt 0) { throw 'No JSON object found.' }
    $depth = 0
    $inString = $false
    $escaped = $false
    for ($i = $start; $i -lt $Text.Length; $i++) {
        $char = $Text[$i]
        if ($inString) {
            if ($escaped) { $escaped = $false }
            elseif ($char -eq '\') { $escaped = $true }
            elseif ($char -eq '"') { $inString = $false }
            continue
        }
        if ($char -eq '"') { $inString = $true }
        elseif ($char -eq '{') { $depth++ }
        elseif ($char -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return ($Text.Substring($start, $i - $start + 1) | ConvertFrom-Json)
            }
        }
    }
    throw 'Incomplete JSON object.'
}

function Get-ResikJsonMemberName {
    # The property names of a JSON object, or the items of a JSON array.
    param($Value)
    if ($null -eq $Value) { return }
    # A one-item array arrives here as its item, because PowerShell unrolls
    # arrays returned from functions.
    if ($Value -is [string] -or $Value -is [System.Collections.IEnumerable]) { $Value; return }
    foreach ($property in $Value.PSObject.Properties) { $property.Name }
}

function Get-ResikCondaCleanPreview {
    # Returns EstimatedBytes (unused packages and tarballs) and Paths: the
    # validated folders the cleanup affects, without nested duplicates.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $CondaPath
    )

    $run = Invoke-ResikNativeCommand -FilePath $CondaPath -ArgumentList @('clean', '--all', '--dry-run', '--json') -TimeoutSeconds 300
    if ($run.Status -ne 'Success') {
        throw (Get-ResikNativeCommandFailure $run)
    }
    try {
        $preview = ConvertFrom-ResikFirstJson -Text $run.StdOut
    }
    catch {
        throw "Unexpected output from '$($run.Command)': $($_.Exception.Message)"
    }

    $bytes = [long]0
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('tarballs', 'packages')) {
        $section = Get-ResikOptionalProperty $preview $name
        if ($null -eq $section) { throw "Unexpected output from '$($run.Command)': '$name' is missing." }
        $bytes += [long](Get-ResikOptionalProperty $section 'total_size')
        foreach ($dir in @(Get-ResikJsonMemberName (Get-ResikOptionalProperty $section 'pkgs_dirs'))) { $paths.Add([string]$dir) }
    }
    $indexCache = Get-ResikOptionalProperty $preview 'index_cache'
    foreach ($dir in @(Get-ResikJsonMemberName (Get-ResikOptionalProperty $indexCache 'files'))) { $paths.Add([string]$dir) }

    $checked = @(foreach ($path in ($paths | Select-Object -Unique)) {
            $issue = Get-ResikPathSafetyIssue -Path $path
            if ($issue) { throw "Refusing to clean the conda package cache: $issue" }
            [System.IO.Path]::GetFullPath($path).TrimEnd('\')
        })
    # Measure a folder once, even when conda lists it and a folder inside it.
    $outer = @($checked | Where-Object {
            $path = $_
            @($checked | Where-Object { $path.StartsWith("$_\", [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0
        })

    [pscustomobject]@{
        EstimatedBytes = $bytes
        Paths          = $outer
    }
}

function Invoke-ResikCondaDetection {
    $conda = Get-ResikCondaExecutable
    if (-not $conda) {
        return [pscustomobject]@{ Available = $false; Details = 'conda.exe was not found on PATH or in CONDA_EXE.' }
    }
    [pscustomobject]@{ Available = $true; Details = $conda }
}

function Invoke-ResikCondaAnalysis {
    $conda = Get-ResikCondaExecutable
    if (-not $conda) { throw 'conda.exe was not found.' }
    $preview = Get-ResikCondaCleanPreview -CondaPath $conda
    $where = if ($preview.Paths.Count -gt 0) { $preview.Paths -join ', ' } else { 'nothing to remove' }
    [pscustomobject]@{
        EstimatedBytes = $preview.EstimatedBytes
        Details        = "$where (unused packages and tarballs; the index cache and logs are not included)"
    }
}

function Invoke-ResikCondaCleanup {
    $conda = Get-ResikCondaExecutable
    if (-not $conda) { throw 'conda.exe was not found.' }
    $preview = Get-ResikCondaCleanPreview -CondaPath $conda
    if ($preview.Paths.Count -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'Conda reports nothing to remove.' }
    }
    Invoke-ResikMeasuredCommand -FilePath $conda -ArgumentList @('clean', '--all', '--yes', '--json') `
        -MeasurePath $preview.Paths -TimeoutSeconds 1800
}

function New-ResikCondaTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'conda' -Name 'Conda package cache' -Category Developer -RiskLevel Medium `
        -Description ('Removes unused packages, downloaded package files, the index cache, and logs by running ' +
            '"conda clean --all". Environments and their installed packages are kept. Conda checks only the ' +
            'environments it knows about (conda info --envs) for links into the package cache, so an ' +
            'environment it does not list could lose files. Conda downloads packages again when needed.') `
        -Detect { Invoke-ResikCondaDetection } `
        -Analyze { Invoke-ResikCondaAnalysis } `
        -Clean { Invoke-ResikCondaCleanup }
}
