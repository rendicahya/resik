# Deleting a folder that Resik itself has to remove, for targets whose tool has
# no cleanup command (such as leftover Scoop persist folders).
#
# Remove-Item -Recurse is not used: Windows PowerShell 5.1 can follow a
# junction and delete what it points to. Instead the tree is walked with .NET,
# deepest folders first, and a symbolic link or junction is removed as a link
# (RemoveDirectory or DeleteFile on the link itself) without being entered.
# Attributes are never changed on links, because SetFileAttributes follows them.

function Get-ResikExceptionReason {
    # The message of the .NET exception behind an error record.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    if ($null -ne $exception.InnerException) { $exception = $exception.InnerException }
    $exception.Message
}

function Remove-ResikDirectoryTree {
    <#
    .SYNOPSIS
        Deletes a folder and everything in it without following links.
    .DESCRIPTION
        Path must pass Get-ResikPathSafetyIssue, must not itself be a link, and
        must be strictly inside Scope. Items that cannot be deleted (in use,
        access denied) are skipped and reported; the rest are still deleted.
        Returns Errors (one line per item that could not be deleted) and
        Removed (whether Path itself is gone).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Scope
    )

    $issue = Get-ResikPathSafetyIssue -Path $Path
    if ($issue) { throw "Refusing to delete: $issue" }
    $scopeIssue = Get-ResikPathSafetyIssue -Path $Scope
    if ($scopeIssue) { throw "Refusing to delete inside '$Scope': $scopeIssue" }

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $scopeFull = [System.IO.Path]::GetFullPath($Scope).TrimEnd('\')
    if (-not $full.StartsWith("$scopeFull\", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to delete '$full': it is not inside '$scopeFull'."
    }

    $errors = New-Object 'System.Collections.Generic.List[string]'
    $root = New-Object System.IO.DirectoryInfo $full
    if (-not $root.Exists) {
        return [pscustomobject]@{ Removed = $true; Errors = @() }
    }
    if (-not $PSCmdlet.ShouldProcess($full, 'Delete folder')) {
        return [pscustomobject]@{ Removed = $false; Errors = @() }
    }

    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $readOnly = [System.IO.FileAttributes]::ReadOnly
    # Each entry is visited twice: first to queue its children, then, after
    # they are gone, to delete the folder itself.
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push([pscustomobject]@{ Directory = $root; Expanded = $false })
    while ($stack.Count -gt 0) {
        $entry = $stack.Pop()
        $directory = $entry.Directory
        if ($entry.Expanded) {
            try {
                if ($directory.Attributes -band $readOnly) { $directory.Attributes = $directory.Attributes -band (-bnot $readOnly) }
                $directory.Delete($false)
            }
            catch {
                # A folder that still holds an item reported above is not
                # reported again.
                $failure = $_
                $before = $errors.Count
                $stillHasItems = $false
                try { $stillHasItems = @($directory.GetFileSystemInfos()).Count -gt 0 } catch { $stillHasItems = $false }
                if (-not ($stillHasItems -and $before -gt 0)) {
                    $errors.Add("$($directory.FullName): $(Get-ResikExceptionReason $failure)")
                }
            }
            continue
        }

        $stack.Push([pscustomobject]@{ Directory = $directory; Expanded = $true })
        try {
            $children = $directory.GetFileSystemInfos()
        }
        catch {
            $errors.Add("$($directory.FullName): $(Get-ResikExceptionReason $_)")
            continue
        }
        foreach ($child in $children) {
            $isDirectory = $child -is [System.IO.DirectoryInfo]
            try {
                if ($child.Attributes -band $reparse) {
                    # Removes the link only; its target is left alone.
                    $child.Delete()
                }
                elseif ($isDirectory) {
                    $stack.Push([pscustomobject]@{ Directory = $child; Expanded = $false })
                }
                else {
                    if ($child.Attributes -band $readOnly) { $child.Attributes = $child.Attributes -band (-bnot $readOnly) }
                    $child.Delete()
                }
            }
            catch {
                $errors.Add("$($child.FullName): $(Get-ResikExceptionReason $_)")
            }
        }
    }

    $root.Refresh()
    [pscustomobject]@{ Removed = -not $root.Exists; Errors = $errors.ToArray() }
}

function Remove-ResikDirectoryContent {
    <#
    .SYNOPSIS
        Deletes the items directly inside a folder whose names match Filter,
        and everything under them, without following links.
    .DESCRIPTION
        Path must pass Get-ResikPathSafetyIssue and must not be a link; the
        folder itself is kept. Subfolders go through Remove-ResikDirectoryTree
        with Path as the scope, and a link is removed as a link. Items that
        cannot be deleted (in use, access denied) are skipped and reported in
        Errors.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [string] $Filter = '*'
    )

    $issue = Get-ResikPathSafetyIssue -Path $Path
    if ($issue) { throw "Refusing to delete: $issue" }

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = New-Object System.IO.DirectoryInfo $full
    if (-not $root.Exists) { return [pscustomobject]@{ Errors = @() } }
    if (-not $PSCmdlet.ShouldProcess($full, "Delete the items matching '$Filter'")) {
        return [pscustomobject]@{ Errors = @() }
    }

    $errors = New-Object 'System.Collections.Generic.List[string]'
    $readOnly = [System.IO.FileAttributes]::ReadOnly
    foreach ($child in @($root.GetFileSystemInfos($Filter))) {
        try {
            if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                # Removes the link only; its target is left alone.
                $child.Delete()
            }
            elseif ($child -is [System.IO.DirectoryInfo]) {
                $tree = Remove-ResikDirectoryTree -Path $child.FullName -Scope $full -Confirm:$false
                foreach ($line in @($tree.Errors)) { $errors.Add($line) }
            }
            else {
                if ($child.Attributes -band $readOnly) { $child.Attributes = $child.Attributes -band (-bnot $readOnly) }
                $child.Delete()
            }
        }
        catch {
            $errors.Add("$($child.FullName): $(Get-ResikExceptionReason $_)")
        }
    }
    [pscustomobject]@{ Errors = $errors.ToArray() }
}

