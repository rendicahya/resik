# Resik - safe cleanup for Windows and developer-tool caches.
#
# Run "resik --help" for usage. Options are GNU-style (-h, --help), which
# PowerShell's parameter binder cannot declare, so this script has no param
# block and parses $args itself (see Core\Arguments.ps1).

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Explicit file list: only these files are loaded, in this order.
. (Join-Path $PSScriptRoot 'Core\Models.ps1')
. (Join-Path $PSScriptRoot 'Core\Arguments.ps1')
. (Join-Path $PSScriptRoot 'Core\Selection.ps1')
. (Join-Path $PSScriptRoot 'Core\Analysis.ps1')
. (Join-Path $PSScriptRoot 'Core\NativeCommand.ps1')
. (Join-Path $PSScriptRoot 'Core\FileSystem.ps1')
. (Join-Path $PSScriptRoot 'Core\Cleanup.ps1')
. (Join-Path $PSScriptRoot 'Core\Deletion.ps1')
. (Join-Path $PSScriptRoot 'DeveloperCleanup\Uv.ps1')
. (Join-Path $PSScriptRoot 'DeveloperCleanup\Pip.ps1')
. (Join-Path $PSScriptRoot 'DeveloperCleanup\Poetry.ps1')
. (Join-Path $PSScriptRoot 'DeveloperCleanup\Npm.ps1')
. (Join-Path $PSScriptRoot 'DeveloperCleanup\Composer.ps1')
. (Join-Path $PSScriptRoot 'DeveloperCleanup\Scoop.ps1')
. (Join-Path $PSScriptRoot 'DeveloperCleanup\Chocolatey.ps1')
. (Join-Path $PSScriptRoot 'DeveloperCleanup\NuGet.ps1')
. (Join-Path $PSScriptRoot 'DeveloperCleanup\Conda.ps1')
. (Join-Path $PSScriptRoot 'DeveloperCleanup\HuggingFace.ps1')
. (Join-Path $PSScriptRoot 'DeveloperCleanup\Playwright.ps1')
. (Join-Path $PSScriptRoot 'DeveloperCleanup\Gradle.ps1')
. (Join-Path $PSScriptRoot 'DeveloperCleanup\Maven.ps1')
. (Join-Path $PSScriptRoot 'DeveloperCleanup\JetBrains.ps1')
. (Join-Path $PSScriptRoot 'Core\Catalog.ps1')
. (Join-Path $PSScriptRoot 'Core\Cli.ps1')
. (Join-Path $PSScriptRoot 'Reporting\ConsoleReport.ps1')
. (Join-Path $PSScriptRoot 'UI\TargetPicker.ps1')
. (Join-Path $PSScriptRoot 'UI\Spinner.ps1')

try {
    $exitCode = Invoke-ResikCli -Arguments $args -Targets @(Get-ResikTargetCatalog)
}
catch {
    Write-ResikError "Unexpected error: $($_.Exception.Message)"
    $exitCode = 1
}
exit $exitCode
