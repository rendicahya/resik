# NuGet HTTP cache target, using the .NET SDK
# (https://learn.microsoft.com/dotnet/core/tools/dotnet-nuget-locals).
#
#   dotnet --list-sdks                         read-only; an SDK is required
#   dotnet nuget locals http-cache --list      read-only; "http-cache: <path>"
#   dotnet nuget locals http-cache --clear     removes the HTTP cache
#
# Only the HTTP cache is cleaned. The global-packages folder is never cleaned,
# because projects use packages directly from it. The temp folder (NuGetScratch)
# is left alone because NuGet uses it to coordinate running restores.
# Verified against Microsoft's documentation only: no .NET SDK was available
# on the development machine when this target was written.

function Get-ResikDotnetExecutable {
    $dotnet = Resolve-ResikExecutable -Name 'dotnet'
    if (-not $dotnet) { throw 'dotnet was not found on PATH.' }
    $dotnet
}

function Test-ResikDotnetSdk {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $DotnetPath
    )

    $run = Invoke-ResikNativeCommand -FilePath $DotnetPath -ArgumentList @('--list-sdks') -TimeoutSeconds 60
    $run.Status -eq 'Success' -and @($run.StdOut -split "`r?`n" | Where-Object { $_.Trim() }).Count -gt 0
}

function Get-ResikNuGetHttpCacheDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $DotnetPath
    )

    $run = Invoke-ResikNativeCommand -FilePath $DotnetPath -ArgumentList @('nuget', 'locals', 'http-cache', '--list') -TimeoutSeconds 120
    if ($run.Status -ne 'Success') {
        throw (Get-ResikNativeCommandFailure $run)
    }
    # Lines look like "http-cache: C:\..." or, on some versions, "info : http-cache: C:\...".
    $matched = @($run.StdOut -split "`r?`n" | Where-Object { $_ -match '(?:^|\s)http-cache:\s+(\S.*)$' })
    if ($matched.Count -ne 1 -or $matched[0] -notmatch '(?:^|\s)http-cache:\s+(\S.*)$') {
        throw "Unexpected output from '$($run.Command)'."
    }
    $cacheDir = $Matches[1].Trim().TrimEnd('\')
    $issue = Get-ResikPathSafetyIssue -Path $cacheDir
    if ($issue) { throw "Refusing to clean the NuGet HTTP cache: $issue" }
    $cacheDir
}

function Invoke-ResikNuGetDetection {
    $dotnet = Resolve-ResikExecutable -Name 'dotnet'
    if (-not $dotnet) {
        return [pscustomobject]@{ Available = $false; Details = 'dotnet was not found on PATH.' }
    }
    if (-not (Test-ResikDotnetSdk -DotnetPath $dotnet)) {
        return [pscustomobject]@{ Available = $false; Details = 'No .NET SDK is installed (only a runtime).' }
    }
    [pscustomobject]@{ Available = $true; Details = $dotnet }
}

function Invoke-ResikNuGetAnalysis {
    $cacheDir = Get-ResikNuGetHttpCacheDirectory -DotnetPath (Get-ResikDotnetExecutable)
    $size = Measure-ResikPathSet -Path @($cacheDir)
    $details = "$cacheDir ($($size.Files) files)"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikNuGetCleanup {
    $dotnet = Get-ResikDotnetExecutable
    $cacheDir = Get-ResikNuGetHttpCacheDirectory -DotnetPath $dotnet
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No cache at $cacheDir; nothing to clean." }
    }
    Invoke-ResikMeasuredCommand -FilePath $dotnet -ArgumentList @('nuget', 'locals', 'http-cache', '--clear') `
        -MeasurePath @($cacheDir) -TimeoutSeconds 1800
}

function New-ResikNuGetTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'nuget' -Name 'NuGet HTTP cache' -Category Developer -RiskLevel Low `
        -Description ('Removes cached NuGet downloads and feed responses by running ' +
            '"dotnet nuget locals http-cache --clear". The global packages folder, which projects use ' +
            'directly, is not touched, nor are SDKs or runtimes. NuGet downloads packages again when needed.') `
        -Detect { Invoke-ResikNuGetDetection } `
        -Analyze { Invoke-ResikNuGetAnalysis } `
        -Clean { Invoke-ResikNuGetCleanup }
}
