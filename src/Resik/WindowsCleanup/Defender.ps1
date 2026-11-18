# Microsoft Defender Antivirus target
# (https://learn.microsoft.com/windows-server/administration/windows-commands/cleanmgr,
# https://learn.microsoft.com/troubleshoot/windows-server/backup-and-storage/automating-disk-cleanup-tool).
#
# Defender protects its own folders, and it has no command that deletes its
# leftover files, so Resik uses Disk Cleanup's "Microsoft Defender Antivirus"
# item (the "Windows Defender" handler under
# HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches, whose
# Folder value lists LocalCopy and Support under
# %ProgramData%\Microsoft\Windows Defender):
#   cleanmgr.exe /sagerun:<n>
# runs the items whose REG_DWORD StateFlags<nnnn> value is 2 (selected); 0
# means not selected. Resik picks a slot no item uses yet, sets 2 on Defender
# and 0 on every other item, so nothing else is cleaned, and removes every
# value it wrote afterwards, even when cleanup fails. Disk Cleanup shows a
# small progress window while it runs. Writing HKLM and reading Defender's
# folders need administrator rights, so without them the target is
# report-only. Definitions, the engine (Platform), scan history, and
# quarantine are not touched; Defender manages those itself.

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

function Get-ResikDefenderDataRoot {
    # %ProgramData%\Microsoft\Windows Defender, as a function so tests can
    # point it at TestDrive.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path $env:ProgramData 'Microsoft\Windows Defender'
}

function Get-ResikDefenderHandlerName {
    'Windows Defender'
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
    # The first slot from 6100 to 6199 that no Disk Cleanup item uses, so a
    # profile the user saved with /sageset is never changed; $null when all
    # are taken.
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

function Get-ResikDefenderFolder {
    # The folders the Defender item cleans, from its Folder value. Only real
    # folders inside Defender's data folder are kept; they are measured, never
    # deleted by Resik.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Handler
    )
    $root = Get-ResikDefenderDataRoot
    foreach ($entry in @("$($Handler.Folder)" -split '\|')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $path = Expand-ResikConfiguredPath -Path $entry
        if ($null -ne (Get-ResikPathSafetyIssue -Path $path)) { continue }
        $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
        if ($full -ieq $root.TrimEnd('\')) { continue }
        if (Test-ResikRealFolder -Path $full -Base $root) { $full }
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

function Get-ResikDefenderHandler {
    # The Defender item and all items, or $null for Defender when Disk
    # Cleanup has none.
    [CmdletBinding()]
    param()
    $all = @(Get-ResikVolumeCacheHandler)
    $defender = $all | Where-Object { $_.Name -eq (Get-ResikDefenderHandlerName) } | Select-Object -First 1
    [pscustomobject]@{ Defender = $defender; All = $all }
}

function Invoke-ResikDefenderDetection {
    $cleanmgr = Get-ResikCleanMgrPath
    if (-not (Test-Path -LiteralPath $cleanmgr -PathType Leaf)) {
        return [pscustomobject]@{ Available = $false; Details = "cleanmgr.exe was not found at $cleanmgr." }
    }
    $handlers = Get-ResikDefenderHandler
    if ($null -eq $handlers.Defender) {
        return [pscustomobject]@{ Available = $false; Details = 'Disk Cleanup has no Microsoft Defender Antivirus item.' }
    }
    [pscustomobject]@{ Available = $true; Details = $cleanmgr }
}

function Invoke-ResikDefenderAnalysis {
    if (-not (Test-ResikAdministrator)) {
        return [pscustomobject]@{
            EstimatedBytes = $null
            Details        = 'Needs administrator rights. To clean it, run Resik in a terminal opened with "Run as administrator".'
        }
    }
    $folders = @(Get-ResikDefenderFolder -Handler (Get-ResikDefenderHandler).Defender)
    if ($folders.Count -eq 0) {
        return [pscustomobject]@{ EstimatedBytes = [long]0; Details = 'Defender has no support files or local copies to clean.' }
    }
    $size = Measure-ResikPathSet -Path $folders
    $estimate = if ($size.Unreadable -gt 0) { $null } else { $size.Bytes }
    [pscustomobject]@{
        EstimatedBytes = $estimate
        Details        = "$($size.Files) file(s) in $($folders -join ', '); Disk Cleanup decides which of them to delete"
    }
}

function Invoke-ResikDefenderCleanup {
    if (-not (Test-ResikAdministrator)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'Needs administrator rights; nothing was changed.' }
    }
    $cleanmgr = Get-ResikCleanMgrPath
    if (-not (Test-Path -LiteralPath $cleanmgr -PathType Leaf)) { throw "cleanmgr.exe was not found at $cleanmgr." }
    $handlers = Get-ResikDefenderHandler
    if ($null -eq $handlers.Defender) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'Disk Cleanup has no Microsoft Defender Antivirus item.' }
    }
    $slot = Get-ResikFreeCleanupSlot -Handler $handlers.All
    if ($null -eq $slot) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'Disk Cleanup slots 6100 to 6199 are all in use; nothing was changed.' }
    }

    $folders = @(Get-ResikDefenderFolder -Handler $handlers.Defender)
    $written = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($handler in $handlers.All) {
            $value = if ($handler.Name -eq $handlers.Defender.Name) { 2 } else { 0 }
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

function New-ResikDefenderTarget {
    # Without administrator rights the target has no Clean, so it is shown as
    # report-only with the reason instead of failing during cleanup.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    $clean = if (Test-ResikAdministrator) { { Invoke-ResikDefenderCleanup } } else { $null }
    New-ResikTarget -Id 'defender' -Name 'Microsoft Defender Antivirus files' -Category Windows -RiskLevel Low `
        -Description ('Deletes the non-critical files Microsoft Defender Antivirus keeps (its Support and LocalCopy ' +
            'folders) with Disk Cleanup''s own item, by running "cleanmgr.exe /sagerun". Definitions, scan history, ' +
            'and quarantine are kept. Disk Cleanup shows a small progress window. Needs administrator rights.') `
        -Detect { Invoke-ResikDefenderDetection } `
        -Analyze { Invoke-ResikDefenderAnalysis } `
        -Clean $clean
}
