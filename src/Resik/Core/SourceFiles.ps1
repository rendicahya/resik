# The source files that make up Resik, in load order.
#
# Resik.ps1, the background analysis workers (Core\Analysis.ps1), and
# tests\TestSetup.ps1 all load this list, so a new source file is added here
# only.

function Get-ResikSourceRoot {
    # The folder that holds Resik.ps1.
    [CmdletBinding()]
    [OutputType([string])]
    param()
    Split-Path -Parent $PSScriptRoot
}

function Get-ResikSourceFile {
    # Emits each source file's path relative to Get-ResikSourceRoot, except
    # this file, which callers load first.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    'Core\Models.ps1'
    'Core\Arguments.ps1'
    'Core\Selection.ps1'
    'Core\Analysis.ps1'
    'Core\NativeCommand.ps1'
    'Core\FileSystem.ps1'
    'Core\Cleanup.ps1'
    'Core\Process.ps1'
    'Core\Deletion.ps1'
    'WindowsCleanup\RecycleBin.ps1'
    'WindowsCleanup\ShaderCache.ps1'
    'WindowsCleanup\ThumbnailCache.ps1'
    'WindowsCleanup\Screenshots.ps1'
    'WindowsCleanup\WindowsUpdate.ps1'
    'WindowsCleanup\DeliveryOptimization.ps1'
    'WindowsCleanup\DiskCleanup.ps1'
    'WindowsCleanup\Defender.ps1'
    'WindowsCleanup\ErrorReports.ps1'
    'WindowsCleanup\MemoryDumps.ps1'
    'WindowsCleanup\WindowsSetup.ps1'
    'WindowsCleanup\Edge.ps1'
    'WindowsCleanup\InternetCache.ps1'
    'WindowsCleanup\TempFiles.ps1'
    'WindowsCleanup\WindowsLogs.ps1'
    'AppCleanup\AppCache.ps1'
    'AppCleanup\Chromium.ps1'
    'AppCleanup\Zotero.ps1'
    'AppCleanup\Firefox.ps1'
    'AppCleanup\Nvidia.ps1'
    'DeveloperCleanup\Uv.ps1'
    'DeveloperCleanup\Pip.ps1'
    'DeveloperCleanup\Poetry.ps1'
    'DeveloperCleanup\Npm.ps1'
    'DeveloperCleanup\Pnpm.ps1'
    'DeveloperCleanup\Yarn.ps1'
    'DeveloperCleanup\Composer.ps1'
    'DeveloperCleanup\Go.ps1'
    'DeveloperCleanup\Bun.ps1'
    'DeveloperCleanup\NodeGyp.ps1'
    'DeveloperCleanup\NetBeans.ps1'
    'DeveloperCleanup\Deno.ps1'
    'DeveloperCleanup\Dart.ps1'
    'DeveloperCleanup\Scoop.ps1'
    'DeveloperCleanup\Chocolatey.ps1'
    'DeveloperCleanup\NuGet.ps1'
    'DeveloperCleanup\Conda.ps1'
    'DeveloperCleanup\HuggingFace.ps1'
    'DeveloperCleanup\PyTorch.ps1'
    'DeveloperCleanup\Playwright.ps1'
    'DeveloperCleanup\Gradle.ps1'
    'DeveloperCleanup\Maven.ps1'
    'DeveloperCleanup\JetBrains.ps1'
    'Core\Catalog.ps1'
    'Core\Cli.ps1'
    'Reporting\ConsoleReport.ps1'
    'UI\TargetPicker.ps1'
    'UI\Spinner.ps1'
}
