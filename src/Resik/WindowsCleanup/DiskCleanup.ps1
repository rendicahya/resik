# Running one of Disk Cleanup's own items
# (https://learn.microsoft.com/windows-server/administration/windows-commands/cleanmgr,
# https://learn.microsoft.com/troubleshoot/windows-server/backup-and-storage/automating-disk-cleanup-tool).
#
# Each Disk Cleanup item is a key under
# HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches.
#   cleanmgr.exe /sagerun:<n>
# runs the items whose REG_DWORD StateFlags<nnnn> value is 2 (selected); 0
# means not selected. Resik picks a slot no item uses yet, so a profile the
# user saved with /sageset is never changed, sets 2 on the one item and 0 on
# every other item, so nothing else is cleaned, and removes every value it
# wrote afterwards, even when cleanup fails. A target may run several items
# at once (memory dumps are two items). Disk Cleanup shows a small progress
# window while it runs. Writing HKLM needs administrator rights, so targets
# built on this have no Clean without them. Resik never deletes the items'
# files itself; it only measures the folders the items name, or the files and
# folders the target names, before and after.

function Get-ResikCleanMgrPath {
    # The 64-bit cleanmgr.exe, also from a 32-bit PowerShell on 64-bit Windows.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $system = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        Join-Path $env:SystemRoot 'Sysnative'
    }
    else {
        [Environment]::SystemDirectory
    }
    Join-Path $system 'cleanmgr.exe'
}

function Get-ResikVolumeCacheHandler {
    # One record per Disk Cleanup item: Name, Path (the registry key), Folder
    # (its Folder value, or ''), and ValueNames.
    [CmdletBinding()]
    param()
    $root = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
    foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction Stop)) {
        [pscustomobject]@{
            Name       = $key.PSChildName
            Path       = $key.PSPath
            Folder     = [string]$key.GetValue('Folder', '')
            ValueNames = @($key.GetValueNames())
        }
    }
}

function Get-ResikCleanupSlotName {
    param([int] $Slot)
    'StateFlags{0:D4}' -f $Slot
}

function Get-ResikFreeCleanupSlot {
    # The first slot from 6100 to 6199 that no Disk Cleanup item uses; $null
    # when all are taken.
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]] $Handler = @()
    )
    foreach ($slot in 6100..6199) {
        $name = Get-ResikCleanupSlotName $slot
        $used = @($Handler | Where-Object { @($_.ValueNames) -contains $name })
        if ($used.Count -eq 0) { return $slot }
    }
    $null
}

function Get-ResikDiskCleanupHandler {
    # The named items Disk Cleanup has (Items, possibly empty) and all items.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Name
    )
    $all = @(Get-ResikVolumeCacheHandler)
    $items = @($all | Where-Object { $Name -contains $_.Name })
    [pscustomobject]@{ Items = $items; All = $all }
}

function Get-ResikDiskCleanupMeasurePath {
    # What a target measures: the real folders inside Root that its items
    # name (when Root is given), plus MeasurePath.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Handler = @(),

        [string] $Root = '',

        [AllowEmptyCollection()]
        [string[]] $MeasurePath = @()
    )
    if ($Root) {
        foreach ($item in $Handler) { Get-ResikDiskCleanupFolder -Handler $item -Root $Root }
    }
    foreach ($path in $MeasurePath) { $path }
}

function Get-ResikDiskCleanupFolder {
    # The folders an item cleans, from its Folder value ("a|b"). Only real
    # folders that are Root or inside it are kept; they are measured, never
    # deleted by Resik.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Handler,

        [Parameter(Mandatory)]
        [string] $Root
    )
    foreach ($entry in @("$($Handler.Folder)" -split '\|')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $path = Expand-ResikConfiguredPath -Path $entry
        if ($null -ne (Get-ResikPathSafetyIssue -Path $path)) { continue }
        $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
        if (Test-ResikRealFolder -Path $full -Base $Root) { $full }
    }
}

function Set-ResikVolumeCacheStateFlag {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [int] $Slot,

        [Parameter(Mandatory)]
        [ValidateSet(0, 2)]
        [int] $Value
    )
    $name = Get-ResikCleanupSlotName $Slot
    if ($PSCmdlet.ShouldProcess("$Path\$name", "Set to $Value")) {
        New-ItemProperty -LiteralPath $Path -Name $name -PropertyType DWord -Value $Value -Force -ErrorAction Stop | Out-Null
    }
}

function Remove-ResikVolumeCacheStateFlag {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [int] $Slot
    )
    $name = Get-ResikCleanupSlotName $Slot
    if ($PSCmdlet.ShouldProcess("$Path\$name", 'Remove')) {
        Remove-ItemProperty -LiteralPath $Path -Name $name -ErrorAction Stop
    }
}

