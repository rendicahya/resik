<#
.SYNOPSIS
    Builds the Resik release archive.
.DESCRIPTION
    Packages src/Resik plus LICENSE and README.md into dist/resik-<version>.zip,
    where <version> is read from Get-ResikVersion. Prints the archive path and
    its SHA-256 hash. Refuses to overwrite an existing archive.

    The archive is not byte-for-byte reproducible (zip entries carry
    timestamps), so the published hash must always be computed from the exact
    file uploaded to the GitHub Release.
#>
[CmdletBinding()]
param(
    [string] $OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist')
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceRoot = Join-Path $repoRoot 'src\Resik'

. (Join-Path $sourceRoot 'Core\Cli.ps1')
$version = Get-ResikVersion
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Refusing to build a release from non-release version '$version'."
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$archivePath = Join-Path $OutputDirectory "resik-$version.zip"
if (Test-Path -LiteralPath $archivePath) {
    throw "Archive already exists: $archivePath. Remove it first if you intend to rebuild."
}

# Stage the files so the archive root contains Resik.ps1 directly.
$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("resik-build-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging | Out-Null
try {
    Copy-Item -Path (Join-Path $sourceRoot '*') -Destination $staging -Recurse
    Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination $staging
    Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination $staging
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $archivePath
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force
}

$hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
[pscustomobject]@{
    Version = $version
    Path    = $archivePath
    SHA256  = $hash
}
