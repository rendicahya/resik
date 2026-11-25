# Chocolatey file targets: what Chocolatey leaves behind and has no command for
# ("choco optimize" and the Package Reducer need a licensed edition).
#
#   choco-downloads   <temp>\chocolatey: installers Chocolatey downloaded and
#                     unpacked. No administrator rights needed; %WINDIR%\Temp\
#                     chocolatey is included only with them. Chocolatey's
#                     cacheLocation setting replaces this folder; a folder the
#                     user chose could hold other files, so it is report-only.
#   choco-logs        rotated logs in <root>\logs (chocolatey.<n>.log and
#                     choco.summary.<n>.log, 10 MB each); current logs are kept
#   choco-leftovers   <root>\lib-bad (packages whose install failed), <root>\
#                     lib-bkp (backups kept when an upgrade was interrupted),
#                     <root>\.chocolatey\<id>.<version> records of packages or
#                     versions that are no longer installed, and the *.old
#                     files Chocolatey leaves when it upgrades itself
#   choco-shims       shims in <root>\bin whose program no longer exists
#   choco-installers  installers and archives inside <root>\lib\<id>\tools that
#                     the package's install script already used
#
# Everything in <root> needs administrator rights: without them those targets
# are report-only, like windows-update. Nothing is deleted while choco.exe runs.
# Verified against Chocolatey CLI 2.7.3 as installed, its source (logging,
# package information, failed-package and backup folders, shims), and the
# Package Reducer documentation (file types, .SkipReducer).
#
# Deliberately kept, because Chocolatey uses them later: *.ignore files (read
# when a package's shims are removed, or it would delete another package's
# shim), <name>.zip.txt lists (Uninstall-ChocolateyZipPackage reads them to know
# what to delete), chocolatey.config.backup (restored when the configuration is
# corrupt), and the .nupkg of each installed package. License and readme files
# are kept too.

function Get-ResikChocolateyRoot {
    # Chocolatey's install folder; tests point it at TestDrive.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $configured = [Environment]::GetEnvironmentVariable('ChocolateyInstall')
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        return (Expand-ResikConfiguredPath -Path $configured).TrimEnd('\')
    }
    Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'chocolatey'
}

function Test-ResikChocolateyRoot {
    # A folder is only treated as Chocolatey's when choco.exe and lib are in it.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )
    (Test-Path -LiteralPath (Join-Path $Root 'choco.exe') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $Root 'lib') -PathType Container)
}

function Get-ResikCheckedChocolateyRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $root = Get-ResikCheckedAppRoot -Root (Get-ResikChocolateyRoot) -AppName 'Chocolatey'
    if (-not (Test-ResikChocolateyRoot -Root $root)) { throw "Chocolatey was not found in $root." }
    $root
}

function Test-ResikChocolateyRunning {
    # In any session: another user's install uses the same folders.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    @(Get-Process -Name 'choco' -ErrorAction SilentlyContinue).Count -gt 0
}

function Invoke-ResikChocolateyRootDetection {
    $root = Get-ResikChocolateyRoot
    if (-not (Test-ResikChocolateyRoot -Root $root)) {
        return [pscustomobject]@{ Available = $false; Details = "Chocolatey was not found in $root." }
    }
    [pscustomobject]@{ Available = $true; Details = $root }
}

function Get-ResikChocolateyFileSet {
    # The items a target deletes: Content (folders to empty but keep), Tree
    # (folders to delete), and File (single files).
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]] $Content = @(),

        [AllowEmptyCollection()]
        [string[]] $Tree = @(),

        [AllowEmptyCollection()]
        [string[]] $File = @(),

        [string] $Note = ''
    )
    [pscustomobject]@{ Content = $Content; Tree = $Tree; File = $File; Note = $Note; All = @($Content) + @($Tree) + @($File) }
}

