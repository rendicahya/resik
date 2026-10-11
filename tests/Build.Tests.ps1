BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')

    $script:buildScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\Build-Release.ps1'
    $script:powershellPath = (Get-Process -Id $PID).Path
}

Describe 'Build-Release.ps1' {
    BeforeAll {
        $script:outDir = Join-Path $TestDrive 'dist'
        $script:build = & $script:buildScript -OutputDirectory $script:outDir
        $script:extracted = Join-Path $TestDrive 'extracted'
        Expand-Archive -LiteralPath $script:build.Path -DestinationPath $script:extracted
    }

    It 'names the archive after the current version' {
        $script:build.Version | Should -BeExactly (Get-ResikVersion)
        Split-Path -Leaf $script:build.Path | Should -BeExactly "resik-$(Get-ResikVersion).zip"
    }

    It 'reports the SHA-256 of the archive it wrote' {
        $script:build.SHA256 | Should -BeExactly (Get-FileHash -LiteralPath $script:build.Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    It 'puts Resik.ps1, its sources, LICENSE, and README at the archive root' {
        foreach ($relative in @('Resik.ps1', 'Core\Cli.ps1', 'Core\Models.ps1', 'Reporting\ConsoleReport.ps1', 'LICENSE', 'README.md')) {
            Join-Path $script:extracted $relative | Should -Exist
        }
    }

    It 'contains no tests or development files' {
        Join-Path $script:extracted 'tests' | Should -Not -Exist
        Join-Path $script:extracted 'tools' | Should -Not -Exist
        Join-Path $script:extracted 'CLAUDE.md' | Should -Not -Exist
    }

    It 'produces a runnable package' {
        $output = & $script:powershellPath -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File (Join-Path $script:extracted 'Resik.ps1') --version
        $LASTEXITCODE | Should -Be 0
        "$output" | Should -BeExactly "resik $(Get-ResikVersion)"
    }

    It 'refuses to overwrite an existing archive' {
        { & $script:buildScript -OutputDirectory $script:outDir } | Should -Throw -ExpectedMessage '*already exists*'
    }
}
