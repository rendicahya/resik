# JetBrains IDE caches target (analysis only)
# (https://www.jetbrains.com/help/idea/directories-used-by-the-ide-to-store-settings-caches-plugins-and-logs.html).
#
# Each IDE version keeps a system folder, %LOCALAPPDATA%\JetBrains\
# <product><version>, holding caches, indexes, logs, and Local History. The
# IDEs have no command-line cleanup. Their own tools are File | Invalidate
# Caches (for the running IDE) and Help | Delete Leftover IDE Directories (for
# old versions), and a new major version removes the caches and logs of
# versions unused for 180 days. Deleting caches under a running IDE can
# corrupt them, and the system folder also holds Local History, which must be
# kept. Resik therefore only reports the size of the caches and index folders,
# and never deletes them.
#
# Only the default location is checked: IDEs moved with idea.system.path,
# and Android Studio (under %LOCALAPPDATA%\Google), are not detected.

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
        'in the IDE; Resik does not clean them.')
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