function Invoke-ResikChocolateyFileAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Set,

        # What the files are, such as 'rotated log'.
        [Parameter(Mandatory)]
        [string] $Label,

        [Parameter(Mandatory)]
        [string] $Where
    )
    $size = Measure-ResikPathSet -Path $Set.All
    $details = if ($size.Files -eq 0) { "No $Label in $Where" } else { "$($size.Files) $Label in $Where" }
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    if ($Set.Note) { $details += "; $($Set.Note)" }
    if ($size.Files -gt 0 -and -not (Test-ResikAdministrator)) {
        $details += '. Needs administrator rights. To clean it, run Resik in a terminal opened with "Run as administrator"'
    }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Get-ResikChocolateyRefusal {
    # A Skipped result when the install folder must not be changed now.
    if (-not (Test-ResikAdministrator)) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'Needs administrator rights; nothing was changed.' }
    }
    if (Test-ResikChocolateyRunning) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'Chocolatey is running. Wait until it finishes, then try again. Nothing was removed.' }
    }
}

function Invoke-ResikChocolateyFileDeletion {
    <#
    .SYNOPSIS
        Deletes a file set inside Chocolatey's folder and measures the effect.
    .DESCRIPTION
        Every path must be inside Root; links are never followed. Items that
        cannot be deleted are skipped and reported.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Set,

        [Parameter(Mandatory)]
        [string] $Root,

        [Parameter(Mandatory)]
        [string] $Label
    )

    if (@($Set.All).Count -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No $Label; nothing to clean." }
    }
    foreach ($folder in @($Set.Content) + @($Set.Tree)) {
        $issue = Get-ResikPathSafetyIssue -Path $folder
        if ($issue) { throw "Refusing to clean ${Label}: $issue" }
        if (-not (Test-ResikRealFolder -Path $folder -Base $Root)) { throw "Refusing to clean ${Label}: $folder is not a real folder in $Root." }
    }
    foreach ($file in @($Set.File)) {
        if (-not (Test-ResikRealFolder -Path (Split-Path -Parent $file) -Base $Root)) {
            throw "Refusing to clean ${Label}: $file is not in a real folder in $Root."
        }
    }
    Write-Host "Deleting $Label in $Root"

    $errors = New-Object 'System.Collections.Generic.List[string]'
    $spinner = Start-ResikSpinner -Message 'Measuring before cleaning'
    try {
        $before = Measure-ResikPathSet -Path $Set.All
        $freeBefore = Get-ResikFreeSpace -Path $Root
        Set-ResikSpinnerMessage -Spinner $spinner -Message "Deleting $Label"
        $deletions = @(
            foreach ($folder in @($Set.Content)) { Remove-ResikDirectoryContent -Path $folder -Confirm:$false }
            foreach ($folder in @($Set.Tree)) { Remove-ResikDirectoryTree -Path $folder -Scope $Root -Confirm:$false }
            if (@($Set.File).Count -gt 0) {
                $files = @($Set.File | ForEach-Object { New-Object System.IO.FileInfo $_ })
                Remove-ResikAgedFile -File $files -Scope $Root -Confirm:$false
            }
        )
        foreach ($deletion in $deletions) {
            foreach ($line in @($deletion.Errors)) { $errors.Add($line) }
        }
        Set-ResikSpinnerMessage -Spinner $spinner -Message 'Measuring what was removed'
        $after = Measure-ResikPathSet -Path $Set.All
        $freeAfter = Get-ResikFreeSpace -Path $Root
    }
    finally {
        Stop-ResikSpinner -Spinner $spinner
    }

    $measured = if ($before.Unreadable -eq 0 -and $after.Unreadable -eq 0) { $before.Bytes - $after.Bytes } else { $null }
    $removedFiles = [Math]::Max(0, $before.Files - $after.Files)
    $details = "Deleted $removedFiles $Label in $Root"
    $status = 'Success'
    if ($errors.Count -gt 0) {
        $status = if ($removedFiles -gt 0) { 'PartialSuccess' } else { 'Failed' }
        $details += "; $($errors.Count) item(s) could not be deleted, for example $($errors[0])"
    }
    [pscustomobject]@{
        Status               = $status
        Details              = $details
        MeasuredBytes        = $measured
        FreeSpaceChangeBytes = $(if ($null -ne $freeBefore -and $null -ne $freeAfter) { $freeAfter - $freeBefore } else { $null })
    }
}

