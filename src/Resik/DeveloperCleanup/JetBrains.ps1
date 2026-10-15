# JetBrains IDE targets
# (https://www.jetbrains.com/help/idea/directories-used-by-the-ide-to-store-settings-caches-plugins-and-logs.html).
#
# Each IDE version keeps a system folder, %LOCALAPPDATA%\JetBrains\
# <product><version>, holding caches, indexes, logs, plugins, and Local
# History, and a config folder, %APPDATA%\JetBrains\<product><version>, holding
# settings and plugins. The IDEs have no command-line cleanup. Their own tools
# are File | Invalidate Caches (for the running IDE) and Help | Delete Leftover
# IDE Directories (for old versions), and a new major version removes the
# caches and logs of versions unused for 180 days.
#
#   jetbrains            (analysis only) reports the size of the caches and
#                        index folders of every version. Deleting them under a
#                        running IDE can corrupt them, and Local History next
#                        to them must be kept, so Resik never deletes them.
#   jetbrains-leftovers  deletes both folders of an IDE version, typically one
#                        that is no longer installed, with
#                        Remove-ResikDirectoryTree. Resik cannot reliably tell
#                        whether a version is installed (portable and Toolbox
#                        installs leave no record), so it asks about every
#                        version, and refuses while a JetBrains IDE is running.
#                        This also deletes the version's settings and Local
#                        History, so it is High risk and explicit only.
#
# Only the default locations are checked: IDEs moved with idea.system.path or
# idea.config.path, and Android Studio (under %LOCALAPPDATA%\Google), are not
# detected. A running IDE is recognized by its launcher's process name.

function Get-ResikJetBrainsSystemRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path $env:LOCALAPPDATA 'JetBrains'
}

function Get-ResikJetBrainsCacheFolder {
    # Emits Product (the system folder name) and Path for every caches or
    # index folder in an IDE system folder.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Root
    )

    foreach ($ide in @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
        if ($ide.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        foreach ($name in @('caches', 'index')) {
            $path = Join-Path $ide.FullName $name
            $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            if ($null -eq $item -or -not $item.PSIsContainer) { continue }
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            [pscustomobject]@{ Product = $ide.Name; Path = $item.FullName }
        }
    }
}

function Invoke-ResikJetBrainsDetection {
    $root = Get-ResikJetBrainsSystemRoot
    if (@(Get-ResikJetBrainsCacheFolder -Root $root).Count -eq 0) {
        return [pscustomobject]@{ Available = $false; Details = "No JetBrains IDE caches in $root" }
    }
    [pscustomobject]@{ Available = $true; Details = $root }
}

function Invoke-ResikJetBrainsAnalysis {
    $root = Get-ResikJetBrainsSystemRoot
    $folders = @(Get-ResikJetBrainsCacheFolder -Root $root)
    $bytes = [long]0
    $unreadable = 0
    $products = [ordered]@{}
    foreach ($folder in $folders) {
        $size = Measure-ResikDirectory -Path $folder.Path
        $bytes += $size.Bytes
        $unreadable += $size.Unreadable
        if (-not $products.Contains($folder.Product)) { $products[$folder.Product] = [long]0 }
        $products[$folder.Product] += $size.Bytes
    }
    $listed = ($products.Keys | ForEach-Object { "$_ $(Format-ResikSize $products[$_])" }) -join ', '
    $details = ("$root ($listed). Use File | Invalidate Caches or Help | Delete Leftover IDE Directories " +
        'in the IDE; Resik does not clean them. For versions you no longer use, see jetbrains-leftovers.')
    if ($unreadable -gt 0) { $details += " $unreadable folder(s) could not be read." }
    [pscustomobject]@{ EstimatedBytes = $bytes; Details = $details }
}

