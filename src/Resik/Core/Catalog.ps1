# The catalog of cleanup targets known to Resik, in display order.
#
# Targets are added here one at a time as they are implemented in
# WindowsCleanup/ and DeveloperCleanup/.

function Get-ResikTargetCatalog {
    # Emits each registered target. Callers should wrap the call in @().
    [CmdletBinding()]
    param()

    New-ResikRecycleBinTarget
    New-ResikShaderCacheTarget
    New-ResikThumbnailCacheTarget
    New-ResikTempFileTarget
    New-ResikScreenshotsTarget
    New-ResikWindowsUpdateTarget
    New-ResikWindowsLogTarget
    New-ResikDeliveryOptimizationTarget
    New-ResikEdgeCacheTarget
    New-ResikEdgeProfileTarget
    New-ResikInternetCacheTarget
    New-ResikUvTarget
    New-ResikPipTarget
    New-ResikPoetryTarget
    New-ResikCondaTarget
    New-ResikHuggingFaceTarget
    New-ResikTorchInductorTarget
    New-ResikTritonTarget
    New-ResikNpmTarget
    New-ResikPnpmTarget
    New-ResikYarnTarget
    New-ResikBunTarget
    New-ResikDenoTarget
    New-ResikComposerTarget
    New-ResikGoBuildTarget
    New-ResikGoModulesTarget
    New-ResikDartTarget
    New-ResikPlaywrightTarget
    New-ResikScoopAppsTarget
    New-ResikScoopCacheTarget
    New-ResikScoopPersistTarget
    New-ResikChocolateyTarget
    New-ResikNuGetTarget
    New-ResikJetBrainsLeftoverTarget
    # Analysis only: these report sizes and are never cleaned.
    New-ResikGradleTarget
    New-ResikMavenTarget
    New-ResikJetBrainsTarget
}