# --- choco-downloads ---------------------------------------------------------

function Get-ResikChocolateyCacheSetting {
    # The cacheLocation value in chocolatey.config, or '' when it is not set.
    # "choco config get" is not used: without administrator rights it stops to
    # ask a question.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $file = Join-Path (Get-ResikChocolateyRoot) 'config\chocolatey.config'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
    $document = New-Object System.Xml.XmlDocument
    $document.XmlResolver = $null
    $document.Load($file)
    $node = $document.SelectSingleNode("/chocolatey/config/add[@key='cacheLocation']")
    if ($null -eq $node) { return '' }
    $value = $node.GetAttribute('value')
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }
    Expand-ResikConfiguredPath -Path $value
}

function Get-ResikChocolateyDownloadFolder {
    # The existing default download folders, after the safety checks.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $bases = @(Get-ResikUserTempPath)
    if (Test-ResikAdministrator) {
        $windowsTemp = Get-ResikWindowsTempPath
        if ($bases -notcontains $windowsTemp) { $bases += $windowsTemp }
    }
    foreach ($base in $bases) {
        $folder = Join-Path $base 'chocolatey'
        if (Test-ResikRealFolder -Path $folder -Base $base) { $folder }
    }
}

function Invoke-ResikChocolateyDownloadDetection {
    $setting = Get-ResikChocolateyCacheSetting
    $found = @(if ($setting) { $setting | Where-Object { Test-Path -LiteralPath $_ -PathType Container } } else { Get-ResikChocolateyDownloadFolder })
    if ($found.Count -eq 0) {
        return [pscustomobject]@{ Available = $false; Details = 'No Chocolatey download folder.' }
    }
    [pscustomobject]@{ Available = $true; Details = $found -join ', ' }
}

function Invoke-ResikChocolateyDownloadAnalysis {
    $setting = Get-ResikChocolateyCacheSetting
    if ($setting) {
        $size = Measure-ResikPathSet -Path @($setting)
        return [pscustomobject]@{
            EstimatedBytes = $size.Bytes
            Details        = "$setting ($($size.Files) files). Chocolatey's cacheLocation setting moved the downloads here, so Resik only reports the size; delete them yourself if the folder holds nothing else"
        }
    }
    $folders = @(Get-ResikChocolateyDownloadFolder)
    Invoke-ResikAppFolderAnalysis -Path $folders -Where (Get-ResikUserTempPath)
}

