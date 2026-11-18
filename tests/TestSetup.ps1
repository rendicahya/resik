# Dot-source this from a Pester BeforeAll block to load Resik's functions
# without running the CLI entry point, from the same list as src/Resik/Resik.ps1.

# Match the strict mode that src/Resik/Resik.ps1 runs under.
Set-StrictMode -Version 3.0

$resikSource = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\Resik'

. (Join-Path $resikSource 'Core\SourceFiles.ps1')
foreach ($resikSourceFile in Get-ResikSourceFile) {
    . (Join-Path $resikSource $resikSourceFile)
}

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
