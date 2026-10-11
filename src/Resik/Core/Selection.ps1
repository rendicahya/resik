# Target ID parsing and target selection.
#
# Usage errors are raised as System.ArgumentException so the CLI can report them
# as actionable messages instead of stack traces.

function ConvertTo-ResikTargetIdList {
    <#
    .SYNOPSIS
        Normalizes --only input into a distinct, lowercase list of target IDs.
    .DESCRIPTION
        Accepts a single comma-separated string or an array of them.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [string[]] $Value
    )

    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        foreach ($part in ([string]$item).Split(',')) {
            $id = $part.Trim().ToLowerInvariant()
            if ($id.Length -eq 0) {
                throw [System.ArgumentException]::new(
                    "--only contains an empty target ID. Use a comma-separated list such as: --only uv,pip")
            }
            if ($id -cnotmatch '^[a-z0-9][a-z0-9-]*$') {
                throw [System.ArgumentException]::new(
                    "Invalid target ID '$($part.Trim())'. Target IDs contain only lowercase letters, digits, and hyphens.")
            }
            if (-not $ids.Contains($id)) {
                $ids.Add($id)
            }
        }
    }

    if ($ids.Count -eq 0) {
        throw [System.ArgumentException]::new("--only requires at least one target ID.")
    }

    $ids.ToArray()
}

function Resolve-ResikSelection {
    <#
    .SYNOPSIS
        Returns the targets selected by --all or --only, in catalog order.
        Callers should wrap the call in @() to always get an array.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]] $Targets = @(),

        [switch] $All,

        [string[]] $Only
    )

    $hasOnly = $PSBoundParameters.ContainsKey('Only')

    if ($All -and $hasOnly) {
        throw [System.ArgumentException]::new("--all and --only cannot be used together.")
    }
    if (-not $All -and -not $hasOnly) {
        throw [System.ArgumentException]::new("No targets selected. Use --all or --only <id>[,<id>...].")
    }

    if ($All) {
        return $Targets
    }

    $requested = @(ConvertTo-ResikTargetIdList -Value $Only)
    $knownIds = @($Targets | ForEach-Object { $_.Id })
    $unknown = @($requested | Where-Object { $knownIds -cnotcontains $_ })
    if ($unknown.Count -gt 0) {
        $available = if ($knownIds.Count -gt 0) { $knownIds -join ', ' } else { '(none registered)' }
        throw [System.ArgumentException]::new(
            "Unknown target ID(s): $($unknown -join ', '). Available targets: $available")
    }

    $Targets | Where-Object { $requested -ccontains $_.Id }
}