function New-ResikJetBrainsTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'jetbrains' -Name 'JetBrains IDE caches' -Category Developer -RiskLevel Low `
        -Description ('Analysis only: reports the size of the caches and indexes of each JetBrains IDE version. ' +
            'Clean them from the IDE (File | Invalidate Caches, or Help | Delete Leftover IDE Directories for ' +
            'old versions); Resik does not delete anything here.') `
        -Detect { Invoke-ResikJetBrainsDetection } `
        -Analyze { Invoke-ResikJetBrainsAnalysis }
}

function Get-ResikJetBrainsConfigRoot {
    # %APPDATA%\JetBrains, as a function so tests can point it at TestDrive.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)) 'JetBrains'
}

function Get-ResikJetBrainsRunningIde {
    # Emits the process names of running JetBrains IDEs, from their launchers'
    # names (idea64.exe, pycharm64.exe, ...). The Toolbox app is not an IDE.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $pattern = '^(idea|pycharm|webstorm|phpstorm|clion|goland|rider|datagrip|rubymine|dataspell|rustrover|aqua|writerside|appcode|mps|gateway|jetbrains_client)(64)?$'
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $pattern } |
            ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
}

function Get-ResikJetBrainsVersionFolder {
    # Emits one entry per IDE version (<product><year>.<n>, such as
    # PyCharm2024.1) found in the system or config root: its Name and the
    # Paths that exist, each with the Root it must stay inside. Other folders
    # (Toolbox, consentOptions) and links are left out.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Root
    )

    $versions = [ordered]@{}
    foreach ($base in $Root) {
        foreach ($folder in @(Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if ($folder.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($folder.Name -notmatch '^[A-Za-z][A-Za-z0-9]*\d{4}\.\d+$') { continue }
            if (-not $versions.Contains($folder.Name)) {
                $versions[$folder.Name] = New-Object 'System.Collections.Generic.List[object]'
            }
            $versions[$folder.Name].Add([pscustomobject]@{ Path = $folder.FullName; Root = $base })
        }
    }
    foreach ($name in $versions.Keys) {
        [pscustomobject]@{ Name = $name; Paths = $versions[$name].ToArray() }
    }
}

function Get-ResikJetBrainsLeftoverRoot {
    # The system and config roots, after the path safety checks.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    foreach ($root in @((Get-ResikJetBrainsSystemRoot), (Get-ResikJetBrainsConfigRoot))) {
        $issue = Get-ResikPathSafetyIssue -Path $root
        if ($issue) { throw "Refusing to clean JetBrains IDE data in '$root': $issue" }
        $root
    }
}

function Invoke-ResikJetBrainsLeftoverDetection {
    $roots = @((Get-ResikJetBrainsSystemRoot), (Get-ResikJetBrainsConfigRoot))
    if (@(Get-ResikJetBrainsVersionFolder -Root $roots).Count -eq 0) {
        return [pscustomobject]@{ Available = $false; Details = "No JetBrains IDE data in $($roots -join ' or ')" }
    }
    [pscustomobject]@{ Available = $true; Details = $roots -join ', ' }
}

function Invoke-ResikJetBrainsLeftoverAnalysis {
    $roots = @(Get-ResikJetBrainsLeftoverRoot)
    $versions = @(Get-ResikJetBrainsVersionFolder -Root $roots)
    $total = [long]0
    $unreadable = 0
    $parts = foreach ($version in $versions) {
        $size = Measure-ResikPathSet -Path @($version.Paths | ForEach-Object { $_.Path })
        $total += $size.Bytes
        $unreadable += $size.Unreadable
        "$($version.Name) ($(Format-ResikSize $size.Bytes))"
    }
    $details = "$(@($versions).Count) IDE version(s), each with its settings, plugins, and Local History: $($parts -join ', ')"
    if ($unreadable -gt 0) { $details += "; $unreadable folder(s) could not be read" }
    $running = @(Get-ResikJetBrainsRunningIde)
    if ($running.Count -gt 0) { $details += ". Close $($running -join ', ') before cleaning" }
    [pscustomobject]@{ EstimatedBytes = $total; Details = $details }
}

function Invoke-ResikJetBrainsLeftoverCleanup {
    # JetBrains has no command for this, so Resik deletes each version's
    # folders itself, and only after the user confirms that version. --force
    # does not answer these questions.
    [CmdletBinding()]
    param(
        [object] $Context
    )

    $canPrompt = $null -ne $Context -and [bool](Get-ResikOptionalProperty $Context 'CanPrompt')
    if (-not $canPrompt) {
        return [pscustomobject]@{
            Status  = 'Skipped'
            Details = 'JetBrains IDE data is removed only after you confirm each version, which needs a terminal. Nothing was removed.'
        }
    }
    $running = @(Get-ResikJetBrainsRunningIde)
    if ($running.Count -gt 0) {
        return [pscustomobject]@{
            Status  = 'Skipped'
            Details = "A JetBrains IDE is running ($($running -join ', ')). Close it and run Resik again. Nothing was removed."
        }
    }

    $roots = @(Get-ResikJetBrainsLeftoverRoot)
    $versions = @(Get-ResikJetBrainsVersionFolder -Root $roots)
    if ($versions.Count -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'No JetBrains IDE data; nothing to clean.' }
    }

    $removed = New-Object 'System.Collections.Generic.List[string]'
    $kept = New-Object 'System.Collections.Generic.List[string]'
    $failed = New-Object 'System.Collections.Generic.List[string]'
    $measured = [long]0
    $measuredComplete = $true
    $freeBefore = Get-ResikFreeSpace -Path $roots[0]

    foreach ($version in $versions) {
        $paths = @($version.Paths | ForEach-Object { $_.Path })
        $before = Measure-ResikPathSet -Path $paths
        $question = "Delete all data of $($version.Name) ($(Format-ResikSize $before.Bytes)) in $($paths -join ' and '), " +
            'including its settings, plugins, and Local History? It cannot be recovered. [y/N]'
        if (-not (Read-ResikConfirmation -Prompt $question)) {
            $kept.Add($version.Name)
            continue
        }
        # An IDE could have been started while the question was open.
        if (@(Get-ResikJetBrainsRunningIde).Count -gt 0) {
            $kept.Add("$($version.Name) (an IDE was started)")
            continue
        }

        $errors = New-Object 'System.Collections.Generic.List[string]'
        $spinner = Start-ResikSpinner -Message "Deleting $($version.Name)"
        try {
            foreach ($folder in $version.Paths) {
                try {
                    $deletion = Remove-ResikDirectoryTree -Path $folder.Path -Scope $folder.Root -Confirm:$false
                    foreach ($line in @($deletion.Errors)) { $errors.Add($line) }
                }
                catch {
                    $errors.Add($_.Exception.Message)
                }
            }
        }
        finally {
            Stop-ResikSpinner -Spinner $spinner
        }

        $after = Measure-ResikPathSet -Path $paths
        if ($before.Unreadable -eq 0 -and $after.Unreadable -eq 0) { $measured += $before.Bytes - $after.Bytes }
        else { $measuredComplete = $false }

        if ($errors.Count -eq 0) {
            $removed.Add($version.Name)
        }
        else {
            $failed.Add("$($version.Name) ($($errors.Count) item(s) could not be deleted, for example $($errors[0]))")
        }
    }

    $freeAfter = Get-ResikFreeSpace -Path $roots[0]
    $attempted = $removed.Count + $failed.Count
    $parts = @()
    if ($removed.Count -gt 0) { $parts += "Deleted: $($removed -join ', ')" }
    if ($failed.Count -gt 0) { $parts += "Not fully deleted: $($failed -join '; ')" }
    if ($kept.Count -gt 0) { $parts += "Kept: $($kept -join ', ')" }

    $status = if ($attempted -eq 0) { 'Skipped' }
    elseif ($failed.Count -eq 0) { 'Success' }
    elseif ($removed.Count -gt 0 -or ($measuredComplete -and $measured -gt 0)) { 'PartialSuccess' }
    else { 'Failed' }

    [pscustomobject]@{
        Status               = $status
        Details              = ($parts -join '. ')
        MeasuredBytes        = $(if ($attempted -gt 0 -and $measuredComplete) { $measured } else { $null })
        FreeSpaceChangeBytes = $(if ($attempted -gt 0 -and $null -ne $freeBefore -and $null -ne $freeAfter) { $freeAfter - $freeBefore } else { $null })
    }
}

function New-ResikJetBrainsLeftoverTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'jetbrains-leftovers' -Name 'JetBrains IDE version data' -Category Developer -RiskLevel High `
        -ExplicitOnly `
        -Description ('Deletes all data of JetBrains IDE versions you choose, typically ones that are no longer ' +
            'installed: caches, indexes, logs, plugins, settings, and Local History, in %LOCALAPPDATA%\JetBrains ' +
            'and %APPDATA%\JetBrains. Resik cannot tell which versions are still installed, so it asks about each ' +
            'version; it cannot be recovered. Refused while a JetBrains IDE is running. Never chosen by --all or ' +
            '"select all".') `
        -Detect { Invoke-ResikJetBrainsLeftoverDetection } `
        -Analyze { Invoke-ResikJetBrainsLeftoverAnalysis } `
        -Clean { param($Context) Invoke-ResikJetBrainsLeftoverCleanup -Context $Context }
}
