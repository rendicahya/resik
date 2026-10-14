BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')

    $script:repoRoot = Split-Path -Parent $PSScriptRoot
    $script:entryPoint = Join-Path $repoRoot 'src\Resik\Resik.ps1'
    # Run the entry point with the same PowerShell executable as the tests.
    $script:powershellPath = (Get-Process -Id $PID).Path

    function Invoke-ResikProcess {
        # Standard input is always redirected and answers "n", so a child
        # process can never be told to clean.
        param([string[]] $Arguments)
        # Windows PowerShell 5.1 wraps a native command's stderr in error
        # records under 2>&1, which throw when the caller's preference is Stop.
        $ErrorActionPreference = 'Continue'
        $output = 'n' | & $script:powershellPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:entryPoint @Arguments 2>&1 |
            ForEach-Object { "$_" }
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }

    function Get-ResikExampleOption {
        # Returns every option-like token in "resik ..." command examples.
        param([string] $Text)
        foreach ($line in ($Text -split "`r?`n")) {
            if ($line.Trim() -match '^resik(\s|$)') {
                [regex]::Matches($line, '(?<=\s)--?[^\s=]+') | ForEach-Object { $_.Value }
            }
        }
    }
}

Describe 'Invoke-ResikCli' {
    BeforeEach {
        $script:errors = New-Object System.Collections.Generic.List[string]
        Mock Write-ResikError { $script:errors.Add($Message) }
        Mock Write-Host {}
    }

    It 'shows help for <_> and exits 0' -ForEach @('-h', '--help') {
        Invoke-ResikCli -Arguments @($_) | Should -Be 0
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*Usage:*' }
    }

    It 'shows the version for <_> and exits 0' -ForEach @('-v', '--version') {
        Invoke-ResikCli -Arguments @($_) | Should -Be 0
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq "resik $(Get-ResikVersion)" }
    }

    It 'reports argument errors as usage errors' {
        Invoke-ResikCli -Arguments @('-dryrun') | Should -Be 2
        $script:errors | Should -BeLike "*Unknown option '-dryrun'. Did you mean --dry-run?*"
    }

    It 'rejects --report-path until reporting is implemented' {
        Invoke-ResikCli -Arguments @('--dry-run', '--all', '--report-path', 'report.json') | Should -Be 2
        $script:errors | Should -BeLike '*--report-path is not implemented*'
    }

    It 'requires an explicit selection with --non-interactive' {
        Invoke-ResikCli -Arguments @('--non-interactive', '--dry-run') | Should -Be 2
        $script:errors | Should -BeLike '*--non-interactive requires --all or --only*'
    }

    It 'rejects --all with --only' {
        Invoke-ResikCli -Arguments @('-n', '-a', '-o', 'fake') -Targets @(New-TestTarget) | Should -Be 2
        $script:errors | Should -BeLike '*--all and --only cannot be used together*'
    }

    It 'rejects unknown target IDs' {
        Invoke-ResikCli -Arguments @('--dry-run', '--only=nope') -Targets @(New-TestTarget) | Should -Be 2
        $script:errors | Should -BeLike '*Unknown target ID(s): nope*'
    }

    It 'selects targets with --only' {
        Invoke-ResikCli -Arguments @('--dry-run', '--only', 'b') -Targets @((New-TestTarget -Id 'a'), (New-TestTarget -Id 'b')) |
            Should -Be 0
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '  b  *' }
        Should -Invoke Write-Host -Times 0 -ParameterFilter { "$Object" -like '  a  *' }
    }

    It 'succeeds with no registered targets' {
        Invoke-ResikCli -Arguments @('--dry-run', '--all') -Targets @() | Should -Be 0
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*No cleanup targets are registered*' }
    }

    It 'leaves the filesystem untouched during --dry-run' {
        $cache = Join-Path $TestDrive 'cache'
        New-Item -ItemType Directory -Path $cache | Out-Null
        Set-Content -Path (Join-Path $cache 'entry.bin') -Value 'data' -Encoding ASCII
        $before = Get-ChildItem -Recurse $cache | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }

        $target = New-TestTarget -Analyze {
            $size = (Get-ChildItem -Recurse -File $cache | Measure-Object -Property Length -Sum).Sum
            [pscustomobject]@{ EstimatedBytes = $size }
        }.GetNewClosure()

        Invoke-ResikCli -Arguments @('--dry-run', '--all') -Targets @($target) | Should -Be 0

        $after = Get-ChildItem -Recurse $cache | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }
        $after | Should -Be $before
    }

    It 'exits 1 when a target fails, after analyzing the rest' {
        $targets = @((New-TestTarget -Id 'bad' -Analyze { throw 'boom' }), (New-TestTarget -Id 'good'))

        Invoke-ResikCli -Arguments @('--dry-run', '--all') -Targets $targets | Should -Be 1
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '  good  *' }
    }

    It 'never runs Clean during --dry-run, even with --force' {
        $script:cleaned = $false
        $target = New-TestTarget -Clean { $script:cleaned = $true; [pscustomobject]@{ Status = 'Success' } }

        Invoke-ResikCli -Arguments @('--dry-run', '--all', '--force') -Targets @($target) | Should -Be 0
        $script:cleaned | Should -BeFalse
    }
}

