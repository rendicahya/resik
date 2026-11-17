# Temporary files target (temp-files).
#
# Windows has no command for this, so Resik deletes files itself, the way Disk
# Cleanup's "Temporary files" item does: only files older than 7 days (both
# last written and created more than 7 days ago), in
#   your temp folder (TEMP, normally %LOCALAPPDATA%\Temp), and
#   %WINDIR%\Temp, only when Resik runs as administrator.
# Files in use are skipped and reported. Empty subfolders created more than 7
# days ago are removed afterwards. Links are neither followed nor deleted.
# The temp folder must be named Temp or Tmp, so a TEMP variable pointing at an
# ordinary folder (such as Documents) is refused.

function Get-ResikTempFileAgeDays {
    7
}

function Get-ResikUserTempPath {
    # The user's temp folder, as a function so tests can point it at TestDrive.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    [System.IO.Path]::GetTempPath().TrimEnd('\')
}

function Get-ResikWindowsTempPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path ([Environment]::GetFolderPath('Windows')) 'Temp'
}

function Get-ResikCheckedTempPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )
    # TEMP and TMP are protected so that no other target empties them; this
    # target may search them, because it deletes only old files and empty
    # subfolders. Every other protected location still applies.
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $protected = @(Get-ResikProtectedPath | Where-Object { $_ -ine $full })
    $issue = Get-ResikPathSafetyIssue -Path $Path -ProtectedPath $protected
    if ($issue) { throw "Refusing to clean temporary files: $issue" }
    if (@('Temp', 'Tmp') -notcontains (Split-Path -Leaf $Path)) {
        throw "Refusing to clean temporary files: $Path is not a folder named Temp or Tmp."
    }
    $Path
}

function Get-ResikTempFileLocation {
    # The locations to clean; %WINDIR%\Temp only as administrator.
    [CmdletBinding()]
    param()
    $before = (Get-Date).AddDays(-(Get-ResikTempFileAgeDays))
    $paths = @(Get-ResikCheckedTempPath -Path (Get-ResikUserTempPath))
    if (Test-ResikAdministrator) {
        $windowsTemp = Get-ResikCheckedTempPath -Path (Get-ResikWindowsTempPath)
        if ($paths -notcontains $windowsTemp) { $paths += $windowsTemp }
    }
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path -PathType Container) {
            New-ResikAgedFileLocation -Path $path -Before $before -Recurse -PruneFolders -AllowProtectedRoot
        }
    }
}

function Invoke-ResikTempFileDetection {
    $path = Get-ResikUserTempPath
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        return [pscustomobject]@{ Available = $false; Details = "No temp folder at $path." }
    }
    [pscustomobject]@{ Available = $true; Details = $path }
}

function Invoke-ResikTempFileAnalysis {
    $locations = @(Get-ResikTempFileLocation)
    if ($locations.Count -eq 0) {
        return [pscustomobject]@{ EstimatedBytes = 0; Details = 'No temp folder found.' }
    }
    $size = Measure-ResikAgedFileLocation -Location $locations
    $days = Get-ResikTempFileAgeDays
    $details = "$($size.Files) file(s) older than $days days in $(@($locations | ForEach-Object { $_.Path }) -join ' and ')"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    if (-not (Test-ResikAdministrator)) {
        $details += "; $(Get-ResikWindowsTempPath) needs administrator rights and is not included"
    }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikTempFileCleanup {
    # Finds the files again instead of trusting the analysis.
    $locations = @(Get-ResikTempFileLocation)
    if ($locations.Count -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'No temp folder found; nothing to clean.' }
    }
    Invoke-ResikMeasuredAgedDeletion -Location $locations -Label 'the temp folders' `
        -InUseHint 'Files that running apps keep open were skipped.'
}

function New-ResikTempFileTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'temp-files' -Name 'Temporary files' -Category Windows -RiskLevel Low `
        -Description ('Deletes files older than 7 days in your temp folder (%TEMP%), and in %WINDIR%\Temp when ' +
            'Resik runs as administrator, like Disk Cleanup''s "Temporary files". Newer files and files in use ' +
            'are kept, so running apps and installers are not disturbed.') `
        -Detect { Invoke-ResikTempFileDetection } `
        -Analyze { Invoke-ResikTempFileAnalysis } `
        -Clean { Invoke-ResikTempFileCleanup }
}