function Invoke-ResikChocolateyDownloadCleanup {
    if (Get-ResikChocolateyCacheSetting) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "Chocolatey's cacheLocation setting moved the downloads; nothing was removed." }
    }
    if (Test-ResikChocolateyRunning) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'Chocolatey is running. Wait until it finishes, then try again. Nothing was removed.' }
    }
    Invoke-ResikAppFolderCleanup -Path @(Get-ResikChocolateyDownloadFolder) -Where (Get-ResikUserTempPath) `
        -Label 'the Chocolatey downloads'
}

function New-ResikChocolateyDownloadTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    # An unreadable configuration is reported by the analysis.
    $moved = try { [bool](Get-ResikChocolateyCacheSetting) } catch { $true }
    $clean = if ($moved) { $null } else { { Invoke-ResikChocolateyDownloadCleanup } }
    New-ResikTarget -Id 'choco-downloads' -Name 'Chocolatey downloads' -Category Developer -RiskLevel Low -Group 'Chocolatey' `
        -Description ('Deletes installers Chocolatey downloaded and unpacked in %TEMP%\chocolatey (and, as ' +
            'administrator, in %WINDIR%\Temp\chocolatey). Installed packages are not touched.') `
        -Detect { Invoke-ResikChocolateyDownloadDetection } `
        -Analyze { Invoke-ResikChocolateyDownloadAnalysis } `
        -Clean $clean
}

# --- choco-logs --------------------------------------------------------------

function Get-ResikChocolateyLogSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )
    $logs = Join-Path $Root 'logs'
    $files = @()
    if (Test-ResikRealFolder -Path $logs -Base $Root) {
        $files = @(Get-ChildItem -LiteralPath $logs -File -Force -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -match '^(chocolatey|choco\.summary)\.\d+\.log$' -and
                -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
            } | ForEach-Object { $_.FullName })
    }
    Get-ResikChocolateyFileSet -File $files
}

function New-ResikChocolateyLogTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    $clean = if (Test-ResikAdministrator) {
        {
            $refusal = Get-ResikChocolateyRefusal
            if ($refusal) { return $refusal }
            $root = Get-ResikCheckedChocolateyRoot
            Invoke-ResikChocolateyFileDeletion -Set (Get-ResikChocolateyLogSet -Root $root) -Root $root -Label 'rotated log(s)'
        }
    }
    else { $null }
    New-ResikTarget -Id 'choco-logs' -Name 'Chocolatey old logs' -Category Developer -RiskLevel Low -Group 'Chocolatey' `
        -Description ('Deletes rotated Chocolatey logs (chocolatey.<n>.log and choco.summary.<n>.log). The current ' +
            'logs are kept. Needs administrator rights.') `
        -Detect { Invoke-ResikChocolateyRootDetection } `
        -Analyze {
            $root = Get-ResikCheckedChocolateyRoot
            Invoke-ResikChocolateyFileAnalysis -Set (Get-ResikChocolateyLogSet -Root $root) -Label 'rotated log(s)' -Where (Join-Path $root 'logs')
        } `
        -Clean $clean
}

# --- choco-leftovers ---------------------------------------------------------

function ConvertTo-ResikChocolateyVersion {
    # A version in a form that can be compared: four numbers, then any
    # prerelease label in lower case ('1.2' -> '1.2.0.0'). $null when Text is
    # not a version. Chocolatey names a record after the normalized version,
    # which can be written differently from what "choco list" shows.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Text
    )
    if ($Text -notmatch '^(?<numbers>\d+(\.\d+){0,3})(?<label>-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$') { return $null }
    $label = if ($Matches.ContainsKey('label')) { $Matches['label'].ToLowerInvariant() } else { '' }
    $numbers = @($Matches['numbers'].Split('.') | ForEach-Object {
            $trimmed = $_.TrimStart('0')
            if ($trimmed) { $trimmed } else { '0' }
        })
    while ($numbers.Count -lt 4) { $numbers += '0' }
    ($numbers -join '.') + $label
}

function Get-ResikChocolateyInstalledPackage {
    # The installed packages (Id, Version), or nothing when they cannot be
    # listed reliably. Before version 2, "choco list" searched the remote
    # sources, so older versions are not asked.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )
    $choco = Join-Path $Root 'choco.exe'
    if ((Get-ResikChocolateyMajorVersion -Path $choco) -lt 2) { return }
    $run = Invoke-ResikNativeCommand -FilePath $choco -ArgumentList @('list', '--limit-output') -TimeoutSeconds 120
    if ($run.Status -ne 'Success') { return }
    $packages = @(foreach ($line in $run.StdOut -split "`r?`n") {
            if ($line -match '^(?<id>[^|\s]+)\|(?<version>[^|\s]+)\s*$') {
                [pscustomobject]@{ Id = $Matches['id']; Version = $Matches['version'] }
            }
        })
    # Chocolatey always lists itself; without it the output is not trusted.
    if (@($packages | Where-Object { $_.Id -ieq 'chocolatey' }).Count -eq 0) { return }
    $packages
}

function Get-ResikChocolateyMajorVersion {
    # As a function so tests can mock it.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )
    [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path).ProductMajorPart
}

function Test-ResikChocolateyRecordOrphaned {
    # True when a .chocolatey\<id>.<version> folder belongs to no installed
    # package version. Anything that cannot be told apart for sure is kept.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [object[]] $Package,

        # Names of the folders in lib.
        [AllowEmptyCollection()]
        [string[]] $LibFolder = @()
    )
    if ($Name -notmatch '^[^.].*?\.\d+(\.\d+)+(-[0-9A-Za-z.-]+)?$') { return $false }
    foreach ($installed in $Package) {
        if (-not $Name.StartsWith("$($installed.Id).", [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $installedVersion = ConvertTo-ResikChocolateyVersion -Text $installed.Version
        if (-not $installedVersion) { return $false }
        if ((ConvertTo-ResikChocolateyVersion -Text $Name.Substring($installed.Id.Length + 1)) -ceq $installedVersion) { return $false }
    }
    # A package folder Chocolatey does not list may be a broken install.
    $ids = @($Package | ForEach-Object { $_.Id })
    foreach ($folder in $LibFolder) {
        if ($ids -notcontains $folder -and $Name.StartsWith("$folder.", [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    $true
}

function Get-ResikChocolateyOldFile {
    # What Chocolatey's setup renames when it upgrades itself. It removes them
    # on a later run, unless that failed.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )
    foreach ($place in @(
            @{ Folder = $Root; Pattern = 'choco.exe.old' }
            @{ Folder = (Join-Path $Root 'bin'); Pattern = '*.exe.old' }
            @{ Folder = (Join-Path $Root 'helpers'); Pattern = 'Chocolatey.PowerShell.dll.old' }
        )) {
        if (-not (Test-ResikRealFolder -Path $place.Folder -Base $Root)) { continue }
        Get-ChildItem -LiteralPath $place.Folder -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $place.Pattern -and -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } |
            ForEach-Object { $_.FullName }
    }
}

function Get-ResikChocolateyLeftoverSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )
    $content = @(Get-ResikExistingFolder -Path @((Join-Path $Root 'lib-bad'), (Join-Path $Root 'lib-bkp')) -Base $Root)
    $records = @()
    $note = ''
    $store = Join-Path $Root '.chocolatey'
    if (Test-ResikRealFolder -Path $store -Base $Root) {
        $packages = @(Get-ResikChocolateyInstalledPackage -Root $Root)
        if ($packages.Count -eq 0) {
            $note = 'package records were not checked, because the installed packages could not be listed'
        }
        else {
            $lib = @(Get-ChildItem -LiteralPath (Join-Path $Root 'lib') -Directory -Force | ForEach-Object { $_.Name })
            $records = @(Get-ChildItem -LiteralPath $store -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { Test-ResikChocolateyRecordOrphaned -Name $_.Name -Package $packages -LibFolder $lib } |
                    ForEach-Object { $_.FullName })
            $records = @(Get-ResikExistingFolder -Path $records -Base $Root)
        }
    }
    Get-ResikChocolateyFileSet -Content $content -Tree $records -File @(Get-ResikChocolateyOldFile -Root $Root) -Note $note
}

function New-ResikChocolateyLeftoverTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    $clean = if (Test-ResikAdministrator) {
        {
            $refusal = Get-ResikChocolateyRefusal
            if ($refusal) { return $refusal }
            $root = Get-ResikCheckedChocolateyRoot
            Invoke-ResikChocolateyFileDeletion -Set (Get-ResikChocolateyLeftoverSet -Root $root) -Root $root -Label 'leftover file(s)'
        }
    }
    else { $null }
    New-ResikTarget -Id 'choco-leftovers' -Name 'Chocolatey leftovers' -Category Developer -RiskLevel Medium -Group 'Chocolatey' `
        -Description ('Deletes packages whose install failed (lib-bad), backups from interrupted upgrades (lib-bkp), ' +
            'records of package versions that are no longer installed, and *.old files from Chocolatey''s own ' +
            'upgrades. You can no longer restore a failed package from them. Needs administrator rights.') `
        -Detect { Invoke-ResikChocolateyRootDetection } `
        -Analyze {
            $root = Get-ResikCheckedChocolateyRoot
            Invoke-ResikChocolateyFileAnalysis -Set (Get-ResikChocolateyLeftoverSet -Root $root) -Label 'leftover file(s)' -Where $root
        } `
        -Clean $clean
}

# --- choco-shims -------------------------------------------------------------

function Test-ResikChocolateyShim {
    # Only files shimgen marked as a shim are ever run, because any other
    # program would ignore --shimgen-help and simply start.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )
    $version = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    "$($version.FileDescription)".EndsWith('- Chocolatey Shim') -or "$($version.ProductName)".EndsWith('- Chocolatey Shim')
}

function Get-ResikChocolateyShimTarget {
    # The program a shim starts, or $null. --shimgen-help only prints it; the
    # exit code depends on whether the program exists, so it is not checked.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )
    $run = Invoke-ResikNativeCommand -FilePath $Path -ArgumentList @('--shimgen-help') -TimeoutSeconds 15
    if (@('Success', 'NonZeroExit') -notcontains $run.Status) { return $null }
    if ($run.StdOut -notmatch "generated by Chocolatey's ShimGenerator") { return $null }
    if ($run.StdOut -notmatch "(?m)^\s*Target: '(?<target>[A-Za-z]:\\[^'\r\n]+)'\s*$") { return $null }
    $Matches['target']
}

function Get-ResikChocolateyOrphanShimSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )
    $bin = Join-Path $Root 'bin'
    $orphans = @()
    if (Test-ResikRealFolder -Path $bin -Base $Root) {
        $orphans = @(foreach ($file in @(Get-ChildItem -LiteralPath $bin -File -Force -ErrorAction SilentlyContinue)) {
                if ($file.Extension -ine '.exe' -or ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { continue }
                if (-not (Test-ResikChocolateyShim -Path $file.FullName)) { continue }
                $target = Get-ResikChocolateyShimTarget -Path $file.FullName
                # A drive that is not connected says nothing about the program.
                if (-not $target -or -not (Test-Path -LiteralPath ([System.IO.Path]::GetPathRoot($target)))) { continue }
                if (-not (Test-Path -LiteralPath $target)) { $file.FullName }
            })
    }
    Get-ResikChocolateyFileSet -File $orphans
}

function New-ResikChocolateyShimTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    $clean = if (Test-ResikAdministrator) {
        {
            $refusal = Get-ResikChocolateyRefusal
            if ($refusal) { return $refusal }
            $root = Get-ResikCheckedChocolateyRoot
            Invoke-ResikChocolateyFileDeletion -Set (Get-ResikChocolateyOrphanShimSet -Root $root) -Root $root -Label 'broken shim(s)'
        }
    }
    else { $null }
    New-ResikTarget -Id 'choco-shims' -Name 'Chocolatey broken shims' -Category Developer -RiskLevel Low -Group 'Chocolatey' `
        -Description ('Deletes shims in Chocolatey''s bin folder whose program no longer exists. Shims that work are ' +
            'kept. Needs administrator rights.') `
        -Detect { Invoke-ResikChocolateyRootDetection } `
        -Analyze {
            $root = Get-ResikCheckedChocolateyRoot
            Invoke-ResikChocolateyFileAnalysis -Set (Get-ResikChocolateyOrphanShimSet -Root $root) -Label 'broken shim(s)' -Where (Join-Path $root 'bin')
        } `
        -Clean $clean
}

# --- choco-installers --------------------------------------------------------

function Get-ResikChocolateyInstallerExtension {
    # The Package Reducer's file types, without .iso (which can be the product
    # itself) and .exe (which is usually the installed program).
    @('.7z', '.zip', '.rar', '.gz', '.tar', '.sfx', '.msi', '.msu', '.msp')
}

function Get-ResikChocolateyScriptText {
    # A script without its comment lines.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )
    (@([System.IO.File]::ReadAllLines($Path) | Where-Object { $_ -notmatch '^\s*#' })) -join "`n"
}

