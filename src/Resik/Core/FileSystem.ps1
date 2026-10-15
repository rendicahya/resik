# Read-only filesystem helpers: path safety checks, size measurement, and free
# disk space. Nothing in this file modifies the filesystem.

function Get-ResikProtectedPath {
    # Locations that must never be cleaned, nor any folder that contains them.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $variables = @('SystemRoot', 'windir', 'ProgramFiles', 'ProgramFiles(x86)', 'ProgramW6432',
        'ProgramData', 'PUBLIC', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'TEMP', 'TMP')
    $folders = @('Desktop', 'MyDocuments', 'MyMusic', 'MyPictures', 'MyVideos', 'Favorites', 'Startup',
        'ApplicationData', 'LocalApplicationData', 'CommonApplicationData', 'UserProfile', 'System',
        'Windows', 'ProgramFiles', 'ProgramFilesX86')

    $paths = @(
        foreach ($name in $variables) { [Environment]::GetEnvironmentVariable($name) }
        foreach ($name in $folders) { [Environment]::GetFolderPath([Environment+SpecialFolder]$name) }
    )
    # The folder holding all user profiles, such as C:\Users.
    $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if ($userProfile) { $paths += Split-Path -Parent $userProfile }

    foreach ($path in $paths) {
        if ($path -and $path -match '^[A-Za-z]:\\') {
            [System.IO.Path]::GetFullPath($path).TrimEnd('\')
        }
    }
}

function Get-ResikPathSafetyIssue {
    <#
    .SYNOPSIS
        Explains why a directory must not be cleaned, or returns $null.
    .DESCRIPTION
        Accepts only fully qualified local paths (C:\...). Rejects drive roots,
        protected locations and their parent folders, and paths that are
        symbolic links or junctions. ProtectedPath defaults to
        Get-ResikProtectedPath and is a parameter so tests can supply their own.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Path,

        [AllowEmptyCollection()]
        [string[]] $ProtectedPath = @(Get-ResikProtectedPath)
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return 'The path is empty.'
    }
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0 -or
        $Path.IndexOfAny([char[]]'*?') -ge 0 -or $Path.Substring(2).Contains(':')) {
        return "'$Path' is not a fully qualified local path."
    }

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -match '^[A-Za-z]:$') {
        return "'$Path' is a drive root."
    }

    foreach ($protected in $ProtectedPath) {
        if (-not $protected) { continue }
        $protected = $protected.TrimEnd('\')
        if ($full -ieq $protected) {
            return "'$full' is a protected location."
        }
        if ($protected.StartsWith("$full\", [System.StringComparison]::OrdinalIgnoreCase)) {
            return "'$full' contains the protected location '$protected'."
        }
    }

    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if ($null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        return "'$full' is a symbolic link or junction."
    }
    $null
}

function Expand-ResikConfiguredPath {
    # Expands %VARIABLES% and a leading ~ in a path read from an environment
    # variable or a configuration file. The result is not trusted: it still
    # has to pass Get-ResikPathSafetyIssue.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ($expanded -eq '~' -or $expanded.StartsWith('~\') -or $expanded.StartsWith('~/')) {
        $expanded = $env:USERPROFILE + $expanded.Substring(1)
    }
    $expanded.Replace('/', '\')
}

function Measure-ResikDirectory {
    <#
    .SYNOPSIS
        Measures the total size of the files under a directory.
    .DESCRIPTION
        Never follows symbolic links or junctions, and does not count them.
        Returns Bytes, Files, and Unreadable (directories that could not be
        listed). Bytes is a lower bound when Unreadable is above zero. Files
        with several hard links are counted once per link.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $bytes = [long]0
    $files = 0
    $unreadable = 0
    $pending = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    $pending.Push((New-Object System.IO.DirectoryInfo $Path))
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        try {
            $entries = $directory.GetFileSystemInfos()
        }
        catch {
            $unreadable++
            continue
        }
        foreach ($entry in $entries) {
            if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($entry -is [System.IO.DirectoryInfo]) {
                $pending.Push($entry)
            }
            else {
                $bytes += $entry.Length
                $files++
            }
        }
    }

    [pscustomobject]@{
        Bytes      = $bytes
        Files      = $files
        Unreadable = $unreadable
    }
}

function Get-ResikFreeSpace {
    # Free bytes available to the current user on the drive holding Path, or
    # $null when it cannot be determined.
    [CmdletBinding()]
    [OutputType([Nullable[long]])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    try {
        $root = [System.IO.Path]::GetPathRoot($Path)
        if (-not $root) { return $null }
        [long](New-Object System.IO.DriveInfo $root).AvailableFreeSpace
    }
    catch {
        $null
    }
}

function Measure-ResikDirectoryContent {
    # Like Measure-ResikDirectory, but counts only the items directly inside
    # Path whose names match Filter (and everything under them). A missing
    # folder counts as empty.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [string] $Filter = '*'
    )

    $bytes = [long]0
    $files = 0
    $unreadable = 0
    $directory = New-Object System.IO.DirectoryInfo $Path
    if ($directory.Exists) {
        try {
            $entries = @($directory.GetFileSystemInfos($Filter))
        }
        catch {
            $entries = @()
            $unreadable++
        }
        foreach ($entry in $entries) {
            if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($entry -is [System.IO.DirectoryInfo]) {
                $size = Measure-ResikDirectory -Path $entry.FullName
                $bytes += $size.Bytes
                $files += $size.Files
                $unreadable += $size.Unreadable
            }
            else {
                $bytes += $entry.Length
                $files++
            }
        }
    }
    [pscustomobject]@{ Bytes = $bytes; Files = $files; Unreadable = $unreadable }
}

function Get-ResikLocalAppDataPath {
    # %LOCALAPPDATA%, as a function so tests can point it at TestDrive.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
}
