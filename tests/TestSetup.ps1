# Dot-source this from a Pester BeforeAll block to load Resik's functions
# without running the CLI entry point. Keep in sync with src/Resik/Resik.ps1.

# Match the strict mode that src/Resik/Resik.ps1 runs under.
Set-StrictMode -Version 3.0

$resikSource = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Resik'

. (Join-Path $resikSource 'Core\Models.ps1')
. (Join-Path $resikSource 'Core\Arguments.ps1')
. (Join-Path $resikSource 'Core\Selection.ps1')
. (Join-Path $resikSource 'Core\Analysis.ps1')
. (Join-Path $resikSource 'Core\NativeCommand.ps1')
. (Join-Path $resikSource 'Core\FileSystem.ps1')
. (Join-Path $resikSource 'Core\Cleanup.ps1')
. (Join-Path $resikSource 'Core\Process.ps1')
. (Join-Path $resikSource 'Core\Deletion.ps1')
. (Join-Path $resikSource 'WindowsCleanup\RecycleBin.ps1')
. (Join-Path $resikSource 'WindowsCleanup\ShaderCache.ps1')
. (Join-Path $resikSource 'WindowsCleanup\ThumbnailCache.ps1')
. (Join-Path $resikSource 'WindowsCleanup\Screenshots.ps1')
. (Join-Path $resikSource 'WindowsCleanup\WindowsUpdate.ps1')
. (Join-Path $resikSource 'WindowsCleanup\DeliveryOptimization.ps1')
. (Join-Path $resikSource 'WindowsCleanup\DiskCleanup.ps1')
. (Join-Path $resikSource 'WindowsCleanup\Defender.ps1')
. (Join-Path $resikSource 'WindowsCleanup\ErrorReports.ps1')
. (Join-Path $resikSource 'WindowsCleanup\Edge.ps1')
. (Join-Path $resikSource 'WindowsCleanup\InternetCache.ps1')
. (Join-Path $resikSource 'WindowsCleanup\TempFiles.ps1')
. (Join-Path $resikSource 'WindowsCleanup\WindowsLogs.ps1')
. (Join-Path $resikSource 'AppCleanup\AppCache.ps1')
. (Join-Path $resikSource 'AppCleanup\Chromium.ps1')
. (Join-Path $resikSource 'AppCleanup\Zotero.ps1')
. (Join-Path $resikSource 'AppCleanup\Nvidia.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\Uv.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\Pip.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\Poetry.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\Npm.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\Pnpm.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\Yarn.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\Composer.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\Go.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\Bun.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\NodeGyp.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\NetBeans.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\Deno.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\Dart.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\Scoop.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\Chocolatey.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\NuGet.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\Conda.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\HuggingFace.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\PyTorch.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\Playwright.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\Gradle.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\Maven.ps1')
. (Join-Path $resikSource 'DeveloperCleanup\JetBrains.ps1')
. (Join-Path $resikSource 'Core\Catalog.ps1')
. (Join-Path $resikSource 'Core\Cli.ps1')
. (Join-Path $resikSource 'Reporting\ConsoleReport.ps1')
. (Join-Path $resikSource 'UI\TargetPicker.ps1')
. (Join-Path $resikSource 'UI\Spinner.ps1')

# Tests run in a real console; keep the spinner from drawing during them.
# Spinner.Tests.ps1 reloads the real function.
function Test-ResikSpinnerSupported { $false }

# Likewise, never change the real console's input mode; the picker then reads
# keys only. TargetPicker.Tests.ps1 mocks this to test mouse clicks.
function Enable-ResikPickerMouse { $null }

# Tests must never write Disk Cleanup's registry values; tests of the
# Disk Cleanup targets (defender, error-reports) mock these.
function Set-ResikVolumeCacheStateFlag {
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $Path, [int] $Slot, [int] $Value)
    if ($PSCmdlet.ShouldProcess("$Path $Slot", "Set to $Value")) { throw 'Tests must mock Set-ResikVolumeCacheStateFlag.' }
}
function Remove-ResikVolumeCacheStateFlag {
    [CmdletBinding(SupportsShouldProcess)]
    param([string] $Path, [int] $Slot)
    if ($PSCmdlet.ShouldProcess("$Path $Slot", 'Remove')) { throw 'Tests must mock Remove-ResikVolumeCacheStateFlag.' }
}

function New-TestRunResult {
    # A fake Invoke-ResikNativeCommand result, for mocks.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    param([string] $Status = 'Success', [string] $StdOut = '', [string] $StdErr = '', [string] $Message = '')
    [pscustomobject]@{
        Command = 'tool'; Status = $Status; ExitCode = $(if ($Status -eq 'Success') { 0 } else { 1 })
        StdOut = $StdOut; StdErr = $StdErr; Message = $Message; Duration = [timespan]::Zero
    }
}

function New-TestFile {
    # Writes a file of the given size, creating its folder.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only to TestDrive.')]
    param([string] $Path, [int] $Size = 100)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [System.IO.File]::WriteAllBytes($Path, (New-Object byte[] $Size))
}

function New-TestTarget {
    # A fake target for tests. Never touches real caches.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    param(
        [string] $Id = 'fake',
        [scriptblock] $Detect = { [pscustomobject]@{ Available = $true } },
        [scriptblock] $Analyze = { [pscustomobject]@{ EstimatedBytes = 1024; Details = 'fake cache' } },
        [scriptblock] $Clean = $null,
        [string] $RiskLevel = 'Low',
        [string] $Group = '',
        [switch] $ExplicitOnly,
        [switch] $ListFirst
    )
    New-ResikTarget -Id $Id -Name "Fake $Id" -Category Developer -RiskLevel $RiskLevel `
        -Description 'Test target' -Detect $Detect -Analyze $Analyze -Clean $Clean -Group $Group -ExplicitOnly:$ExplicitOnly `
        -ListFirst:$ListFirst
}
