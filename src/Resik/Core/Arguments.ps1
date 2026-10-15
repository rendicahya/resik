# Command-line argument parsing.
#
# Resik uses GNU-style options (-h, --help, --only=uv,pip), which PowerShell's
# parameter binder cannot declare, so the entry point passes its raw $args here.
# Usage errors are raised as System.ArgumentException.

function New-ResikOptionSpec {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    param([string] $Key, [string] $Long, [string] $Short, [string] $ValueName, [string] $Description)
    [pscustomobject]@{
        Key         = $Key
        Long        = $Long
        Short       = $Short
        ValueName   = $ValueName
        Description = $Description
    }
}

function Get-ResikOptionSpec {
    # The single source of truth for Resik's options, in help-text order.
    # Short and ValueName are empty strings when not applicable.
    New-ResikOptionSpec Help '--help' '-h' '' 'Show this help.'
    New-ResikOptionSpec Version '--version' '-v' '' 'Show the Resik version.'
    New-ResikOptionSpec DryRun '--dry-run' '-n' '' 'Analyze targets without changing anything.'
    New-ResikOptionSpec All '--all' '-a' '' 'Select all targets except the High-risk deletions (skips the picker).'
    New-ResikOptionSpec Only '--only' '-o' '<ids>' 'Select specific target IDs, comma-separated (skips the picker).'
    New-ResikOptionSpec NonInteractive '--non-interactive' '' '' 'Never prompt; needs --all or --only, and --force to clean.'
    New-ResikOptionSpec ReportPath '--report-path' '' '<path>' 'Write a JSON report (not available yet).'
    New-ResikOptionSpec Force '--force' '-f' '' 'Skip the cleanup confirmation prompt (never safety checks).'
}

function ConvertTo-ResikArgumentString {
    # When Resik is invoked in-process, PowerShell turns "uv,pip" into an array,
    # and splits "--only=uv,pip" into "--only=uv" and "pip". Rejoin with commas.
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [System.Collections.IList] -and $Value -isnot [string]) {
        return (@($Value | ForEach-Object { [string]$_ }) -join ',')
    }
    [string]$Value
}

function Get-ResikOptionSuggestion {
    # Suggests the correct spelling for near misses such as -dryrun or --Help.
    param([string] $Token, [object[]] $Spec)
    $normalized = $Token.TrimStart('-').Replace('-', '').ToLowerInvariant()
    foreach ($option in $Spec) {
        if ($option.Long.TrimStart('-').Replace('-', '') -ceq $normalized) { return $option.Long }
        if ($option.Short -and $option.Short.TrimStart('-') -ceq $normalized) { return $option.Short }
    }
    $null
}

function ConvertFrom-ResikArgument {
    <#
    .SYNOPSIS
        Parses raw command-line arguments into a Resik options object.
    .DESCRIPTION
        Options are case-sensitive and lowercase. Value options accept
        "--only uv,pip", "--only=uv,pip", and "-o uv,pip". Short options cannot
        be bundled. Unset value options are $null.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]] $Arguments = @()
    )

    $spec = @(Get-ResikOptionSpec)
    $options = [ordered]@{}
    foreach ($option in $spec) {
        $options[$option.Key] = if ($option.ValueName) { $null } else { $false }
    }

    $tokens = @(@($Arguments) | ForEach-Object { ConvertTo-ResikArgumentString $_ })
    $index = 0
    while ($index -lt $tokens.Count) {
        $token = $tokens[$index]
        $index++

        if (-not $token.StartsWith('-') -or $token -eq '-' -or $token -eq '--') {
            throw [System.ArgumentException]::new("Unexpected argument '$token'. See: resik --help")
        }

        $name = $token
        $inlineValue = $null
        if ($token.StartsWith('--') -and $token.Contains('=')) {
            $separator = $token.IndexOf('=')
            $name = $token.Substring(0, $separator)
            $inlineValue = $token.Substring($separator + 1)
        }

        $option = $spec | Where-Object { $_.Long -ceq $name -or ($_.Short -and $_.Short -ceq $name) } |
            Select-Object -First 1
        if ($null -eq $option) {
            $message = "Unknown option '$name'."
            $suggestion = Get-ResikOptionSuggestion -Token $name -Spec $spec
            if ($suggestion) { $message += " Did you mean ${suggestion}?" }
            throw [System.ArgumentException]::new("$message See: resik --help")
        }

        if (-not $option.ValueName) {
            if ($null -ne $inlineValue) {
                throw [System.ArgumentException]::new("$($option.Long) does not take a value.")
            }
            $options[$option.Key] = $true
            continue
        }

        if ($null -ne $options[$option.Key]) {
            throw [System.ArgumentException]::new("$($option.Long) was given more than once.")
        }
        if ($null -ne $inlineValue) {
            $value = $inlineValue
        }
        elseif ($index -lt $tokens.Count -and -not $tokens[$index].StartsWith('-')) {
            $value = $tokens[$index]
            $index++
        }
        else {
            throw [System.ArgumentException]::new("$($option.Long) requires a value: $($option.Long) $($option.ValueName)")
        }
        if ($value.Length -eq 0) {
            throw [System.ArgumentException]::new("$($option.Long) requires a non-empty value.")
        }
        $options[$option.Key] = $value
    }

    [pscustomobject]$options
}
