# Chocolatey HTTP cache target (https://docs.chocolatey.org/en-us/choco/commands/cache/).
#
# Uses Chocolatey's own commands, available since Chocolatey CLI 2.1.0 and
# verified against 2.7.3:
#   choco cache list            read-only; counts the cached items
#   choco cache remove --yes    removes the cached items
# Without administrator rights (Resik never elevates), both act only on the
# user's HTTP cache. Chocolatey does not report the cache location or size,
# so Resik shows the item count and cannot measure the space reclaimed.
# Installed packages and Chocolatey's package metadata are not touched.

function Get-ResikChocolateyExecutable {
    $choco = Resolve-ResikExecutable -Name 'choco'
    if (-not $choco) { throw 'Chocolatey was not found on PATH.' }
    $choco
}

function Get-ResikChocolateyCacheSummary {
    # Returns the "We found ... cached items ..." line from "choco cache list".
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $ChocoPath
    )

    $run = Invoke-ResikNativeCommand -FilePath $ChocoPath -ArgumentList @('cache', 'list') -TimeoutSeconds 120
    if ($run.Status -ne 'Success') {
        throw (Get-ResikNativeCommandFailure $run)
    }
    $line = @($run.StdOut -split "`r?`n" | Where-Object { $_ -match 'cached items' }) | Select-Object -Last 1
    if ($line) { return $line.Trim() }
    'Cache size unknown.'
}

function Invoke-ResikChocolateyDetection {
    $choco = Resolve-ResikExecutable -Name 'choco'
    if (-not $choco) {
        return [pscustomobject]@{ Available = $false; Details = 'Chocolatey was not found on PATH.' }
    }
    [pscustomobject]@{ Available = $true; Details = $choco }
}

function Invoke-ResikChocolateyAnalysis {
    $summary = Get-ResikChocolateyCacheSummary -ChocoPath (Get-ResikChocolateyExecutable)
    [pscustomobject]@{ EstimatedBytes = $null; Details = "User HTTP cache: $summary" }
}

function Invoke-ResikChocolateyCleanup {
    $choco = Get-ResikChocolateyExecutable
    $outcome = Invoke-ResikMeasuredCommand -FilePath $choco -ArgumentList @('cache', 'remove', '--yes') -TimeoutSeconds 600
    if ($outcome.Status -eq 'Success') {
        $after = Get-ResikChocolateyCacheSummary -ChocoPath $choco
        $outcome.Details += "; now: $after"
    }
    $outcome
}

function New-ResikChocolateyTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'choco' -Name 'Chocolatey HTTP cache' -Category Developer -RiskLevel Low `
        -Description ('Removes cached package-source responses from your Chocolatey HTTP cache by running ' +
            '"choco cache remove". Installed packages are not touched. The system-wide cache needs administrator ' +
            'rights and is not cleaned. Chocolatey does not report sizes, so none are shown.') `
        -Detect { Invoke-ResikChocolateyDetection } `
        -Analyze { Invoke-ResikChocolateyAnalysis } `
        -Clean { Invoke-ResikChocolateyCleanup }
}
