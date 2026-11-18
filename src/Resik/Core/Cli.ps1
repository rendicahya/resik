# Command-line handling for Resik.
#
# Exit codes:
#   0  Success (including --help and --version).
#   1  One or more targets failed, or an unexpected error occurred.
#   2  Invalid or unsupported command-line usage.

function Get-ResikVersion {
    '0.11.0'
}

function Get-ResikHelpText {
    $optionLines = foreach ($option in (Get-ResikOptionSpec)) {
        $names = if ($option.Short) { "$($option.Short), $($option.Long)" } else { "    $($option.Long)" }
        if ($option.ValueName) { $names += " $($option.ValueName)" }
        '  {0,-26}{1}' -f $names, $option.Description
    }
    # The ID column fits the longest ID, so a long one never runs into its name.
    $catalog = @(Get-ResikTargetCatalog)
    $idWidth = (@($catalog | ForEach-Object { $_.Id.Length }) | Measure-Object -Maximum).Maximum + 2
    $targetLines = foreach ($target in $catalog) {
        "  {0,-$idWidth}{1}" -f $target.Id, $target.Name
    }

    @"
Resik $(Get-ResikVersion) - safe cleanup for Windows and developer-tool caches.

Usage:
  resik
  resik --dry-run
  resik --dry-run --all
  resik --only <id>[,<id>...]
  resik --non-interactive --force --only <id>[,<id>...]

Without --all or --only, Resik analyzes every target and shows a list to pick
from: Up/Down move, Space selects, A selects all, N selects none, Enter
confirms, Q or Esc cancels.

Options:
$($optionLines -join [Environment]::NewLine)

Targets:
$($targetLines -join [Environment]::NewLine)

Before cleaning, Resik shows what will be removed and asks
"Clean these targets?". Answer y to clean, or a (accept all) to clean and
also say yes to every later question about a folder, IDE version, or reset.
--force skips only the first question. With --non-interactive, or when
input is redirected, cleanup requires --force.

recycle-bin, screenshots, edge-profile, scoop-persist, and jetbrains-leftovers
delete files that cannot be recovered and are never chosen by --all or by
"select all"; neither are the *-service-workers browser parts. edge-profile,
scoop-persist, and jetbrains-leftovers ask before deleting, even with --force
(unless you answered a), and remove nothing without a terminal.
Browser, app, and IDE targets ask to close the browser or app when it is
running, even after a; without a terminal they are skipped.
windows-update and windows-logs need administrator rights, and temp-files
includes %WINDIR%\Temp only with them; Resik never elevates itself.
"@
}

function Write-ResikError {
    param([string] $Message)
    [Console]::Error.WriteLine("resik: $Message")
}

function Invoke-ResikCli {
    <#
    .SYNOPSIS
        Runs Resik with raw command-line arguments and returns an exit code.
    .DESCRIPTION
        Targets is injected so the CLI can be tested against fake targets.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]] $Arguments = @(),

        [AllowEmptyCollection()]
        [object[]] $Targets = @()
    )

    if ($null -eq $Arguments) { $Arguments = @() }

    try {
        $options = ConvertFrom-ResikArgument -Arguments $Arguments
    }
    catch [System.ArgumentException] {
        Write-ResikError $_.Exception.Message
        return 2
    }

    if ($options.Help) {
        Write-Host (Get-ResikHelpText)
        return 0
    }
    if ($options.Version) {
        Write-Host "resik $(Get-ResikVersion)"
        return 0
    }

    if ($null -ne $options.ReportPath) {
        Write-ResikError '--report-path is not implemented yet.'
        return 2
    }

    $hasOnly = $null -ne $options.Only
    if (-not $options.All -and -not $hasOnly) {
        if ($options.NonInteractive) {
            Write-ResikError '--non-interactive requires --all or --only <id>[,<id>...].'
            return 2
        }
        return (Invoke-ResikInteractiveRun -Targets $Targets -Options $options)
    }

    try {
        $selectionArgs = @{ Targets = $Targets; All = $options.All }
        if ($hasOnly) { $selectionArgs.Only = $options.Only }
        $selected = @(Resolve-ResikSelection @selectionArgs)
    }
    catch [System.ArgumentException] {
        Write-ResikError $_.Exception.Message
        return 2
    }

    if ($selected.Count -eq 0) {
        Write-Host 'No cleanup targets are registered yet.'
        return 0
    }

    if ($options.DryRun) {
        Write-Host 'Dry run: analyzing selected targets. Nothing will be modified.'
    }
    else {
        Write-Host 'Analyzing selected targets...'
    }
    $analysis = @(Invoke-ResikAnalysisWithSpinner -Targets $selected)
    Write-Host ''
    # Tools that are not installed are named only when the user asked for them.
    foreach ($line in (Format-ResikSummary -Results $analysis -Targets $selected -Width (Get-ResikReportWidth) -ShowNotFound:$hasOnly)) {
        Write-Host $line
    }
    Write-ResikDriveSpace
    $analysisFailed = @($analysis | Where-Object { $_.Status -eq 'Failed' }).Count -gt 0

    if ($options.DryRun) {
        Write-ResikDryRunHint -Analysis $analysis -Targets $selected
        if ($analysisFailed) { return 1 }
        return 0
    }

    return (Invoke-ResikCleanupStep -Targets $selected -Analysis $analysis -Options $options -AnalysisFailed $analysisFailed)
}

