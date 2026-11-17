# Dart and Flutter pub cache target (https://dart.dev/tools/pub/cmd/pub-cache).
#
#   dart pub cache clean --force    removes the whole pub cache (PUB_CACHE)
#
# Dart has no command that prints the cache location, so Resik reads it the
# way pub does (lib/src/system_cache.dart): PUB_CACHE when set, otherwise
# %LOCALAPPDATA%\Pub\Cache. --force skips pub's own "Are you sure?" question;
# Resik asks before cleaning. The cache also holds packages activated with
# "dart pub global activate", which are removed too, so the target is Medium
# risk. Flutter installs put dart.bat on PATH instead of dart.exe; its
# arguments are plain tokens. "pub cache clean" needs Dart 2.14 or later.
# Verified against Dart's documentation and pub's source only: Dart was not
# installed on the development machine.

function Get-ResikDartExecutable {
    $dart = Resolve-ResikExecutable -Name 'dart'
    if (-not $dart) { $dart = Resolve-ResikExecutable -Name 'dart' -Extension '.bat' }
    if (-not $dart) { throw 'dart was not found on PATH.' }
    $dart
}

function Get-ResikPubCacheDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $configured = [Environment]::GetEnvironmentVariable('PUB_CACHE')
    # Windows cannot store an empty environment variable, so empty means unset.
    if (-not [string]::IsNullOrEmpty($configured)) {
        if (-not $configured.Trim()) { throw 'Refusing to clean the pub cache: PUB_CACHE is blank.' }
        $cacheDir = Expand-ResikConfiguredPath -Path $configured
    } else {
        $cacheDir = Join-Path (Get-ResikLocalAppDataPath) 'Pub\Cache'
    }
    $cacheDir = $cacheDir.TrimEnd('\')
    $issue = Get-ResikPathSafetyIssue -Path $cacheDir
    if ($issue) { throw "Refusing to clean the pub cache: $issue" }
    $cacheDir
}

function Invoke-ResikDartDetection {
    $dart = Resolve-ResikExecutable -Name 'dart'
    if (-not $dart) { $dart = Resolve-ResikExecutable -Name 'dart' -Extension '.bat' }
    if (-not $dart) {
        return [pscustomobject]@{ Available = $false; Details = 'dart was not found on PATH.' }
    }
    [pscustomobject]@{ Available = $true; Details = $dart }
}

function Invoke-ResikDartAnalysis {
    $cacheDir = Get-ResikPubCacheDirectory
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return [pscustomobject]@{ EstimatedBytes = 0; Details = "No pub cache at $cacheDir." }
    }
    $size = Measure-ResikPathSet -Path @($cacheDir)
    $details = "$cacheDir ($($size.Files) files)"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikDartCleanup {
    # Re-reads and re-validates the folder instead of trusting the analysis.
    $dart = Get-ResikDartExecutable
    $cacheDir = Get-ResikPubCacheDirectory
    if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No pub cache at $cacheDir; nothing to clean." }
    }
    Invoke-ResikMeasuredCommand -FilePath $dart -ArgumentList @('pub', 'cache', 'clean', '--force') `
        -MeasurePath @($cacheDir) -TimeoutSeconds 1800 -WorkingDirectory (Get-ResikToolWorkingDirectory)
}

function New-ResikDartTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'dart' -Name 'Dart and Flutter pub cache' -Category Developer -RiskLevel Medium `
        -Description ('Removes every downloaded Dart and Flutter package (PUB_CACHE) by running ' +
            '"dart pub cache clean --force", including tools activated with "dart pub global activate". ' +
            'Projects are not touched, but each needs "dart pub get" or "flutter pub get" again, which fails while offline.') `
        -Detect { Invoke-ResikDartDetection } `
        -Analyze { Invoke-ResikDartAnalysis } `
        -Clean { Invoke-ResikDartCleanup }
}
