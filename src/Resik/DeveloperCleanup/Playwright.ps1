# Playwright browsers target (https://playwright.dev/docs/browsers).
#
# Uses the Playwright CLI, verified against Playwright 1.63 (Python package):
#   playwright uninstall --all   removes the browsers of every Playwright
#                                installation from the shared browsers folder
# There is no preview, so analysis measures the browser folders, which
# Playwright names <browser>-<revision> (chromium-1234, ffmpeg-1011). Other
# folders there, such as .links, are neither measured nor removed by
# Playwright. Branded browsers (Google Chrome, Microsoft Edge) are not
# affected.
#
# The browsers folder is PLAYWRIGHT_BROWSERS_PATH, else
# %LOCALAPPDATA%\ms-playwright. PLAYWRIGHT_BROWSERS_PATH=0 keeps browsers
# inside each project's node_modules, which Resik does not touch. The CLI is
# playwright.exe (Python) or playwright.cmd (a global npm install) on PATH;
# Resik never uses npx, which could download Playwright first.

function Get-ResikPlaywrightExecutable {
    $playwright = Resolve-ResikExecutable -Name 'playwright'
    if (-not $playwright) { $playwright = Resolve-ResikExecutable -Name 'playwright' -Extension '.cmd' }
    $playwright
}

function Get-ResikPlaywrightBrowsersDirectory {
    # Returns the validated browsers folder, or $null when browsers are kept
    # inside each project (PLAYWRIGHT_BROWSERS_PATH=0).
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $configured = $env:PLAYWRIGHT_BROWSERS_PATH
    if ($configured -eq '0') { return $null }
    if (-not $configured) { $configured = Join-Path $env:LOCALAPPDATA 'ms-playwright' }

    $path = (Expand-ResikConfiguredPath -Path $configured).TrimEnd('\')
    $issue = Get-ResikPathSafetyIssue -Path $path
    if ($issue) { throw "Refusing to clean Playwright browsers: $issue" }
    [System.IO.Path]::GetFullPath($path)
}

function Get-ResikPlaywrightBrowserFolder {
    # Emits the browser folders (<name>-<revision>) in the browsers folder, sorted
    # ordinally because Get-ChildItem's order differs between PowerShell versions.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $found = New-Object 'System.Collections.Generic.List[string]'
    foreach ($folder in @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($folder.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        if ($folder.Name -cmatch '^[a-z][a-z0-9_-]*-\d+$') { $found.Add($folder.FullName) }
    }
    $found.Sort([System.StringComparer]::Ordinal)
    $found
}

function Invoke-ResikPlaywrightDetection {
    $playwright = Get-ResikPlaywrightExecutable
    if (-not $playwright) {
        return [pscustomobject]@{
            Available = $false
            Details   = ('The playwright command was not found on PATH. In a Node.js project, remove browsers ' +
                'with "npx playwright uninstall --all".')
        }
    }
    [pscustomobject]@{ Available = $true; Details = $playwright }
}

function Invoke-ResikPlaywrightAnalysis {
    $browsersDir = Get-ResikPlaywrightBrowsersDirectory
    if ($null -eq $browsersDir) {
        return [pscustomobject]@{ EstimatedBytes = 0; Details = 'PLAYWRIGHT_BROWSERS_PATH=0: browsers are kept inside each project.' }
    }
    $folders = @(Get-ResikPlaywrightBrowserFolder -Path $browsersDir)
    if ($folders.Count -eq 0) {
        return [pscustomobject]@{ EstimatedBytes = 0; Details = "No browsers in $browsersDir" }
    }
    $size = Measure-ResikPathSet -Path $folders
    $names = ($folders | ForEach-Object { Split-Path -Leaf $_ }) -join ', '
    $details = "$browsersDir ($names)"
    if ($size.Unreadable -gt 0) { $details += "; $($size.Unreadable) folder(s) could not be read" }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function Invoke-ResikPlaywrightCleanup {
    $playwright = Get-ResikPlaywrightExecutable
    if (-not $playwright) { throw 'The playwright command was not found on PATH.' }
    $browsersDir = Get-ResikPlaywrightBrowsersDirectory
    if ($null -eq $browsersDir) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = 'PLAYWRIGHT_BROWSERS_PATH=0: browsers are kept inside each project.' }
    }
    $folders = @(Get-ResikPlaywrightBrowserFolder -Path $browsersDir)
    if ($folders.Count -eq 0) {
        return [pscustomobject]@{ Status = 'Skipped'; Details = "No browsers in $browsersDir; nothing to clean." }
    }
    # A browser that is running cannot be deleted; ExpectEmpty reports that.
    Invoke-ResikMeasuredCommand -FilePath $playwright -ArgumentList @('uninstall', '--all') `
        -MeasurePath $folders -FreeSpacePath $browsersDir -TimeoutSeconds 1800 -ExpectEmpty
}

function New-ResikPlaywrightTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'playwright' -Name 'Playwright browsers' -Category Developer -RiskLevel Medium `
        -Description ('Uninstalls the browsers that Playwright downloaded (Chromium, Firefox, WebKit, FFmpeg) for ' +
            'every Playwright installation, by running "playwright uninstall --all". These are browser ' +
            'installations, not a cache: Playwright tests and scripts stop working until you run ' +
            '"playwright install" again, which downloads them again and needs an internet connection. ' +
            'Google Chrome and Microsoft Edge are not affected.') `
        -Detect { Invoke-ResikPlaywrightDetection } `
        -Analyze { Invoke-ResikPlaywrightAnalysis } `
        -Clean { Invoke-ResikPlaywrightCleanup }
}