function Invoke-ResikInteractiveRun {
    # Analyzes every target, lets the user pick some, then analyzes (dry run)
    # or confirms and cleans the picked ones.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Targets = @(),

        [object] $Options
    )

    $mode = Get-ResikPickerMode
    if ($mode -eq 'None') {
        Write-ResikError 'Interactive selection needs a terminal. Use --all or --only <id>[,<id>...]. See: resik --help'
        return 2
    }
    if ($Targets.Count -eq 0) {
        Write-Host 'No cleanup targets are registered yet.'
        return 0
    }

    Write-Host 'Analyzing targets...'
    $analysis = @(Invoke-ResikAnalysisWithSpinner -Targets $Targets)
    Write-Host ''
    $choice = Select-ResikTargetInteractive -Targets $Targets -Analysis $analysis -Mode $mode -DryRun:$Options.DryRun
    Write-Host ''
    if ($choice.Cancelled) {
        Write-Host 'Cancelled. Nothing was changed.'
        return 0
    }
    $selected = @($choice.Targets)
    if ($selected.Count -eq 0) {
        Write-Host 'Nothing selected. Nothing was changed.'
        return 0
    }

    $ids = @($selected | ForEach-Object { $_.Id })
    $selectedAnalysis = @($analysis | Where-Object { $ids -contains $_.TargetId })
    if ($Options.DryRun) {
        Write-Host 'Dry run: nothing will be modified.'
        Write-Host ''
        foreach ($line in (Format-ResikSummary -Results $selectedAnalysis -Targets $selected -Width (Get-ResikReportWidth))) {
            Write-Host $line
        }
        Write-ResikDriveSpace
        Write-ResikDryRunHint -Analysis $selectedAnalysis -Targets $selected
        return 0
    }

    Invoke-ResikCleanupStep -Targets $selected -Analysis $selectedAnalysis -Options $Options -AnalysisFailed $false
}

function Invoke-ResikAnalysisWithSpinner {
    # Analysis can take a while (sizing large caches, starting tools), so a
    # spinner shows which target is being analyzed.
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]] $Targets = @()
    )

    $spinner = Start-ResikSpinner -Message 'Analyzing targets'
    try {
        Invoke-ResikAnalysis -Targets $Targets -Spinner $spinner
    }
    finally {
        Stop-ResikSpinner -Spinner $spinner
    }
}

function Get-ResikReportWidth {
    # The width reports are fitted to, or 0 (no limit) when output goes to a
    # file or pipe, so logs keep every detail.
    [CmdletBinding()]
    [OutputType([int])]
    param()
    if ([Console]::IsOutputRedirected) { return 0 }
    Get-ResikConsoleWidth
}

function Write-ResikDriveSpace {
    # Prints the free space of each fixed drive after a blank line.
    [CmdletBinding()]
    param([string] $Title = 'Free space:')

    $lines = @(Format-ResikDriveSpace -Drives @(Get-ResikDriveSpace) -Title $Title)
    if ($lines.Count -eq 0) { return }
    Write-Host ''
    foreach ($line in $lines) {
        Write-Host $line
    }
}

