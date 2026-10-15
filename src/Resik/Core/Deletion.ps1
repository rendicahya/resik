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