Describe 'Invoke-ResikCli interactive selection' {
    BeforeEach {
        $script:errors = New-Object System.Collections.Generic.List[string]
        $script:cleaned = New-Object System.Collections.Generic.List[string]
        Mock Write-ResikError { $script:errors.Add($Message) }
        Mock Write-Host {}
        Mock Get-ResikPickerMode { 'Keys' }
        Mock Test-ResikInteractiveInput { $true }
        Mock Read-ResikConfirmation { $true }

        $cleanedList = $script:cleaned
        $script:targets = @(
            (New-TestTarget -Id 'a' -Clean { $cleanedList.Add('a'); [pscustomobject]@{ Status = 'Success' } }.GetNewClosure()),
            (New-TestTarget -Id 'b' -Clean { $cleanedList.Add('b'); [pscustomobject]@{ Status = 'Success' } }.GetNewClosure())
        )
    }

    It 'opens the picker for <Description>' -ForEach @(
        @{ Description = 'bare resik'; Arguments = @() }
        @{ Description = 'a null argument list'; Arguments = $null }
        @{ Description = '--force alone'; Arguments = @('--force') }
    ) {
        Mock Select-ResikTargetInteractive { [pscustomobject]@{ Cancelled = $true; Targets = @() } }

        Invoke-ResikCli -Arguments $Arguments -Targets $script:targets | Should -Be 0

        Should -Invoke Select-ResikTargetInteractive -Times 1 -Exactly
        $script:errors | Should -BeNullOrEmpty
    }

    It 'gives the picker the analysis of every target' {
        Mock Select-ResikTargetInteractive { [pscustomobject]@{ Cancelled = $true; Targets = @() } }

        Invoke-ResikCli -Arguments @() -Targets $script:targets | Out-Null

        Should -Invoke Select-ResikTargetInteractive -ParameterFilter {
            $Analysis.Count -eq 2 -and @($Analysis | Where-Object Status -eq 'AnalysisOnly').Count -eq 2 -and $Mode -eq 'Keys' -and -not $DryRun
        }
    }

    It 'cleans only the picked targets, after confirmation' {
        $script:pick = $script:targets[1]
        Mock Select-ResikTargetInteractive { [pscustomobject]@{ Cancelled = $false; Targets = @($script:pick) } }

        Invoke-ResikCli -Arguments @() -Targets $script:targets | Should -Be 0

        Should -Invoke Read-ResikConfirmation -Times 1 -Exactly
        $script:cleaned | Should -Be @('b')
    }

    It 'cleans nothing when the confirmation is declined' {
        Mock Read-ResikConfirmation { $false }
        $script:pick = $script:targets[0]
        Mock Select-ResikTargetInteractive { [pscustomobject]@{ Cancelled = $false; Targets = @($script:pick) } }

        Invoke-ResikCli -Arguments @() -Targets $script:targets | Should -Be 0

        $script:cleaned | Should -BeNullOrEmpty
    }

    It 'skips the confirmation, not the picker, with --force' {
        $script:pick = $script:targets[0]
        Mock Select-ResikTargetInteractive { [pscustomobject]@{ Cancelled = $false; Targets = @($script:pick) } }

        Invoke-ResikCli -Arguments @('-f') -Targets $script:targets | Should -Be 0

        Should -Invoke Select-ResikTargetInteractive -Times 1 -Exactly
        Should -Invoke Read-ResikConfirmation -Times 0
        $script:cleaned | Should -Be @('a')
    }

    It 'changes nothing when the picker is cancelled' {
        Mock Select-ResikTargetInteractive { [pscustomobject]@{ Cancelled = $true; Targets = @() } }

        Invoke-ResikCli -Arguments @() -Targets $script:targets | Should -Be 0

        $script:cleaned | Should -BeNullOrEmpty
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq 'Cancelled. Nothing was changed.' }
    }

    It 'changes nothing when nothing is picked' {
        Mock Select-ResikTargetInteractive { [pscustomobject]@{ Cancelled = $false; Targets = @() } }

        Invoke-ResikCli -Arguments @() -Targets $script:targets | Should -Be 0

        Should -Invoke Read-ResikConfirmation -Times 0
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq 'Nothing selected. Nothing was changed.' }
    }

    It 'only reports the picked targets with --dry-run, and never cleans' {
        $script:pick = $script:targets[0]
        Mock Select-ResikTargetInteractive { [pscustomobject]@{ Cancelled = $false; Targets = @($script:pick) } }

        Invoke-ResikCli -Arguments @('--dry-run') -Targets $script:targets | Should -Be 0

        Should -Invoke Select-ResikTargetInteractive -ParameterFilter { $DryRun }
        Should -Invoke Read-ResikConfirmation -Times 0
        $script:cleaned | Should -BeNullOrEmpty
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '  a  *' }
        Should -Invoke Write-Host -Times 0 -ParameterFilter { "$Object" -like '  b  *' }
    }

    It 'uses the numbered list when the terminal has no key input' {
        Mock Get-ResikPickerMode { 'Numbered' }
        Mock Select-ResikTargetInteractive { [pscustomobject]@{ Cancelled = $true; Targets = @() } }

        Invoke-ResikCli -Arguments @() -Targets $script:targets | Out-Null

        Should -Invoke Select-ResikTargetInteractive -ParameterFilter { $Mode -eq 'Numbered' }
    }

    It 'exits 2 without analyzing when nobody can answer the picker' {
        Mock Get-ResikPickerMode { 'None' }
        Mock Invoke-ResikAnalysis {}
        Mock Select-ResikTargetInteractive {}

        Invoke-ResikCli -Arguments @() -Targets $script:targets | Should -Be 2

        $script:errors | Should -BeLike '*Interactive selection needs a terminal*'
        Should -Invoke Invoke-ResikAnalysis -Times 0
        Should -Invoke Select-ResikTargetInteractive -Times 0
    }
}

