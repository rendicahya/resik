# The catalog of cleanup targets known to Resik, in display order.
#
# Targets are added here one at a time as they are implemented in
# WindowsCleanup/ and DeveloperCleanup/.

function Get-ResikTargetCatalog {
    # Emits each registered target. Callers should wrap the call in @().
    [CmdletBinding()]
    param()

    New-ResikUvTarget
    New-ResikPipTarget
    New-ResikCondaTarget
    New-ResikHuggingFaceTarget
    New-ResikNpmTarget
    New-ResikPlaywrightTarget
    New-ResikScoopAppsTarget
    New-ResikScoopCacheTarget
    New-ResikChocolateyTarget
    New-ResikNuGetTarget
    # Analysis only: these report sizes and are never cleaned.
    New-ResikGradleTarget
    New-ResikMavenTarget
    New-ResikJetBrainsTarget
}
