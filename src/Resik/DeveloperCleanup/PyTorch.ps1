# PyTorch Inductor and Triton compilation caches. Neither tool has a command
# to clear its cache, so Resik deletes the cache folder's contents itself with
# Remove-ResikDirectoryContent (links are not followed); the folder is kept.
# Both caches are rebuilt on the next run, which compiles more slowly once.
#
#   torch-inductor  TORCHINDUCTOR_CACHE_DIR, else <temp>\torchinductor_<user>
#                   (torch/_inductor/runtime/cache_dir_utils.py). <temp> is
#                   Python's tempfile.gettempdir(): TMPDIR, TEMP, or TMP. <user>
#                   is getpass.getuser() (LOGNAME, USER, LNAME, or USERNAME)
#                   with \ / : * ? " < > | replaced by _. It also holds the
#                   Triton kernels Inductor compiles (triton\<device>).
#   triton          TRITON_CACHE_DIR, else <TRITON_HOME or ~>\.triton\cache
#                   (triton/knobs.py). .triton\dump and .triton\override,
#                   which hold debug output and kernels replaced by hand, are
#                   not touched.
#
# The default folders are created by these tools alone. A folder set with
# TORCHINDUCTOR_CACHE_DIR or TRITON_CACHE_DIR could be shared with other data,
# so Resik only reports its size: such a target has no Clean (like
# windows-update without administrator rights), and Clean checks again.
# Verified against the PyTorch and Triton sources on GitHub; neither was
# installed when this was written.

function Get-ResikPythonTempDirectory {
    # The first of TMPDIR, TEMP, and TMP, as tempfile.gettempdir() checks them.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    foreach ($name in @('TMPDIR', 'TEMP', 'TMP')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { return $value }
    }
    $null
}

function Get-ResikPythonUserName {
    # getpass.getuser(): the first of LOGNAME, USER, LNAME, and USERNAME.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    foreach ($name in @('LOGNAME', 'USER', 'LNAME', 'USERNAME')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { return $value }
    }
    $null
}

function New-ResikCacheLocation {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param([string] $Path, [string] $Variable = '')
    [pscustomobject]@{ Path = $Path; Variable = $Variable }
}

function Get-ResikTorchInductorCacheLocation {
    # Path, and Variable: the environment variable that set it, or ''.
    [CmdletBinding()]
    param()
    if ($env:TORCHINDUCTOR_CACHE_DIR) {
        return New-ResikCacheLocation -Path (Expand-ResikConfiguredPath $env:TORCHINDUCTOR_CACHE_DIR) -Variable 'TORCHINDUCTOR_CACHE_DIR'
    }
    $temp = Get-ResikPythonTempDirectory
    $user = Get-ResikPythonUserName
    if (-not $temp -or -not $user) { return New-ResikCacheLocation -Path '' }
    $folder = 'torchinductor_' + ($user -replace '[\\/:*?"<>|]', '_')
    New-ResikCacheLocation -Path (Join-Path (Expand-ResikConfiguredPath $temp) $folder)
}

function Get-ResikTritonCacheLocation {
    [CmdletBinding()]
    param()
    if ($env:TRITON_CACHE_DIR) {
        return New-ResikCacheLocation -Path (Expand-ResikConfiguredPath $env:TRITON_CACHE_DIR) -Variable 'TRITON_CACHE_DIR'
    }
    $tritonHome = if ($env:TRITON_HOME) { Expand-ResikConfiguredPath $env:TRITON_HOME } else { $env:USERPROFILE }
    if (-not $tritonHome) { return New-ResikCacheLocation -Path '' }
    New-ResikCacheLocation -Path (Join-Path $tritonHome '.triton\cache')
}

function Invoke-ResikCompileCacheDetection {
    param([object] $Location, [string] $Name)
    if (-not $Location.Path -or -not (Test-Path -LiteralPath $Location.Path -PathType Container)) {
        return [pscustomobject]@{ Available = $false; Details = "No $Name at $($Location.Path)." }
    }
    [pscustomobject]@{ Available = $true; Details = $Location.Path }
}

function Invoke-ResikCompileCacheAnalysis {
    param([object] $Location, [string] $Name)
    $issue = Get-ResikPathSafetyIssue -Path $Location.Path
    if ($issue) { throw "Refusing to clean the ${Name}: $issue" }
    $size = Measure-ResikDirectoryContent -Path $Location.Path
    $details = "$($Location.Path) ($($size.Files) files)"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    if ($Location.Variable) {
        $details += ". $($Location.Variable) sets this folder, so Resik does not clean it; delete its contents yourself if it holds only this cache"
    }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikCompileCacheCleanup {
    param([object] $Location, [string] $Name)
    if ($Location.Variable) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "$($Location.Variable) sets the $Name folder; Resik cleans only the default location. Nothing was changed." }
    }
    if (-not $Location.Path -or -not (Test-Path -LiteralPath $Location.Path -PathType Container)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No $Name at $($Location.Path); nothing to clean." }
    }
    Invoke-ResikMeasuredDeletion -Path $Location.Path -InUseHint 'Close Python programs that use PyTorch or Triton, then try again.'
}

function New-ResikTorchInductorTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    $clean = if (-not (Get-ResikTorchInductorCacheLocation).Variable) {
        { Invoke-ResikCompileCacheCleanup -Location (Get-ResikTorchInductorCacheLocation) -Name 'PyTorch Inductor cache' }
    }
    else { $null }
    New-ResikTarget -Id 'torch-inductor' -Name 'PyTorch Inductor cache' -Category Developer -RiskLevel Low `
        -Description ('Deletes the kernels that torch.compile (TorchInductor) compiled, in ' +
            '%TEMP%\torchinductor_<user>. PyTorch compiles them again, so the next run of a compiled model ' +
            'starts more slowly. Not cleaned when TORCHINDUCTOR_CACHE_DIR moves the cache.') `
        -Detect { Invoke-ResikCompileCacheDetection -Location (Get-ResikTorchInductorCacheLocation) -Name 'PyTorch Inductor cache' } `
        -Analyze { Invoke-ResikCompileCacheAnalysis -Location (Get-ResikTorchInductorCacheLocation) -Name 'PyTorch Inductor cache' } `
        -Clean $clean
}

function New-ResikTritonTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    $clean = if (-not (Get-ResikTritonCacheLocation).Variable) {
        { Invoke-ResikCompileCacheCleanup -Location (Get-ResikTritonCacheLocation) -Name 'Triton kernel cache' }
    }
    else { $null }
    New-ResikTarget -Id 'triton' -Name 'Triton kernel cache' -Category Developer -RiskLevel Low `
        -Description ('Deletes the GPU kernels Triton compiled, in ~\.triton\cache (or TRITON_HOME). Triton ' +
            'compiles them again on the next run. Kernels you replaced by hand (.triton\override) are kept. ' +
            'Not cleaned when TRITON_CACHE_DIR moves the cache.') `
        -Detect { Invoke-ResikCompileCacheDetection -Location (Get-ResikTritonCacheLocation) -Name 'Triton kernel cache' } `
        -Analyze { Invoke-ResikCompileCacheAnalysis -Location (Get-ResikTritonCacheLocation) -Name 'Triton kernel cache' } `
        -Clean $clean
}
