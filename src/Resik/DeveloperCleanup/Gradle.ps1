# Gradle user home target (analysis only)
# (https://docs.gradle.org/current/userguide/directory_layout.html).
#
# Gradle has no command that cleans its caches, and its documentation does not
# describe deleting them by hand as safe. It cleans them itself: version
# caches unused for 30 days, unused wrapper distributions, and daemon logs
# older than 14 days are removed when a daemon stops. Resik therefore only
# reports how much space the Gradle user home uses, and never deletes it.
#
# The Gradle user home is GRADLE_USER_HOME, else %USERPROFILE%\.gradle.

function Get-ResikGradleUserHome {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $configured = $env:GRADLE_USER_HOME
    if (-not $configured) { $configured = Join-Path $env:USERPROFILE '.gradle' }
    $path = (Expand-ResikConfiguredPath -Path $configured).TrimEnd('\')
    $issue = Get-ResikPathSafetyIssue -Path $path
    if ($issue) { throw "Not measuring the Gradle user home: $issue" }
    [System.IO.Path]::GetFullPath($path)
}

function Invoke-ResikGradleDetection {
    $gradleHome = Get-ResikGradleUserHome
    if (-not (Test-Path -LiteralPath $gradleHome -PathType Container)) {
        return [pscustomobject]@{ Available = $false; Details = "No Gradle user home at $gradleHome" }
    }
    [pscustomobject]@{ Available = $true; Details = $gradleHome }
}

function Invoke-ResikGradleAnalysis {
    $gradleHome = Get-ResikGradleUserHome
    $parts = foreach ($name in @('caches', 'wrapper\dists', 'daemon')) {
        $path = Join-Path $gradleHome $name
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        [pscustomobject]@{ Name = $name; Size = Measure-ResikDirectory -Path $path }
    }
    $parts = @($parts)
    $bytes = [long]0
    foreach ($part in $parts) { $bytes += $part.Size.Bytes }
    $listed = if ($parts.Count -gt 0) {
        ($parts | ForEach-Object { "$($_.Name) $(Format-ResikSize $_.Size.Bytes)" }) -join ', '
    }
    else { 'no caches' }
    $details = "$gradleHome ($listed). Gradle removes unused entries itself; Resik does not clean it."
    $unreadable = ($parts | ForEach-Object { $_.Size.Unreadable } | Measure-Object -Sum).Sum
    if ($unreadable -gt 0) { $details += " $unreadable folder(s) could not be read." }
    [pscustomobject]@{ EstimatedBytes = $bytes; Details = $details }
}

function New-ResikGradleTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'gradle' -Name 'Gradle caches' -Category Developer -RiskLevel Low `
        -Description ('Analysis only: reports the size of the Gradle caches, wrapper distributions, and daemon ' +
            'logs. Gradle has no command to clean them and removes unused entries itself, so Resik does not ' +
            'delete anything here.') `
        -Detect { Invoke-ResikGradleDetection } `
        -Analyze { Invoke-ResikGradleAnalysis }
}
