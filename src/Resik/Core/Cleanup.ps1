# Cleanup orchestration.
#
# Cleanup runs only after analysis and confirmation (see Invoke-ResikCli). Each
# target's Clean scriptblock runs in isolation: a failure in one target produces
# a Failed result for that target and never stops the rest.

function Measure-ResikPathSet {
    # Total size of several directories; a missing directory counts as zero.
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]] $Path = @()
    )

    $bytes = [long]0
    $files = 0
    $unreadable = 0
    foreach ($item in $Path) {
        if (-not (Test-Path -LiteralPath $item -PathType Container)) { continue }
        $size = Measure-ResikDirectory -Path $item
        $bytes += $size.Bytes
        $files += $size.Files
        $unreadable += $size.Unreadable
    }
    [pscustomobject]@{ Bytes = $bytes; Files = $files; Unreadable = $unreadable }
}

function Invoke-ResikMeasuredCommand {
    <#
    .SYNOPSIS
        Runs a tool's own cleanup command and measures its effect.
    .DESCRIPTION
        Measures MeasurePath before and after the command, and the free space
        on the drive of the first MeasurePath (or FreeSpacePath). Returns an
        outcome for a target's Clean scriptblock. A failed command that still
        removed something is PartialSuccess. Tools that report success but
        leave files behind (Scoop ignores files it cannot delete) are also
        PartialSuccess when ExpectEmpty is set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,

        [AllowEmptyCollection()]
        [string[]] $ArgumentList = @(),

        [AllowEmptyCollection()]
        [string[]] $MeasurePath = @(),

        [string] $FreeSpacePath = '',

        [int] $TimeoutSeconds = 1800,

        [string] $WorkingDirectory = '',

        [switch] $ExpectEmpty
    )

    $freeSpaceAt = if ($FreeSpacePath) { $FreeSpacePath } elseif ($MeasurePath.Count -gt 0) { $MeasurePath[0] } else { '' }
    $canMeasure = $MeasurePath.Count -gt 0
    $display = (@((Split-Path -Leaf $FilePath)) + @($ArgumentList)) -join ' '
    Write-Host "Running: $display (press Ctrl+C to stop)"

    # Nothing may write to the console while the spinner runs.
    $spinner = Start-ResikSpinner -Message 'Measuring before cleaning'
    try {
        $before = if ($canMeasure) { Measure-ResikPathSet -Path $MeasurePath } else { $null }
        $freeBefore = if ($freeSpaceAt) { Get-ResikFreeSpace -Path $freeSpaceAt } else { $null }

        Set-ResikSpinnerMessage -Spinner $spinner -Message "Waiting for $display"
        $run = Invoke-ResikNativeCommand -FilePath $FilePath -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds `
            -WorkingDirectory $WorkingDirectory

        Set-ResikSpinnerMessage -Spinner $spinner -Message 'Measuring what was removed'
        $after = if ($canMeasure) { Measure-ResikPathSet -Path $MeasurePath } else { $null }
        $freeAfter = if ($freeSpaceAt) { Get-ResikFreeSpace -Path $freeSpaceAt } else { $null }
    }
    finally {
        Stop-ResikSpinner -Spinner $spinner
    }

    $measured = $null
    if ($canMeasure -and $before.Unreadable -eq 0 -and $after.Unreadable -eq 0) {
        $measured = $before.Bytes - $after.Bytes
    }
    $freeChange = if ($null -ne $freeBefore -and $null -ne $freeAfter) { $freeAfter - $freeBefore } else { $null }

    if ($run.Status -eq 'Success') {
        $status = 'Success'
        $details = "Ran: $($run.Command)"
        if ($ExpectEmpty -and $canMeasure -and $after.Files -gt 0) {
            $status = 'PartialSuccess'
            $details += "; $($after.Files) file(s) could not be removed, possibly because they are in use"
        }
    }
    else {
        $status = if ($null -ne $measured -and $measured -gt 0) { 'PartialSuccess' } else { 'Failed' }
        $details = Get-ResikNativeCommandFailure $run
    }

    [pscustomobject]@{
        Status               = $status
        Details              = $details
        MeasuredBytes        = $measured
        FreeSpaceChangeBytes = $freeChange
    }
}

function Invoke-ResikTargetCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Target,

        # The estimate from analysis, carried into the result for comparison.
        [Nullable[long]] $EstimatedBytes = $null,

        # True when a person can answer the target's own questions.
        [bool] $CanPrompt = $false,

        # True when the user answered "a" (accept all) at the cleanup prompt,
        # so the target's own questions are answered yes.
        [bool] $AcceptAll = $false
    )

    $ErrorActionPreference = 'Stop'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($null -eq $Target.Clean) {
        return New-ResikResult -TargetId $Target.Id -Operation Clean -Status Unsupported `
            -Message 'This target supports analysis only.' -EstimatedBytes $EstimatedBytes
    }

    try {
        $outcome = & $Target.Clean ([pscustomobject]@{ CanPrompt = $CanPrompt; AcceptAll = $CanPrompt -and $AcceptAll })
        $status = [string](Get-ResikOptionalProperty $outcome 'Status')
        if (@('Success', 'PartialSuccess', 'Failed', 'Skipped') -cnotcontains $status) {
            throw "Cleanup returned an invalid status '$status'."
        }

        $measured = Get-ResikOptionalProperty $outcome 'MeasuredBytes'
        $freeSpace = Get-ResikOptionalProperty $outcome 'FreeSpaceChangeBytes'
        New-ResikResult -TargetId $Target.Id -Operation Clean -Status $status `
            -Message ([string](Get-ResikOptionalProperty $outcome 'Details')) `
            -EstimatedBytes $EstimatedBytes -MeasuredBytes $measured -FreeSpaceChangeBytes $freeSpace `
            -Duration $stopwatch.Elapsed
    }
    catch {
        New-ResikResult -TargetId $Target.Id -Operation Clean -Status Failed `
            -Message "Cleanup failed: $($_.Exception.Message)" -EstimatedBytes $EstimatedBytes `
            -Duration $stopwatch.Elapsed
    }
}

function Invoke-ResikMeasuredDeletion {
    <#
    .SYNOPSIS
        Deletes the matching items in a folder with Remove-ResikDirectoryContent
        and measures the effect.
    .DESCRIPTION
        For targets with no cleanup command of their own. Returns an outcome for
        a target's Clean scriptblock. Items in use are skipped: the result is
        PartialSuccess when something was removed, else Failed. InUseHint is
        added to the details when items were skipped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [string] $Filter = '*',

        [string] $InUseHint = ''
    )

    $issue = Get-ResikPathSafetyIssue -Path $Path
    if ($issue) { throw "Refusing to clean: $issue" }
    Write-Host "Deleting: $(Join-Path $Path $Filter)"

    $spinner = Start-ResikSpinner -Message 'Measuring before cleaning'
    try {
        $before = Measure-ResikDirectoryContent -Path $Path -Filter $Filter
        $freeBefore = Get-ResikFreeSpace -Path $Path
        Set-ResikSpinnerMessage -Spinner $spinner -Message "Deleting files in $Path"
        $deletion = Remove-ResikDirectoryContent -Path $Path -Filter $Filter -Confirm:$false
        Set-ResikSpinnerMessage -Spinner $spinner -Message 'Measuring what was removed'
        $after = Measure-ResikDirectoryContent -Path $Path -Filter $Filter
        $freeAfter = Get-ResikFreeSpace -Path $Path
    }
    finally {
        Stop-ResikSpinner -Spinner $spinner
    }

    $measured = if ($before.Unreadable -eq 0 -and $after.Unreadable -eq 0) { $before.Bytes - $after.Bytes } else { $null }
    $freeChange = if ($null -ne $freeBefore -and $null -ne $freeAfter) { $freeAfter - $freeBefore } else { $null }
    $errors = @($deletion.Errors)

    if ($errors.Count -eq 0) {
        $status = 'Success'
        $details = "Deleted $($before.Files) file(s) in $Path"
    }
    else {
        $removedFiles = [Math]::Max(0, $before.Files - $after.Files)
        $status = if ($removedFiles -gt 0 -or ($null -ne $measured -and $measured -gt 0)) { 'PartialSuccess' } else { 'Failed' }
        $details = "Deleted $removedFiles file(s) in $Path; $($errors.Count) item(s) could not be deleted, for example $($errors[0])"
        if ($InUseHint) { $details += ". $InUseHint" }
    }

    [pscustomobject]@{
        Status               = $status
        Details              = $details
        MeasuredBytes        = $measured
        FreeSpaceChangeBytes = $freeChange
    }
}

function Invoke-ResikMeasuredFolderSetDeletion {
    <#
    .SYNOPSIS
        Empties several folders with Remove-ResikDirectoryContent (each folder
        is kept) and measures the effect as a whole.
    .DESCRIPTION
        For targets whose cache is spread over many small folders (Edge's
        per-profile caches). Every folder must pass Get-ResikPathSafetyIssue
        before anything is deleted. Items in use are skipped: the result is
        PartialSuccess when something was removed, else Failed. Label names
        the cache in the details, such as "the Edge cache".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Path,

        [Parameter(Mandatory)]
        [string] $Label,

        [string] $InUseHint = '',

        # Also delete each folder once it is empty (for folders the owning tool
        # treats as "installed" while they exist, such as node-gyp's headers).
        [switch] $RemoveFolder
    )

    foreach ($folder in $Path) {
        $issue = Get-ResikPathSafetyIssue -Path $folder
        if ($issue) { throw "Refusing to clean ${Label}: $issue" }
    }
    Write-Host "Deleting the contents of $($Path.Count) folder(s) in $Label"

    $errors = New-Object 'System.Collections.Generic.List[string]'
    $spinner = Start-ResikSpinner -Message 'Measuring before cleaning'
    try {
        $before = Measure-ResikPathSet -Path $Path
        $freeBefore = Get-ResikFreeSpace -Path $Path[0]
        foreach ($folder in $Path) {
            Set-ResikSpinnerMessage -Spinner $spinner -Message "Deleting files in $folder"
            try {
                $deletion = Remove-ResikDirectoryContent -Path $folder -Confirm:$false
                foreach ($line in @($deletion.Errors)) { $errors.Add($line) }
                if ($RemoveFolder -and $deletion.Errors.Count -eq 0 -and
                    @([System.IO.Directory]::EnumerateFileSystemEntries($folder)).Count -eq 0) {
                    # Not recursive: an empty folder, or a link, is all it removes.
                    [System.IO.Directory]::Delete($folder, $false)
                }
            }
            catch {
                $errors.Add($_.Exception.Message)
            }
        }
        Set-ResikSpinnerMessage -Spinner $spinner -Message 'Measuring what was removed'
        $after = Measure-ResikPathSet -Path $Path
        $freeAfter = Get-ResikFreeSpace -Path $Path[0]
    }
    finally {
        Stop-ResikSpinner -Spinner $spinner
    }

    $measured = if ($before.Unreadable -eq 0 -and $after.Unreadable -eq 0) { $before.Bytes - $after.Bytes } else { $null }
    $freeChange = if ($null -ne $freeBefore -and $null -ne $freeAfter) { $freeAfter - $freeBefore } else { $null }
    $removedFiles = [Math]::Max(0, $before.Files - $after.Files)

    if ($errors.Count -eq 0) {
        $status = 'Success'
        $details = "Deleted $($before.Files) file(s) in $Label"
    }
    else {
        $status = if ($removedFiles -gt 0 -or ($null -ne $measured -and $measured -gt 0)) { 'PartialSuccess' } else { 'Failed' }
        $details = "Deleted $removedFiles file(s) in $Label; $($errors.Count) item(s) could not be deleted, for example $($errors[0])"
        if ($InUseHint) { $details += ". $InUseHint" }
    }

    [pscustomobject]@{
        Status               = $status
        Details              = $details
        MeasuredBytes        = $measured
        FreeSpaceChangeBytes = $freeChange
    }
}

function New-ResikAgedFileLocation {
    # Describes where Invoke-ResikMeasuredAgedDeletion looks: files matching
    # Include in Path (and its subfolders with Recurse) last written and
    # created before Before. PruneFolders also removes subfolders that are
    # empty afterwards and were created before Before.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [datetime] $Before,

        [string[]] $Include = @('*'),

        [switch] $Recurse,

        [switch] $PruneFolders,

        # Path is itself a protected location (TEMP) that may still be
        # searched: only files and empty subfolders in it are deleted.
        [switch] $AllowProtectedRoot
    )
    [pscustomobject]@{
        Path               = $Path
        Before             = $Before
        Include            = $Include
        Recurse            = [bool]$Recurse
        PruneFolders       = [bool]$PruneFolders
        AllowProtectedRoot = [bool]$AllowProtectedRoot
    }
}

function Get-ResikAgedFileLocationProtection {
    # The protected paths that apply to a location: all of them, minus the
    # location itself when it allows a protected root.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Location
    )
    $full = [System.IO.Path]::GetFullPath($Location.Path).TrimEnd('\')
    foreach ($protected in @(Get-ResikProtectedPath)) {
        if ($Location.AllowProtectedRoot -and $protected -ieq $full) { continue }
        $protected
    }
}

function Measure-ResikAgedFileLocation {
    # Sums Get-ResikAgedFile over several locations: Bytes, Files, Unreadable.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Location
    )
    $bytes = [long]0
    $files = 0
    $unreadable = 0
    foreach ($place in $Location) {
        $found = Get-ResikAgedFile -Path $place.Path -Before $place.Before -Include $place.Include -Recurse:$place.Recurse
        $bytes += $found.Bytes
        $files += @($found.Files).Count
        $unreadable += $found.Unreadable
    }
    [pscustomobject]@{ Bytes = $bytes; Files = $files; Unreadable = $unreadable }
}

function Invoke-ResikMeasuredAgedDeletion {
    <#
    .SYNOPSIS
        Deletes old files in several locations and measures the effect.
    .DESCRIPTION
        For Windows targets with no cleanup command (temporary files, logs).
        Each location must pass Get-ResikPathSafetyIssue; files are found again
        here rather than taken from the analysis. Files in use are skipped:
        the result is PartialSuccess when something was removed, else Failed.
        MeasuredBytes is the size of the files that were actually deleted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Location,

        [Parameter(Mandatory)]
        [string] $Label,

        [string] $InUseHint = ''
    )

    foreach ($place in $Location) {
        $issue = Get-ResikPathSafetyIssue -Path $place.Path -ProtectedPath @(Get-ResikAgedFileLocationProtection -Location $place)
        if ($issue) { throw "Refusing to clean ${Label}: $issue" }
    }
    Write-Host "Deleting old files in $(@($Location | ForEach-Object { $_.Path }) -join ', ')"

    $errors = New-Object 'System.Collections.Generic.List[string]'
    $removedBytes = [long]0
    $removedFiles = 0
    $removedFolders = 0
    $spinner = Start-ResikSpinner -Message "Finding old files in $Label"
    try {
        $freeBefore = Get-ResikFreeSpace -Path $Location[0].Path
        foreach ($place in $Location) {
            Set-ResikSpinnerMessage -Spinner $spinner -Message "Deleting old files in $($place.Path)"
            try {
                $found = Get-ResikAgedFile -Path $place.Path -Before $place.Before -Include $place.Include -Recurse:$place.Recurse
                $protection = @(Get-ResikAgedFileLocationProtection -Location $place)
                $deletion = Remove-ResikAgedFile -File $found.Files -Scope $place.Path -ProtectedPath $protection -Confirm:$false
                $removedBytes += $deletion.RemovedBytes
                $removedFiles += $deletion.RemovedFiles
                foreach ($line in @($deletion.Errors)) { $errors.Add($line) }
                if ($place.PruneFolders) {
                    $removedFolders += Remove-ResikEmptyFolder -Path $place.Path -Before $place.Before -ProtectedPath $protection -Confirm:$false
                }
            }
            catch {
                $errors.Add($_.Exception.Message)
            }
        }
        $freeAfter = Get-ResikFreeSpace -Path $Location[0].Path
    }
    finally {
        Stop-ResikSpinner -Spinner $spinner
    }

    $details = "Deleted $removedFiles file(s) in $Label"
    if ($removedFolders -gt 0) { $details += " and $removedFolders empty folder(s)" }
    if ($errors.Count -eq 0) {
        $status = 'Success'
    }
    else {
        $status = if ($removedFiles -gt 0) { 'PartialSuccess' } else { 'Failed' }
        $details += "; $($errors.Count) file(s) could not be deleted, for example $($errors[0])"
        if ($InUseHint) { $details += ". $InUseHint" }
    }
    [pscustomobject]@{
        Status               = $status
        Details              = $details
        MeasuredBytes        = $removedBytes
        FreeSpaceChangeBytes = $(if ($null -ne $freeBefore -and $null -ne $freeAfter) { $freeAfter - $freeBefore } else { $null })
    }
}
