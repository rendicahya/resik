# Resik - safe cleanup for Windows and developer-tool caches.
#
# Run "resik --help" for usage. Options are GNU-style (-h, --help), which
# PowerShell's parameter binder cannot declare, so this script has no param
# block and parses $args itself (see Core\Arguments.ps1).

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Only the files listed in Core\SourceFiles.ps1 are loaded, in that order.
. (Join-Path $PSScriptRoot 'Core\SourceFiles.ps1')
foreach ($resikSourceFile in Get-ResikSourceFile) {
    . (Join-Path $PSScriptRoot $resikSourceFile)
}

try {
    # The targets come from the catalog, so background workers can build the
    # same targets and analyze some of them in parallel.
    $exitCode = Invoke-ResikCli -Arguments $args -Targets @(Get-ResikTargetCatalog) -ParallelAnalysis
}
catch {
    Write-ResikError "Unexpected error: $($_.Exception.Message)"
    $exitCode = 1
}
exit $exitCode
