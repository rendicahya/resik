# Screenshots target.
#
# Windows saves Win+PrtScn and Snipping Tool screenshots in the Screenshots
# known folder (FOLDERID_Screenshots, by default Pictures\Screenshots). Resik
# asks the shell for it through the documented shell:Screenshots name, so a
# folder moved in its Properties dialog is followed. There is no command for
# this, so Resik deletes the image files directly inside that folder itself;
# subfolders, links, desktop.ini, and other files are kept.
# Screenshots are your own files, not a cache: nothing recreates them and they
# do not go to the Recycle Bin, so the target is High risk and is never chosen
# by --all or "select all". A folder inside OneDrive is report-only, because
# deleting there also deletes the copies in the cloud.

function Get-ResikScreenshotsFolder {
    # The Screenshots known folder, or $null when Windows has none.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $folder = (New-Object -ComObject Shell.Application).NameSpace('shell:Screenshots')
        if ($null -eq $folder) { return $null }
        $folder.Self.Path
    }
    catch {
        $null
    }
}

function Get-ResikOneDriveFolder {
    # The OneDrive folders the OneDrive client publishes in the environment.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    foreach ($name in @('OneDrive', 'OneDriveConsumer', 'OneDriveCommercial')) {
        $path = [Environment]::GetEnvironmentVariable($name)
        if ($path -and $path -match '^[A-Za-z]:\\') { [System.IO.Path]::GetFullPath($path).TrimEnd('\') }
    }
}

function Test-ResikScreenshotsInOneDrive {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    # Anything else is rejected later by Get-ResikPathSafetyIssue.
    if ($Path -notmatch '^[A-Za-z]:\\' -or $Path.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0) {
        return $false
    }
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    foreach ($oneDrive in @(Get-ResikOneDriveFolder)) {
        if ($full -ieq $oneDrive -or $full.StartsWith("$oneDrive\", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    $false
}

function Get-ResikScreenshotExtension { @('.png', '.jpg', '.jpeg', '.gif', '.bmp') }

function Get-ResikScreenshotFile {
    # The image files directly inside Path. Links are left out, so a link is
    # neither measured nor deleted.
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $directory = New-Object System.IO.DirectoryInfo $Path
    if (-not $directory.Exists) { return }
    $extensions = Get-ResikScreenshotExtension
    foreach ($file in $directory.GetFiles()) {
        if ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        if ($extensions -contains $file.Extension.ToLowerInvariant()) { $file }
    }
}

function Measure-ResikScreenshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $bytes = [long]0
    $files = 0
    foreach ($file in @(Get-ResikScreenshotFile -Path $Path)) {
        $bytes += $file.Length
        $files++
    }
    [pscustomobject]@{ Bytes = $bytes; Files = $files }
}

function Remove-ResikScreenshotFile {
    # Deletes the screenshot files in Path. Files that cannot be deleted are
    # skipped and reported in Errors.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $issue = Get-ResikPathSafetyIssue -Path $Path
    if ($issue) { throw "Refusing to delete: $issue" }

    $errors = New-Object 'System.Collections.Generic.List[string]'
    if (-not $PSCmdlet.ShouldProcess($Path, 'Delete the screenshot files')) {
        return [pscustomobject]@{ Errors = @() }
    }
    $readOnly = [System.IO.FileAttributes]::ReadOnly
    foreach ($file in @(Get-ResikScreenshotFile -Path $Path)) {
        try {
            if ($file.Attributes -band $readOnly) { $file.Attributes = $file.Attributes -band (-bnot $readOnly) }
            $file.Delete()
        }
        catch {
            $errors.Add("$($file.FullName): $(Get-ResikExceptionReason $_)")
        }
    }
    [pscustomobject]@{ Errors = $errors.ToArray() }
}

function Invoke-ResikScreenshotsDetection {
    $path = Get-ResikScreenshotsFolder
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) {
        return [pscustomobject]@{ Available = $false; Details = 'No Screenshots folder.' }
    }
    [pscustomobject]@{ Available = $true; Details = $path }
}

function Invoke-ResikScreenshotsAnalysis {
    $path = Get-ResikScreenshotsFolder
    $issue = Get-ResikPathSafetyIssue -Path $path
    if ($issue) { throw "Refusing to clean the Screenshots folder: $issue" }
    $size = Measure-ResikScreenshot -Path $path
    if (Test-ResikScreenshotsInOneDrive -Path $path) {
        return [pscustomobject]@{
            EstimatedBytes = $size.Bytes
            Details        = "$path is in OneDrive, so deleting would also delete the copies in the cloud; Resik leaves it alone"
        }
    }
    [pscustomobject]@{
        EstimatedBytes = $size.Bytes
        Details        = "$path ($($size.Files) screenshots; they cannot be recovered after cleaning)"
    }
}

function Invoke-ResikScreenshotsCleanup {
    $path = Get-ResikScreenshotsFolder
    $issue = Get-ResikPathSafetyIssue -Path $path
    if ($issue) { throw "Refusing to clean the Screenshots folder: $issue" }
    if (Test-ResikScreenshotsInOneDrive -Path $path) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "$path is in OneDrive; nothing was deleted." }
    }
    $before = Measure-ResikScreenshot -Path $path
    if ($before.Files -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No screenshots in $path; nothing to clean." }
    }
    Write-Host "Deleting: screenshots ($((Get-ResikScreenshotExtension) -join ', ')) in $path"

    $spinner = Start-ResikSpinner -Message 'Measuring before cleaning'
    try {
        $freeBefore = Get-ResikFreeSpace -Path $path
        Set-ResikSpinnerMessage -Spinner $spinner -Message "Deleting screenshots in $path"
        $deletion = Remove-ResikScreenshotFile -Path $path -Confirm:$false
        Set-ResikSpinnerMessage -Spinner $spinner -Message 'Measuring what was removed'
        $after = Measure-ResikScreenshot -Path $path
        $freeAfter = Get-ResikFreeSpace -Path $path
    }
    finally {
        Stop-ResikSpinner -Spinner $spinner
    }

    $freeChange = if ($null -ne $freeBefore -and $null -ne $freeAfter) { $freeAfter - $freeBefore } else { $null }
    $errors = @($deletion.Errors)
    $removedFiles = [Math]::Max(0, $before.Files - $after.Files)
    if ($errors.Count -eq 0) {
        $status = 'Success'
        $details = "Deleted $removedFiles screenshot(s) in $path"
    }
    else {
        $status = if ($removedFiles -gt 0) { 'PartialSuccess' } else { 'Failed' }
        $details = "Deleted $removedFiles screenshot(s) in $path; $($errors.Count) could not be deleted, for example $($errors[0])"
    }
    [pscustomobject]@{
        Status               = $status
        Details              = $details
        MeasuredBytes        = $before.Bytes - $after.Bytes
        FreeSpaceChangeBytes = $freeChange
    }
}

function New-ResikScreenshotsTarget {
    # A Screenshots folder inside OneDrive gets no Clean, so it is shown as
    # report-only with the reason.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    $path = Get-ResikScreenshotsFolder
    $inOneDrive = $path -and (Test-ResikScreenshotsInOneDrive -Path $path)
    $clean = if ($inOneDrive) { $null } else { { Invoke-ResikScreenshotsCleanup } }
    New-ResikTarget -Id 'screenshots' -Name 'Screenshots' -Category Windows -RiskLevel High -ExplicitOnly `
        -Description ('Permanently deletes the screenshots (PNG, JPEG, GIF, BMP) in your Screenshots folder. ' +
            'They are your own files, are not moved to the Recycle Bin, and cannot be restored. Subfolders ' +
            'and other files are kept. Never chosen by --all or "select all".') `
        -Detect { Invoke-ResikScreenshotsDetection } `
        -Analyze { Invoke-ResikScreenshotsAnalysis } `
        -Clean $clean
}