Describe 'Invoke-ResikCli cleanup' {
    BeforeEach {
        $script:errors = New-Object System.Collections.Generic.List[string]
        $script:cleaned = New-Object System.Collections.Generic.List[string]
        Mock Write-ResikError { $script:errors.Add($Message) }
        Mock Write-Host {}
        Mock Test-ResikInteractiveInput { $true }
        Mock Read-ResikConfirmation { $true }

        function New-CleanableTarget {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Creates an in-memory object only.')]
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Status',
                Justification = 'Used inside the Clean closure.')]
            param([string] $Id = 'fake', [string] $Status = 'Success', [scriptblock] $Analyze)
            # A closure cannot see $script: variables, so capture the list itself.
            $cleanedList = $script:cleaned
            $clean = { $cleanedList.Add($Id); [pscustomobject]@{ Status = $Status; MeasuredBytes = 100 } }.GetNewClosure()
            $targetArgs = @{ Id = $Id; Clean = $clean }
            if ($Analyze) { $targetArgs.Analyze = $Analyze }
            New-TestTarget @targetArgs
        }
    }

    It 'asks for confirmation, then cleans and exits 0' {
        Invoke-ResikCli -Arguments @('--only', 'fake') -Targets @(New-CleanableTarget) | Should -Be 0

        Should -Invoke Read-ResikConfirmation -Times 1 -Exactly
        $script:cleaned | Should -Be @('fake')
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '  fake  *Cleaned*' }
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like 'Measured cache reduction: 100 B*' }
    }

    It 'shows the plan before asking' {
        Invoke-ResikCli -Arguments @('--all') -Targets @(New-CleanableTarget) | Should -Be 0
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like 'Resik will clean*' }
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*Test target*' }
    }

    It 'cleans nothing when the user declines' {
        Mock Read-ResikConfirmation { $false }

        Invoke-ResikCli -Arguments @('--all') -Targets @(New-CleanableTarget) | Should -Be 0

        $script:cleaned | Should -BeNullOrEmpty
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like 'Cancelled. Nothing was changed.*' }
    }

    It 'skips the prompt with --force' {
        Invoke-ResikCli -Arguments @('--all', '-f') -Targets @(New-CleanableTarget) | Should -Be 0

        Should -Invoke Read-ResikConfirmation -Times 0
        $script:cleaned | Should -Be @('fake')
    }

    It 'requires --force with --non-interactive and cleans nothing without it' {
        Invoke-ResikCli -Arguments @('--non-interactive', '--all') -Targets @(New-CleanableTarget) | Should -Be 2

        Should -Invoke Read-ResikConfirmation -Times 0
        $script:cleaned | Should -BeNullOrEmpty
        $script:errors | Should -BeLike '*Add --force to confirm*'
    }

    It 'cleans with --non-interactive --force' {
        Invoke-ResikCli -Arguments @('--non-interactive', '--force', '--all') -Targets @(New-CleanableTarget) | Should -Be 0
        $script:cleaned | Should -Be @('fake')
    }

    It 'requires --force when input cannot be prompted for' {
        Mock Test-ResikInteractiveInput { $false }

        Invoke-ResikCli -Arguments @('--all') -Targets @(New-CleanableTarget) | Should -Be 2

        Should -Invoke Read-ResikConfirmation -Times 0
        $script:cleaned | Should -BeNullOrEmpty
    }

    It 'only cleans targets whose analysis succeeded' {
        $targets = @(
            (New-CleanableTarget -Id 'broken' -Analyze { throw 'boom' }),
            (New-CleanableTarget -Id 'good')
        )

        Invoke-ResikCli -Arguments @('--all') -Targets $targets | Should -Be 1

        $script:cleaned | Should -Be @('good')
    }

    It 'does not clean analysis-only targets' {
        Invoke-ResikCli -Arguments @('--all') -Targets @(New-TestTarget) | Should -Be 0

        Should -Invoke Read-ResikConfirmation -Times 0
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq 'Nothing to clean.' }
    }

    It 'keeps cleaning after a target fails, and exits 1' {
        $targets = @(
            (New-TestTarget -Id 'bad' -Clean { throw 'boom' }),
            (New-CleanableTarget -Id 'good')
        )

        Invoke-ResikCli -Arguments @('--all', '--force') -Targets $targets | Should -Be 1

        $script:cleaned | Should -Be @('good')
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '  bad  *Failed*' }
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq '    Cleanup failed: boom' }
    }

    It 'exits 1 on partial success' {
        Invoke-ResikCli -Arguments @('--all', '--force') -Targets @(New-CleanableTarget -Status PartialSuccess) | Should -Be 1
    }
}