function Get-ResikAgedFile {
    <#
    .SYNOPSIS
        Finds the files in a folder that are older than a cutoff.
    .DESCRIPTION
        A file counts when both its last-write and creation times are before
        Before, and its name matches one of Include. With Recurse, subfolders
        are searched too, but links (symbolic links, junctions) are neither
        entered nor returned. Returns Files (FileInfo objects), Bytes, and
        Unreadable (folders that could not be listed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [datetime] $Before,

        [string[]] $Include = @('*'),

        [switch] $Recurse
    )

    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $files = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $bytes = [long]0
    $unreadable = 0
    $root = New-Object System.IO.DirectoryInfo $Path
    if ($root.Exists -and -not ($root.Attributes -band $reparse)) {
        $pending = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
        $pending.Push($root)
        while ($pending.Count -gt 0) {
            $directory = $pending.Pop()
            try {
                $entries = @($directory.GetFileSystemInfos())
            }
            catch {
                $unreadable++
                continue
            }
            foreach ($entry in $entries) {
                if ($entry.Attributes -band $reparse) { continue }
                if ($entry -is [System.IO.DirectoryInfo]) {
                    if ($Recurse) { $pending.Push($entry) }
                    continue
                }
                if ($entry.LastWriteTime -ge $Before -or $entry.CreationTime -ge $Before) { continue }
                $matched = $false
                foreach ($pattern in $Include) {
                    if ($entry.Name -like $pattern) { $matched = $true; break }
                }
                if (-not $matched) { continue }
                $files.Add($entry)
                $bytes += $entry.Length
            }
        }
    }
    [pscustomobject]@{ Files = $files.ToArray(); Bytes = $bytes; Unreadable = $unreadable }
}