function Invoke-ResikDiskCleanupDetection {
    # Available when cleanmgr.exe exists and Disk Cleanup has at least one of
    # the items.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Name,

        [Parameter(Mandatory)]
        [string] $Label
    )
    $cleanmgr = Get-ResikCleanMgrPath
    if (-not (Test-Path -LiteralPath $cleanmgr -PathType Leaf)) {
        return [pscustomobject]@{ Available = $false; Details = "cleanmgr.exe was not found at $cleanmgr." }
    }
    if (@((Get-ResikDiskCleanupHandler -Name $Name).Items).Count -eq 0) {
        return [pscustomobject]@{ Available = $false; Details = "Disk Cleanup has no $Label item." }
    }
    [pscustomobject]@{ Available = $true; Details = $cleanmgr }
}

function Invoke-ResikDiskCleanupAnalysis {
    # Measures the items' folders inside Root and MeasurePath; changes
    # nothing. With Unmeasured (items whose files Windows does not list), the
    # estimate is unknown and UnmeasuredDetails explains it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Name,

        [string] $Root = '',

        [AllowEmptyCollection()]
        [string[]] $MeasurePath = @(),

        [Parameter(Mandatory)]
        [string] $EmptyDetails,

        [switch] $Unmeasured,

        [string] $UnmeasuredDetails = ''
    )
    if (-not (Test-ResikAdministrator)) {
        return [pscustomobject]@{
            EstimatedBytes = $null
            Details        = 'Needs administrator rights. To clean it, run Resik in a terminal opened with "Run as administrator".'
        }
    }
    if ($Unmeasured) {
        return [pscustomobject]@{ EstimatedBytes = $null; Details = $UnmeasuredDetails }
    }
    $handlers = Get-ResikDiskCleanupHandler -Name $Name
    $paths = @(Get-ResikDiskCleanupMeasurePath -Handler $handlers.Items -Root $Root -MeasurePath $MeasurePath)
    if ($paths.Count -eq 0) {
        return [pscustomobject]@{ EstimatedBytes = [long]0; Details = $EmptyDetails }
    }
    $size = Measure-ResikPathSet -Path $paths
    if ($size.Files -eq 0 -and $size.Unreadable -eq 0) {
        return [pscustomobject]@{ EstimatedBytes = [long]0; Details = $EmptyDetails }
    }
    $estimate = if ($size.Unreadable -gt 0) { $null } else { $size.Bytes }
    $where = if ($paths.Count -le 3) { $paths -join ', ' } else { "$($paths.Count) places" }
    $details = "$($size.Files) file(s) in $where; Disk Cleanup decides which of them to delete"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $estimate; Details = $details }
}

function Invoke-ResikDiskCleanupItem {
    # Runs only the named Disk Cleanup items and measures the items' folders
    # inside Root and MeasurePath.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Name,

        [Parameter(Mandatory)]
        [string] $Label,

        [string] $Root = '',

        [AllowEmptyCollection()]
        [string[]] $MeasurePath = @()
    )
    if (-not (Test-ResikAdministrator)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'Needs administrator rights; nothing was changed.' }
    }
    $cleanmgr = Get-ResikCleanMgrPath
    if (-not (Test-Path -LiteralPath $cleanmgr -PathType Leaf)) { throw "cleanmgr.exe was not found at $cleanmgr." }
    $handlers = Get-ResikDiskCleanupHandler -Name $Name
    if (@($handlers.Items).Count -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "Disk Cleanup has no $Label item." }
    }
    $slot = Get-ResikFreeCleanupSlot -Handler $handlers.All
    if ($null -eq $slot) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'Disk Cleanup slots 6100 to 6199 are all in use; nothing was changed.' }
    }

    $selected = @($handlers.Items | ForEach-Object { $_.Name })
    $folders = @(Get-ResikDiskCleanupMeasurePath -Handler $handlers.Items -Root $Root -MeasurePath $MeasurePath)
    $written = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($handler in $handlers.All) {
            $value = if ($selected -contains $handler.Name) { 2 } else { 0 }
            Set-ResikVolumeCacheStateFlag -Path $handler.Path -Slot $slot -Value $value -Confirm:$false
            $written.Add($handler.Path)
        }
        Invoke-ResikMeasuredCommand -FilePath $cleanmgr -ArgumentList @("/sagerun:$slot") -MeasurePath $folders `
            -FreeSpacePath ($env:SystemDrive + '\') -TimeoutSeconds 1800
    }
    finally {
        # Every value written is removed, even when one removal fails.
        foreach ($path in $written) {
            try { Remove-ResikVolumeCacheStateFlag -Path $path -Slot $slot -Confirm:$false }
            catch { Write-Warning "Could not remove $(Get-ResikCleanupSlotName $slot) from ${path}: $($_.Exception.Message)" }
        }
    }
}