Describe 'Documented options' {
    BeforeAll {
        $script:spec = @(Get-ResikOptionSpec)
        $script:validTokens = @($script:spec.Long) + @($script:spec | Where-Object Short | ForEach-Object Short)
    }

    It 'help text lists every option' {
        $help = Get-ResikHelpText
        foreach ($option in $script:spec) {
            $help | Should -BeLike "*$($option.Long)*"
            if ($option.Short) { $help | Should -BeLike "*$($option.Short), $($option.Long)*" }
        }
    }

    It '<Name> uses only valid options in resik examples' -ForEach @(
        @{ Name = 'help text'; Path = $null }
        @{ Name = 'README.md'; Path = 'README.md' }
        @{ Name = 'docs/RELEASING.md'; Path = 'docs\RELEASING.md' }
    ) {
        $text = if ($Path) { Get-Content -Raw (Join-Path $script:repoRoot $Path) } else { Get-ResikHelpText }
        $tokens = @(Get-ResikExampleOption $text)

        $tokens.Count | Should -BeGreaterThan 0
        $tokens | Where-Object { $script:validTokens -cnotcontains $_ } | Should -BeNullOrEmpty
    }
}

Describe 'Resik.ps1 entry point' {
    It 'prints the version' {
        $run = Invoke-ResikProcess -Arguments '--version'
        $run.ExitCode | Should -Be 0
        $run.Output | Should -BeExactly "resik $(Get-ResikVersion)"
    }

    It 'refuses the picker when input is redirected, in a child process and in-process' {
        # Input is redirected here, so no picker can open and nothing is analyzed.
        $run = Invoke-ResikProcess -Arguments @()
        $run.ExitCode | Should -Be 2
        $run.Output | Should -BeLike '*Interactive selection needs a terminal*'

        $ErrorActionPreference = 'Continue'  # see Invoke-ResikProcess
        $output = 'n' | & $script:powershellPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "& '$script:entryPoint'; exit `$LASTEXITCODE" 2>&1 |
            ForEach-Object { "$_" }
        $LASTEXITCODE | Should -Be 2
        ($output -join "`n") | Should -BeLike '*Interactive selection needs a terminal*'
    }

    It 'prints help for -h' {
        $run = Invoke-ResikProcess -Arguments '-h'
        $run.ExitCode | Should -Be 0
        $run.Output | Should -BeLike '*-n, --dry-run*'
    }

    It 'runs a read-only dry run of the registered targets' {
        # Only inspection runs: uv is skipped if missing, otherwise analyzed.
        $run = Invoke-ResikProcess -Arguments '--non-interactive', '-n', '-a'
        $run.ExitCode | Should -Be 0
        $run.Output | Should -BeLike '*Dry run:*'
        $run.Output | Should -Match '(?m)^(  uv\s|Not found: (.*, )?uv(,|\r?$))'
    }

    It 'refuses to clean without --force when input is redirected, without cleaning anything' {
        # The child's input is redirected, so it must stop before cleanup.
        # If uv is missing or has no cache, there is nothing to clean and it exits 0.
        $run = Invoke-ResikProcess -Arguments '--only', 'uv'
        if ($run.Output -like '*Resik will clean*') {
            $run.ExitCode | Should -Be 2
            $run.Output | Should -BeLike '*Add --force to confirm*'
            $run.Output | Should -Not -BeLike '*Running: uv cache clean*'
        }
        else {
            $run.ExitCode | Should -Be 0
            $run.Output | Should -BeLike '*Nothing to clean.*'
        }
    }

    It 'reports unknown IDs passed as one comma-separated -File argument' {
        $run = Invoke-ResikProcess -Arguments '--dry-run', '--only=foo,bar'
        $run.ExitCode | Should -Be 2
        $run.Output | Should -BeLike '*Unknown target ID(s): foo, bar*'
    }

    It 'rejects the old single-dash form with a hint' {
        $run = Invoke-ResikProcess -Arguments '-dryrun'
        $run.ExitCode | Should -Be 2
        $run.Output | Should -BeLike "*Did you mean --dry-run?*"
    }

    It 'rejects positional arguments' {
        $run = Invoke-ResikProcess -Arguments 'clean'
        $run.ExitCode | Should -Be 2
    }

    It 'parses arguments the same way when invoked in-process, as the Scoop PowerShell shim does' {
        $ErrorActionPreference = 'Continue'  # see Invoke-ResikProcess
        $output = & $script:powershellPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "& '$script:entryPoint' --dry-run --only=foo,bar; exit `$LASTEXITCODE" 2>&1 |
            ForEach-Object { "$_" }
        $LASTEXITCODE | Should -Be 2
        ($output -join "`n") | Should -BeLike '*Unknown target ID(s): foo, bar*'
    }
}
