BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'Get-ResikOptionSpec' {
    It 'uses lowercase, unique option names' {
        $spec = @(Get-ResikOptionSpec)
        $names = @($spec.Long) + @($spec | Where-Object Short | ForEach-Object Short)

        $names | Where-Object { $_ -cne $_.ToLowerInvariant() } | Should -BeNullOrEmpty
        @($names | Select-Object -Unique).Count | Should -Be $names.Count
        $spec.Long | ForEach-Object { $_ | Should -Match '^--[a-z]+(-[a-z]+)*$' }
        $spec | Where-Object Short | ForEach-Object { $_.Short | Should -Match '^-[a-z]$' }
    }
}

Describe 'ConvertFrom-ResikArgument' {
    It 'defaults every switch to false and every value to null' {
        $options = ConvertFrom-ResikArgument -Arguments @()

        $options.Help | Should -BeFalse
        $options.DryRun | Should -BeFalse
        $null -eq $options.Only | Should -BeTrue
        $null -eq $options.ReportPath | Should -BeTrue
    }

    It 'sets <Key> from <Token>' -ForEach @(
        @{ Token = '-h'; Key = 'Help' }
        @{ Token = '--help'; Key = 'Help' }
        @{ Token = '-v'; Key = 'Version' }
        @{ Token = '--version'; Key = 'Version' }
        @{ Token = '-n'; Key = 'DryRun' }
        @{ Token = '--dry-run'; Key = 'DryRun' }
        @{ Token = '-a'; Key = 'All' }
        @{ Token = '--all'; Key = 'All' }
        @{ Token = '--non-interactive'; Key = 'NonInteractive' }
        @{ Token = '-f'; Key = 'Force' }
        @{ Token = '--force'; Key = 'Force' }
    ) {
        (ConvertFrom-ResikArgument -Arguments @($Token)).$Key | Should -BeTrue
    }

    It 'reads --only from <Description>' -ForEach @(
        @{ Description = 'a separate argument'; Arguments = @('--only', 'uv,pip') }
        @{ Description = '--only=value'; Arguments = @('--only=uv,pip') }
        @{ Description = 'the short form'; Arguments = @('-o', 'uv,pip') }
        @{ Description = 'an in-process array'; Arguments = @('--only', @('uv', 'pip')) }
        @{ Description = 'an in-process split --only=value'; Arguments = @(, @('--only=uv', 'pip')) }
    ) {
        (ConvertFrom-ResikArgument -Arguments $Arguments).Only | Should -BeExactly 'uv,pip'
    }

    It 'reads --report-path in both forms' {
        (ConvertFrom-ResikArgument -Arguments @('--report-path', 'r.json')).ReportPath | Should -BeExactly 'r.json'
        (ConvertFrom-ResikArgument -Arguments @('--report-path=r.json')).ReportPath | Should -BeExactly 'r.json'
    }

    It 'combines several options' {
        $options = ConvertFrom-ResikArgument -Arguments @('--non-interactive', '-n', '--only', 'uv')

        $options.NonInteractive | Should -BeTrue
        $options.DryRun | Should -BeTrue
        $options.Only | Should -BeExactly 'uv'
    }

    It 'rejects <Token> and suggests <Suggestion>' -ForEach @(
        @{ Token = '-help'; Suggestion = '--help' }
        @{ Token = '-dryrun'; Suggestion = '--dry-run' }
        @{ Token = '--dryrun'; Suggestion = '--dry-run' }
        @{ Token = '-noninteractive'; Suggestion = '--non-interactive' }
        @{ Token = '-reportpath'; Suggestion = '--report-path' }
        @{ Token = '--Help'; Suggestion = '--help' }
        @{ Token = '-H'; Suggestion = '-h' }
    ) {
        # Exact match, so a missing or wrong suggestion cannot slip through a wildcard.
        $message = $null
        try { ConvertFrom-ResikArgument -Arguments @($Token) } catch [System.ArgumentException] { $message = $_.Exception.Message }

        $message | Should -BeExactly "Unknown option '$Token'. Did you mean ${Suggestion}? See: resik --help"
    }

    It 'rejects <Description>' -ForEach @(
        @{ Description = 'an unknown option'; Arguments = @('--nope'); Message = "*Unknown option '--nope'.*" }
        @{ Description = 'bundled short options'; Arguments = @('-na'); Message = "*Unknown option '-na'*" }
        @{ Description = 'a positional argument'; Arguments = @('clean'); Message = "*Unexpected argument 'clean'*" }
        @{ Description = 'a bare double dash'; Arguments = @('--'); Message = "*Unexpected argument '--'*" }
        @{ Description = 'a value on a switch'; Arguments = @('--all=yes'); Message = '*--all does not take a value*' }
        @{ Description = 'a missing value'; Arguments = @('--only'); Message = '*--only requires a value*' }
        @{ Description = 'an option in place of a value'; Arguments = @('--only', '--all'); Message = '*--only requires a value*' }
        @{ Description = 'an empty inline value'; Arguments = @('--only='); Message = '*--only requires a non-empty value*' }
        @{ Description = 'a repeated value option'; Arguments = @('-o', 'uv', '--only', 'pip'); Message = '*--only was given more than once*' }
    ) {
        { ConvertFrom-ResikArgument -Arguments $Arguments } |
            Should -Throw -ExpectedMessage $Message -ExceptionType ([System.ArgumentException])
    }
}