function Get-ResikChocolateyPackageInstaller {
    # The files in one package's tools folder that its install script names and
    # passes to Chocolatey's install helpers, unless another script in the
    # folder (such as chocolateyUninstall.ps1) may need that kind of file.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Package,

        [Parameter(Mandatory)]
        [string] $Root
    )
    $tools = Join-Path $Package 'tools'
    if (-not (Test-ResikRealFolder -Path $tools -Base $Root)) { return }
    foreach ($marker in '.SkipReducer', 'tools\.SkipReducer', '.chocolateyPending') {
        if (Test-Path -LiteralPath (Join-Path $Package $marker)) { return }
    }
    $install = Join-Path $tools 'chocolateyInstall.ps1'
    if (-not (Test-Path -LiteralPath $install -PathType Leaf)) { return }
    $text = Get-ResikChocolateyScriptText -Path $install
    if ($text -notmatch '\b(Install-ChocolateyInstallPackage|Install-ChocolateyPackage|Install-ChocolateyZipPackage|Get-ChocolateyUnzip)\b') { return }

    $files = @(Get-ChildItem -LiteralPath $tools -File -Force -ErrorAction SilentlyContinue |
            Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) })
    $otherText = @($files | Where-Object { @('.ps1', '.psm1') -contains $_.Extension -and $_.Name -ine 'chocolateyInstall.ps1' } |
            ForEach-Object { Get-ResikChocolateyScriptText -Path $_.FullName }) -join "`n"
    foreach ($file in $files) {
        if (@(Get-ResikChocolateyInstallerExtension) -notcontains $file.Extension) { continue }
        if ($text.IndexOf($file.Name, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if ($otherText.IndexOf($file.Extension, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }
        $file.FullName
    }
}

function Get-ResikChocolateyInstallerSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )
    $lib = Join-Path $Root 'lib'
    $files = @()
    if (Test-ResikRealFolder -Path $lib -Base $Root) {
        $files = @(foreach ($package in @(Get-ChildItem -LiteralPath $lib -Directory -Force)) {
                if ($package.Name -ieq 'chocolatey' -or $package.Name -like '*.extension') { continue }
                Get-ResikChocolateyPackageInstaller -Package $package.FullName -Root $Root
            })
    }
    Get-ResikChocolateyFileSet -File $files
}

function New-ResikChocolateyInstallerTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    $clean = if (Test-ResikAdministrator) {
        {
            $refusal = Get-ResikChocolateyRefusal
            if ($refusal) { return $refusal }
            $root = Get-ResikCheckedChocolateyRoot
            Invoke-ResikChocolateyFileDeletion -Set (Get-ResikChocolateyInstallerSet -Root $root) -Root $root -Label 'used installer(s)'
        }
    }
    else { $null }
    New-ResikTarget -Id 'choco-installers' -Name 'Chocolatey used installers' -Category Developer -RiskLevel Medium -Group 'Chocolatey' -ExplicitOnly `
        -Description ('Deletes installers and archives inside installed Chocolatey packages that the package''s install ' +
            'script already used. The programs stay installed, but a repair may ask for the installer, and the files ' +
            'return only when the package is installed again. Needs administrator rights.') `
        -Detect { Invoke-ResikChocolateyRootDetection } `
        -Analyze {
            $root = Get-ResikCheckedChocolateyRoot
            Invoke-ResikChocolateyFileAnalysis -Set (Get-ResikChocolateyInstallerSet -Root $root) -Label 'used installer(s)' -Where (Join-Path $root 'lib')
        } `
        -Clean $clean
}
