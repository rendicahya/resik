# Shared target and result models for Resik.
#
# Targets and results are plain PSCustomObjects tagged with a PSTypeName so they
# stay easy to construct in tests and serialize later. Sizes use $null to mean
# "not measured", which is deliberately distinct from 0.

function Get-ResikStatusName {
    # The complete, ordered set of result statuses.
    @('Success', 'PartialSuccess', 'Failed', 'Skipped', 'AnalysisOnly', 'Unsupported', 'Unknown')
}

function New-ResikTarget {
    <#
    .SYNOPSIS
        Creates a cleanup target definition.
    .DESCRIPTION
        Detect must return an object with a boolean Available property and an
        optional Details string. Analyze must return an object with an optional
        EstimatedBytes property ($null when not measurable) and an optional
        Details string. Neither scriptblock may modify anything on disk.

        Clean is optional; a target without it is analysis-only. It must
        validate what it removes, and return an object with a Status (Success,
        PartialSuccess, Failed, or Skipped), a Details string, and optional
        MeasuredBytes (observed cache reduction) and FreeSpaceChangeBytes
        (observed change in free disk space). Missing measurements are $null.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9][a-z0-9-]*$', Options = 'None')]
        [string] $Id,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateSet('Windows', 'Developer', IgnoreCase = $false)]
        [string] $Category,

        [Parameter(Mandatory)]
        [ValidateSet('Low', 'Medium', 'High', IgnoreCase = $false)]
        [string] $RiskLevel,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Description,

        [Parameter(Mandatory)]
        [scriptblock] $Detect,

        [Parameter(Mandatory)]
        [scriptblock] $Analyze,

        [scriptblock] $Clean = $null
    )

    [pscustomobject]@{
        PSTypeName  = 'Resik.Target'
        Id          = $Id
        Name        = $Name
        Category    = $Category
        RiskLevel   = $RiskLevel
        Description = $Description
        Detect      = $Detect
        Analyze     = $Analyze
        Clean       = $Clean
    }
}

function New-ResikResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $TargetId,

        [Parameter(Mandatory)]
        [ValidateSet('Analyze', 'Clean', IgnoreCase = $false)]
        [string] $Operation,

        # Keep in sync with Get-ResikStatusName.
        [Parameter(Mandatory)]
        [ValidateSet('Success', 'PartialSuccess', 'Failed', 'Skipped', 'AnalysisOnly', 'Unsupported', 'Unknown', IgnoreCase = $false)]
        [string] $Status,

        [string] $Message = '',

        [Nullable[long]] $EstimatedBytes = $null,

        # Observed reduction of the target's cache contents.
        [Nullable[long]] $MeasuredBytes = $null,

        # Observed change in free disk space; other activity can affect it.
        [Nullable[long]] $FreeSpaceChangeBytes = $null,

        [Nullable[timespan]] $Duration = $null
    )

    [pscustomobject]@{
        PSTypeName           = 'Resik.Result'
        TargetId             = $TargetId
        Operation            = $Operation
        Status               = $Status
        Message              = $Message
        EstimatedBytes       = $EstimatedBytes
        MeasuredBytes        = $MeasuredBytes
        FreeSpaceChangeBytes = $FreeSpaceChangeBytes
        Duration             = $Duration
    }
}