function Write-ResikDryRunHint {
    # Tells the user how to clean what a dry run found.
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]] $Analysis = @(),

        [AllowEmptyCollection()]
        [object[]] $Targets = @()
    )

    $ready = @($Analysis | Where-Object {
            $result = $_
            $target = $Targets | Where-Object { $_.Id -eq $result.TargetId } | Select-Object -First 1
            (Get-ResikAnalysisGroup -Result $result -Target $target) -eq 'Ready'
        } | ForEach-Object { $_.TargetId })
    if ($ready.Count -eq 0) { return }
    Write-Host ''
    Write-Host "To clean, run: resik --only $($ready -join ',')"
}

function Test-ResikInteractiveInput {
    # True when a person can answer a prompt on the console.
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
}

function Read-ResikConfirmation {
    # Asks a yes/no question; only "y" or "yes" confirms.
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Prompt)
    $answer = Read-Host -Prompt $Prompt
    $null -ne $answer -and @('y', 'yes') -contains $answer.Trim().ToLowerInvariant()
}

function ConvertTo-ResikCleanupAnswer {
    # "y"/"yes" is Yes, "a"/"all" is All (yes, and yes to every later question
    # about a folder or version), anything else is No.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()] [AllowNull()] [string] $Answer)
    switch ("$Answer".Trim().ToLowerInvariant()) {
        { @('y', 'yes') -contains $_ } { return 'Yes' }
        { @('a', 'all') -contains $_ } { return 'All' }
    }
    'No'
}

function Read-ResikCleanupAnswer {
    # Asks the cleanup question; returns Yes, All, or No.
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Prompt)
    ConvertTo-ResikCleanupAnswer (Read-Host -Prompt $Prompt)
}

function Invoke-ResikCleanupStep {
    # Confirms and runs cleanup for the targets whose analysis succeeded.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [object[]] $Targets,
        [object[]] $Analysis,
        [object] $Options,
        [bool] $AnalysisFailed
    )

    $eligible = @($Targets | Where-Object {
            $id = $_.Id
            $null -ne $_.Clean -and @($Analysis | Where-Object { $_.TargetId -eq $id -and $_.Status -eq 'AnalysisOnly' }).Count -gt 0
        })

    Write-Host ''
    if ($eligible.Count -eq 0) {
        Write-Host 'Nothing to clean.'
        if ($AnalysisFailed) { return 1 }
        return 0
    }

    foreach ($line in (Format-ResikCleanupPlan -Targets $eligible -AnalysisResults $Analysis -Width (Get-ResikReportWidth))) {
        Write-Host $line
    }
    Write-Host ''

    # The only confirmation prompt in Resik; --force skips it. Answering "a"
    # (accept all) also answers yes to the questions some targets ask about
    # each folder; --force never answers those.
    $acceptAll = $false
    if (-not $Options.Force) {
        if ($Options.NonInteractive -or -not (Test-ResikInteractiveInput)) {
            Write-ResikError 'Cleanup needs confirmation. Add --force to confirm without a prompt, or use --dry-run.'
            return 2
        }
        $answer = Read-ResikCleanupAnswer -Prompt 'Clean these targets? [y/N, a = yes to all]'
        if ($answer -eq 'No') {
            Write-Host 'Cancelled. Nothing was changed.'
            return 0
        }
        $acceptAll = $answer -eq 'All'
    }

    $canPrompt = -not $Options.NonInteractive -and (Test-ResikInteractiveInput)
    $results = @(foreach ($target in $eligible) {
            $estimate = ($Analysis | Where-Object { $_.TargetId -eq $target.Id } | Select-Object -First 1).EstimatedBytes
            Invoke-ResikTargetCleanup -Target $target -EstimatedBytes $estimate -CanPrompt $canPrompt -AcceptAll ($acceptAll -and $canPrompt)
        })

    Write-Host ''
    foreach ($line in (Format-ResikCleanupSummary -Results $results -Targets $eligible -Width (Get-ResikReportWidth))) {
        Write-Host $line
    }
    Write-ResikDriveSpace -Title 'Free space now:'

    if ($AnalysisFailed -or @($results | Where-Object { $_.Status -in @('Failed', 'PartialSuccess') }).Count -gt 0) {
        return 1
    }
    0
}
