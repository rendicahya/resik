# pip cache target (https://pip.pypa.io/en/stable/cli/pip_cache/).
#
# Uses pip's own commands, verified against pip 26:
#   python -m pip cache dir                          read-only
#   python -m pip cache purge --cache-dir <dir>      removes cached files
# "pip cache purge" deletes only the files in the http, http-v2, and wheels
# subfolders of the cache, so those are what Resik measures.
#
# The pip cache is shared by all Python installations of the user (unless one
# is configured differently), so one interpreter is enough. Resik uses, in
# order: python.exe on PATH, the py launcher, then a uv-managed Python found
# with "uv python find --managed-python --no-project". The python.exe that Windows places in WindowsApps
# when no Python is installed opens the Microsoft Store, so it is never run.

function Test-ResikWindowsAppsPythonStub {
    # True for the WindowsApps python.exe alias when no Store Python is installed.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $windowsApps = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Microsoft\WindowsApps'
    $directory = Split-Path -Parent $Path
    if ($directory.TrimEnd('\') -ine $windowsApps.TrimEnd('\')) { return $false }
    $storePython = @(Get-ChildItem -LiteralPath $windowsApps -Directory -Filter 'PythonSoftwareFoundation.Python.*' -ErrorAction SilentlyContinue)
    $storePython.Count -eq 0
}

function Get-ResikPipPythonCandidate {
    # Emits interpreter commands to try, as objects with FilePath and the
    # arguments that select the interpreter (the py launcher needs none).
    [CmdletBinding()]
    param()

    foreach ($command in @(Get-Command -Name 'python.exe' -CommandType Application -All -ErrorAction SilentlyContinue)) {
        if ($command.Path -and -not (Test-ResikWindowsAppsPythonStub -Path $command.Path)) {
            [pscustomobject]@{ FilePath = $command.Path; Source = 'python on PATH' }
        }
    }
    $py = Resolve-ResikExecutable -Name 'py'
    if ($py) { [pscustomobject]@{ FilePath = $py; Source = 'py launcher' } }

    $uv = Resolve-ResikExecutable -Name 'uv'
    if ($uv) {
        # A uv-managed interpreter (these include pip), never a project's
        # virtual environment, and never a download.
        $run = Invoke-ResikNativeCommand -FilePath $uv -TimeoutSeconds 60 `
            -ArgumentList @('python', 'find', '--managed-python', '--no-project', '--no-python-downloads')
        $found = @($run.StdOut -split "`r?`n" | Where-Object { $_.Trim() })
        if ($run.Status -eq 'Success' -and $found.Count -eq 1 -and (Test-Path -LiteralPath $found[0].Trim() -PathType Leaf)) {
            [pscustomobject]@{ FilePath = $found[0].Trim(); Source = 'uv-managed Python' }
        }
    }
}

function Find-ResikPipPython {
    # Returns the first candidate whose pip works, or $null.
    [CmdletBinding()]
    param()

    foreach ($candidate in @(Get-ResikPipPythonCandidate)) {
        $run = Invoke-ResikNativeCommand -FilePath $candidate.FilePath `
            -ArgumentList @('-m', 'pip', '--version', '--disable-pip-version-check') -TimeoutSeconds 60
        if ($run.Status -eq 'Success') {
            return $candidate
        }
    }
    $null
}

function Get-ResikPipCacheDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $PythonPath
    )

    $run = Invoke-ResikNativeCommand -FilePath $PythonPath `
        -ArgumentList @('-m', 'pip', 'cache', 'dir', '--no-input', '--disable-pip-version-check') -TimeoutSeconds 60
    if ($run.Status -ne 'Success') {
        throw (Get-ResikNativeCommandFailure $run)
    }
    $lines = @($run.StdOut -split "`r?`n" | Where-Object { $_.Trim() })
    if ($lines.Count -ne 1) {
        throw "Unexpected output from '$($run.Command)'."
    }
    $cacheDir = $lines[0].Trim()
    $issue = Get-ResikPathSafetyIssue -Path $cacheDir
    if ($issue) { throw "Refusing to clean the pip cache: $issue" }
    $cacheDir
}

function Get-ResikPipCachePath {
    # The subfolders whose files "pip cache purge" deletes.
    param([string] $CacheDir)
    foreach ($name in @('http', 'http-v2', 'wheels')) { Join-Path $CacheDir $name }
}

function Invoke-ResikPipDetection {
    $python = Find-ResikPipPython
    if ($null -eq $python) {
        return [pscustomobject]@{ Available = $false; Details = 'No Python with pip was found.' }
    }
    [pscustomobject]@{ Available = $true; Details = "$($python.FilePath) ($($python.Source))" }
}

function Invoke-ResikPipAnalysis {
    $python = Find-ResikPipPython
    if ($null -eq $python) { throw 'No Python with pip was found.' }
    $cacheDir = Get-ResikPipCacheDirectory -PythonPath $python.FilePath
    $size = Measure-ResikPathSet -Path @(Get-ResikPipCachePath -CacheDir $cacheDir)
    $details = "$cacheDir ($($size.Files) files, using $($python.Source))"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikPipCleanup {
    $python = Find-ResikPipPython
    if ($null -eq $python) { throw 'No Python with pip was found.' }
    $cacheDir = Get-ResikPipCacheDirectory -PythonPath $python.FilePath
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No cache at $cacheDir; nothing to clean." }
    }
    Invoke-ResikMeasuredCommand -FilePath $python.FilePath `
        -ArgumentList @('-m', 'pip', 'cache', 'purge', '--cache-dir', $cacheDir, '--no-input', '--disable-pip-version-check') `
        -MeasurePath @(Get-ResikPipCachePath -CacheDir $cacheDir) -FreeSpacePath $cacheDir -TimeoutSeconds 1800
}

function New-ResikPipTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'pip' -Name 'pip cache' -Category Developer -RiskLevel Low `
        -Description ('Removes downloaded and locally built packages from the pip cache by running ' +
            '"python -m pip cache purge". Installed packages and virtual environments are not touched; ' +
            'pip downloads or builds packages again when it next needs them.') `
        -Detect { Invoke-ResikPipDetection } `
        -Analyze { Invoke-ResikPipAnalysis } `
        -Clean { Invoke-ResikPipCleanup }
}