function Remove-ResikAgedFile {
    <#
    .SYNOPSIS
        Deletes files found by Get-ResikAgedFile, one by one.
    .DESCRIPTION
        Each file must be strictly inside Scope and must not be a link. Files
        in use or without access are skipped and reported in Errors.
        RemovedBytes and RemovedFiles count the files that are gone afterwards.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowEmptyCollection()]
        [System.IO.FileInfo[]] $File = @(),

        [Parameter(Mandatory)]
        [string] $Scope,

        # Only single files are deleted, so a protected folder such as TEMP
        # may be the scope when the caller removes it from this list.
        [AllowEmptyCollection()]
        [string[]] $ProtectedPath = @(Get-ResikProtectedPath)
    )

    $issue = Get-ResikPathSafetyIssue -Path $Scope -ProtectedPath $ProtectedPath
    if ($issue) { throw "Refusing to delete inside '$Scope': $issue" }
    $scopeFull = [System.IO.Path]::GetFullPath($Scope).TrimEnd('\')

    $errors = New-Object 'System.Collections.Generic.List[string]'
    $removedBytes = [long]0
    $removedFiles = 0
    $readOnly = [System.IO.FileAttributes]::ReadOnly
    foreach ($item in $File) {
        $full = [System.IO.Path]::GetFullPath($item.FullName)
        if (-not $full.StartsWith("$scopeFull\", [System.StringComparison]::OrdinalIgnoreCase)) {
            $errors.Add("${full}: not inside $scopeFull")
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($full, 'Delete file')) { continue }
        try {
            $item.Refresh()
            if (-not $item.Exists) { continue }
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $length = $item.Length
            if ($item.Attributes -band $readOnly) { $item.Attributes = $item.Attributes -band (-bnot $readOnly) }
            $item.Delete()
            $removedBytes += $length
            $removedFiles++
        }
        catch {
            $errors.Add("${full}: $(Get-ResikExceptionReason $_)")
        }
    }
    [pscustomobject]@{ Errors = $errors.ToArray(); RemovedBytes = $removedBytes; RemovedFiles = $removedFiles }
}

function Remove-ResikEmptyFolder {
    <#
    .SYNOPSIS
        Removes empty subfolders of Path that were created before Before.
    .DESCRIPTION
        Deepest folders first, so a tree of empty folders goes entirely. Path
        itself is kept, links are neither entered nor removed, and a folder
        that cannot be removed (in use) is left alone. Returns the number of
        folders removed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [datetime] $Before,

        # Only empty subfolders are removed, so a protected folder such as
        # TEMP may be Path when the caller removes it from this list.
        [AllowEmptyCollection()]
        [string[]] $ProtectedPath = @(Get-ResikProtectedPath)
    )

    $issue = Get-ResikPathSafetyIssue -Path $Path -ProtectedPath $ProtectedPath
    if ($issue) { throw "Refusing to delete: $issue" }
    $reparse = [System.IO.FileAttributes]::ReparsePoint
    $root = New-Object System.IO.DirectoryInfo ([System.IO.Path]::GetFullPath($Path).TrimEnd('\'))
    if (-not $root.Exists -or ($root.Attributes -band $reparse)) { return 0 }

    # Collect folders top-down, then visit them in reverse (deepest first).
    $ordered = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'
    $pending = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $pending.Push($root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        try { $children = @($directory.GetDirectories()) } catch { continue }
        foreach ($child in $children) {
            if ($child.Attributes -band $reparse) { continue }
            $ordered.Add($child)
            $pending.Push($child)
        }
    }
    $removed = 0
    for ($i = $ordered.Count - 1; $i -ge 0; $i--) {
        $directory = $ordered[$i]
        try {
            $directory.Refresh()
            if ($directory.CreationTime -ge $Before) { continue }
            if (@($directory.GetFileSystemInfos()).Count -gt 0) { continue }
            if (-not $PSCmdlet.ShouldProcess($directory.FullName, 'Delete empty folder')) { continue }
            $directory.Delete($false)
            $removed++
        }
        catch {
            continue
        }
    }
    $removed
}
