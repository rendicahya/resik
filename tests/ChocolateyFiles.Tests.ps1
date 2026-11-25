BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')

    function New-TestText {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Writes only to TestDrive.')]
        param([string] $Path, [string] $Text)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        [System.IO.File]::WriteAllText($Path, $Text)
    }
}

Describe 'Chocolatey file targets' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ('choco-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $script:root 'choco.exe') -Size 10
        New-Item -ItemType Directory -Force -Path (Join-Path $script:root 'lib\chocolatey') | Out-Null
        $script:temp = Join-Path $TestDrive ('t-' + [guid]::NewGuid().ToString('N') + '\Temp')
        $script:winTemp = Join-Path $TestDrive ('w-' + [guid]::NewGuid().ToString('N') + '\Temp')
        New-Item -ItemType Directory -Force -Path $script:temp, $script:winTemp | Out-Null
        $script:listOutput = "chocolatey|2.7.3`r`nfoo|1.2`r`n"
        Mock Write-Host {}
        Mock Get-ResikChocolateyRoot { $script:root }
        Mock Get-ResikUserTempPath { $script:temp }
        Mock Get-ResikWindowsTempPath { $script:winTemp }
        Mock Get-ResikChocolateyMajorVersion { 2 }
        Mock Test-ResikAdministrator { $true }
        Mock Test-ResikChocolateyRunning { $false }
        Mock Invoke-ResikNativeCommand { throw 'Unexpected command.' }
        Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut $script:listOutput } -ParameterFilter {
            ($ArgumentList -join ' ') -ceq 'list --limit-output'
        }
    }

    It 'are not detected without Chocolatey: <Factory>' -ForEach @(
        @{ Factory = 'New-ResikChocolateyLogTarget' }, @{ Factory = 'New-ResikChocolateyLeftoverTarget' }
        @{ Factory = 'New-ResikChocolateyShimTarget' }, @{ Factory = 'New-ResikChocolateyInstallerTarget' }
        @{ Factory = 'New-ResikChocolateyDownloadTarget' }
    ) {
        $script:root = Join-Path $TestDrive 'missing-choco'
        $result = Invoke-ResikTargetAnalysis -Target (& $Factory)
        $result.Status | Should -BeExactly 'Skipped'
        $result.Message | Should -BeLike 'Not detected:*'
    }

    It 'have no Clean without administrator rights, and say why: <Factory>' -ForEach @(
        @{ Factory = 'New-ResikChocolateyLogTarget' }, @{ Factory = 'New-ResikChocolateyLeftoverTarget' }
        @{ Factory = 'New-ResikChocolateyShimTarget' }, @{ Factory = 'New-ResikChocolateyInstallerTarget' }
    ) {
        Mock Test-ResikAdministrator { $false }
        (& $Factory).Clean | Should -BeNullOrEmpty
    }

    It 'delete nothing while Chocolatey runs or rights are gone: <Factory>' -ForEach @(
        @{ Factory = 'New-ResikChocolateyLogTarget' }, @{ Factory = 'New-ResikChocolateyLeftoverTarget' }
        @{ Factory = 'New-ResikChocolateyShimTarget' }, @{ Factory = 'New-ResikChocolateyInstallerTarget' }
    ) {
        New-TestFile -Path (Join-Path $script:root 'logs\chocolatey.1.log')
        New-TestFile -Path (Join-Path $script:root 'lib-bad\x\1.0\x.nupkg')
        $target = & $Factory
        Mock Test-ResikChocolateyRunning { $true }
        $result = Invoke-ResikTargetCleanup -Target $target
        $result.Status | Should -BeExactly 'Skipped'
        $result.Message | Should -BeLike 'Chocolatey is running*'
        Mock Test-ResikAdministrator { $false }
        (Invoke-ResikTargetCleanup -Target $target).Message | Should -BeLike 'Needs administrator rights*'
        Join-Path $script:root 'logs\chocolatey.1.log' | Should -Exist
        Join-Path $script:root 'lib-bad\x\1.0\x.nupkg' | Should -Exist
    }

    It 'share one picker group and only choco-installers is explicit only' {
        $targets = @(Get-ResikTargetCatalog | Where-Object { $_.Id -like 'choco*' })
        $targets.Id | Should -Be @('choco', 'choco-downloads', 'choco-logs', 'choco-leftovers', 'choco-shims', 'choco-installers')
        @($targets.Group | Select-Object -Unique) | Should -Be @('Chocolatey')
        @($targets | Where-Object { $_.ExplicitOnly } | ForEach-Object { $_.Id }) | Should -Be @('choco-installers')
    }

    Context 'choco-downloads' {
        BeforeEach {
            New-TestFile -Path (Join-Path $script:temp 'chocolatey\foo\1.0\setup.exe') -Size 4000
            New-TestFile -Path (Join-Path $script:temp 'other\keep.txt')
            New-TestFile -Path (Join-Path $script:winTemp 'chocolatey\bar\setup.exe') -Size 500
        }

        It 'needs no administrator rights, and leaves the Windows temp folder alone without them' {
            Mock Test-ResikAdministrator { $false }
            $target = New-ResikChocolateyDownloadTarget
            (Invoke-ResikTargetAnalysis -Target $target).EstimatedBytes | Should -Be 4000
            $result = Invoke-ResikTargetCleanup -Target $target
            $result.Status | Should -BeExactly 'Success'
            $result.MeasuredBytes | Should -Be 4000
            Join-Path $script:temp 'chocolatey\foo' | Should -Not -Exist
            Join-Path $script:temp 'other\keep.txt' | Should -Exist
            Join-Path $script:winTemp 'chocolatey\bar\setup.exe' | Should -Exist
        }

        It 'includes the Windows temp folder as administrator' {
            (Invoke-ResikTargetCleanup -Target (New-ResikChocolateyDownloadTarget)).MeasuredBytes | Should -Be 4500
        }

        It 'treats an empty cacheLocation as the default' {
            New-TestText -Path (Join-Path $script:root 'config\chocolatey.config') -Text '<chocolatey><config><add key="cacheLocation" value="" /></config></chocolatey>'
            (New-ResikChocolateyDownloadTarget).Clean | Should -Not -BeNullOrEmpty
        }

        It 'only reports a folder chosen with cacheLocation' {
            $custom = Join-Path $TestDrive 'mycache'
            New-TestFile -Path (Join-Path $custom 'a.bin') -Size 77
            $ready = New-ResikChocolateyDownloadTarget
            New-TestText -Path (Join-Path $script:root 'config\chocolatey.config') -Text "<chocolatey><config><add key=`"cacheLocation`" value=`"$custom`" /></config></chocolatey>"
            $target = New-ResikChocolateyDownloadTarget
            $target.Clean | Should -BeNullOrEmpty
            $result = Invoke-ResikTargetAnalysis -Target $target
            $result.EstimatedBytes | Should -Be 77
            $result.Message | Should -BeLike '*cacheLocation*'
            (Invoke-ResikTargetCleanup -Target $ready).Status | Should -BeExactly 'Skipped'
            Join-Path $custom 'a.bin' | Should -Exist
            Join-Path $script:temp 'chocolatey\foo\1.0\setup.exe' | Should -Exist
        }

        It 'reports an unreadable configuration instead of guessing' {
            New-TestText -Path (Join-Path $script:root 'config\chocolatey.config') -Text '<chocolatey><config>'
            $target = New-ResikChocolateyDownloadTarget
            $target.Clean | Should -BeNullOrEmpty
            (Invoke-ResikTargetAnalysis -Target $target).Status | Should -BeExactly 'Failed'
        }

        It 'deletes nothing while Chocolatey runs' {
            Mock Test-ResikChocolateyRunning { $true }
            (Invoke-ResikTargetCleanup -Target (New-ResikChocolateyDownloadTarget)).Status | Should -BeExactly 'Skipped'
            Join-Path $script:temp 'chocolatey\foo\1.0\setup.exe' | Should -Exist
        }

        It 'ignores a download folder that is a junction' {
            $outside = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().ToString('N'))
            New-TestFile -Path (Join-Path $outside 'keep.txt')
            Remove-Item -LiteralPath (Join-Path $script:winTemp 'chocolatey') -Recurse -Force
            New-Item -ItemType Junction -Path (Join-Path $script:winTemp 'chocolatey') -Target $outside | Out-Null
            (Invoke-ResikTargetCleanup -Target (New-ResikChocolateyDownloadTarget)).Status | Should -BeExactly 'Success'
            Join-Path $outside 'keep.txt' | Should -Exist
        }
    }

    Context 'choco-logs' {
        It 'deletes rotated logs and keeps everything else' {
            New-TestFile -Path (Join-Path $script:root 'logs\chocolatey.1.log') -Size 300
            New-TestFile -Path (Join-Path $script:root 'logs\choco.summary.12.log') -Size 30
            foreach ($kept in 'chocolatey.log', 'choco.summary.log', 'chocolatey-agent.log', 'chocolatey.x.log', 'chocolatey.1.log.txt') {
                New-TestFile -Path (Join-Path $script:root "logs\$kept")
            }
            $target = New-ResikChocolateyLogTarget
            (Invoke-ResikTargetAnalysis -Target $target).EstimatedBytes | Should -Be 330
            $result = Invoke-ResikTargetCleanup -Target $target
            $result.Status | Should -BeExactly 'Success'
            $result.MeasuredBytes | Should -Be 330
            @(Get-ChildItem -LiteralPath (Join-Path $script:root 'logs')).Count | Should -Be 5
        }

        It 'reports zero and says rights are not needed when there is nothing' {
            Mock Test-ResikAdministrator { $false }
            $result = Invoke-ResikTargetAnalysis -Target (New-ResikChocolateyLogTarget)
            $result.EstimatedBytes | Should -Be 0
            $result.Message | Should -Not -BeLike '*administrator*'
        }

        It 'reports a log in use as a failure' {
            $log = Join-Path $script:root 'logs\chocolatey.1.log'
            New-TestFile -Path $log
            $stream = [System.IO.File]::Open($log, 'Open', 'Read', 'None')
            try { (Invoke-ResikTargetCleanup -Target (New-ResikChocolateyLogTarget)).Status | Should -BeExactly 'Failed' }
            finally { $stream.Dispose() }
        }
    }

    Context 'choco-leftovers' {
        BeforeEach {
            New-TestFile -Path (Join-Path $script:root 'lib-bad\gone\1.0\gone.nupkg') -Size 1000
            New-TestFile -Path (Join-Path $script:root 'lib-bkp\foo\1.1\foo.nupkg') -Size 200
            New-TestFile -Path (Join-Path $script:root '.chocolatey\foo.1.2.0\.files') -Size 10
            New-TestFile -Path (Join-Path $script:root '.chocolatey\foo.1.1.0\.files') -Size 20
            New-TestFile -Path (Join-Path $script:root '.chocolatey\gone.1.0.0\.registry') -Size 30
            New-TestFile -Path (Join-Path $script:root '.chocolatey\chocolatey.2.7.3\.files') -Size 10
            New-TestFile -Path (Join-Path $script:root '.chocolatey\notes\a.txt') -Size 10
            New-TestFile -Path (Join-Path $script:root 'choco.exe.old') -Size 5000
            New-TestFile -Path (Join-Path $script:root 'bin\choco.exe.old') -Size 40
            New-TestFile -Path (Join-Path $script:root 'helpers\Chocolatey.PowerShell.dll.old') -Size 50
            New-TestFile -Path (Join-Path $script:root 'lib\foo\tools\data.old') -Size 10
            New-TestFile -Path (Join-Path $script:root 'config\chocolatey.config.backup') -Size 10
        }

        It 'deletes leftovers and keeps what installed packages use' {
            $target = New-ResikChocolateyLeftoverTarget
            (Invoke-ResikTargetAnalysis -Target $target).EstimatedBytes | Should -Be 6340
            $result = Invoke-ResikTargetCleanup -Target $target
            $result.Status | Should -BeExactly 'Success'
            $result.MeasuredBytes | Should -Be 6340
            foreach ($gone in 'lib-bad\gone', 'lib-bkp\foo', '.chocolatey\foo.1.1.0', '.chocolatey\gone.1.0.0',
                'choco.exe.old', 'bin\choco.exe.old', 'helpers\Chocolatey.PowerShell.dll.old') {
                Join-Path $script:root $gone | Should -Not -Exist
            }
            foreach ($kept in 'lib-bad', 'lib-bkp', '.chocolatey\foo.1.2.0\.files', '.chocolatey\chocolatey.2.7.3\.files',
                '.chocolatey\notes\a.txt', 'choco.exe', 'lib\foo\tools\data.old', 'config\chocolatey.config.backup') {
                Join-Path $script:root $kept | Should -Exist
            }
        }

        It 'keeps every record when the installed packages are unknown: <Case>' -ForEach @(
            @{ Case = 'choco list failed'; Status = 'NonZeroExit'; Output = ''; Major = 2 }
            @{ Case = 'chocolatey is not listed'; Status = 'Success'; Output = "foo|1.2`r`n"; Major = 2 }
            @{ Case = 'Chocolatey 1 would search online'; Status = 'Success'; Output = "chocolatey|1.4.0`r`n"; Major = 1 }
        ) {
            $script:case = @{ Status = $Status; Output = $Output; Major = $Major }
            Mock Get-ResikChocolateyMajorVersion { $script:case.Major }
            Mock Invoke-ResikNativeCommand { New-TestRunResult -Status $script:case.Status -StdOut $script:case.Output } -ParameterFilter {
                ($ArgumentList -join ' ') -ceq 'list --limit-output'
            }
            $target = New-ResikChocolateyLeftoverTarget
            (Invoke-ResikTargetAnalysis -Target $target).Message | Should -BeLike '*records were not checked*'
            (Invoke-ResikTargetCleanup -Target $target).Status | Should -BeExactly 'Success'
            Join-Path $script:root '.chocolatey\gone.1.0.0\.registry' | Should -Exist
            Join-Path $script:root 'lib-bad\gone' | Should -Not -Exist
        }

        It 'does not follow a junction in place of lib-bad' {
            $outside = Join-Path $TestDrive ('outside-' + [guid]::NewGuid().ToString('N'))
            New-TestFile -Path (Join-Path $outside 'keep.txt')
            Remove-Item -LiteralPath (Join-Path $script:root 'lib-bad') -Recurse -Force
            New-Item -ItemType Junction -Path (Join-Path $script:root 'lib-bad') -Target $outside | Out-Null
            (Invoke-ResikTargetCleanup -Target (New-ResikChocolateyLeftoverTarget)).Status | Should -BeExactly 'Success'
            Join-Path $outside 'keep.txt' | Should -Exist
        }
    }

    Context 'Test-ResikChocolateyRecordOrphaned' {
        It '<Name> with <Installed> installed: <Expected>' -ForEach @(
            @{ Name = 'foo.1.2.0'; Installed = 'foo|1.2'; Expected = $false }
            @{ Name = 'foo.1.2'; Installed = 'foo|1.2.0.0'; Expected = $false }
            @{ Name = 'Foo.1.02.0'; Installed = 'foo|1.2.0'; Expected = $false }
            @{ Name = 'foo.1.2.0-beta1'; Installed = 'foo|1.2.0-Beta1'; Expected = $false }
            @{ Name = 'foo.1.2.0-beta1'; Installed = 'foo|1.2.0'; Expected = $true }
            @{ Name = 'foo.1.1.0'; Installed = 'foo|1.2.0'; Expected = $true }
            @{ Name = 'bar.1.1.0'; Installed = 'foo|1.2.0'; Expected = $true }
            @{ Name = 'foo.extension.1.0.0'; Installed = 'foo|1.2.0'; Expected = $true }
            @{ Name = 'dotnet4.5.2.4.5.2'; Installed = 'dotnet4.5.2|4.5.2'; Expected = $false }
            @{ Name = 'foo'; Installed = 'bar|1.0'; Expected = $false }
            @{ Name = 'foo.1.0.0'; Installed = 'foo|odd'; Expected = $false }
        ) {
            $id, $version = $Installed.Split('|')
            Test-ResikChocolateyRecordOrphaned -Name $Name -Package @([pscustomobject]@{ Id = $id; Version = $version }) | Should -Be $Expected
        }

        It 'keeps the record of a package folder Chocolatey does not list' {
            Test-ResikChocolateyRecordOrphaned -Name 'broken.1.0.0' -LibFolder @('broken') `
                -Package @([pscustomobject]@{ Id = 'chocolatey'; Version = '2.7.3' }) | Should -BeFalse
        }
    }

    Context 'choco-shims' {
        BeforeEach {
            foreach ($name in 'good', 'broken', 'offline', 'program', 'odd') { New-TestFile -Path (Join-Path $script:root "bin\$name.exe") }
            New-TestFile -Path (Join-Path $script:root 'bin\broken.cmd')
            New-TestFile -Path (Join-Path $script:root 'lib\good\good.exe')
            Mock Test-ResikChocolateyShim { (Split-Path -Leaf $Path) -ne 'program.exe' }
            $used = @([System.IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1) })
            $script:offline = @('Q', 'R', 'S', 'T', 'U', 'V' | Where-Object { $used -notcontains $_ })[0]
            Mock Invoke-ResikNativeCommand {
                $target = switch (Split-Path -Leaf $FilePath) {
                    'good.exe' { Join-Path $script:root 'lib\good\good.exe' }
                    'broken.exe' { Join-Path $script:root 'lib\broken\broken.exe' }
                    'offline.exe' { "$($script:offline):\apps\offline.exe" }
                    'odd.exe' { '..\relative.exe' }
                    default { throw 'Only shims may be run.' }
                }
                New-TestRunResult -StdOut "This is a shim, generated by Chocolatey's ShimGenerator (shimgen).`r`n Target: '$target'`r`n Target exists: 'x'`r`n"
            } -ParameterFilter { ($ArgumentList -join ' ') -ceq '--shimgen-help' }
        }

        It 'deletes only shims whose program is gone, and runs nothing else' {
            $target = New-ResikChocolateyShimTarget
            (Invoke-ResikTargetAnalysis -Target $target).EstimatedBytes | Should -Be 100
            (Invoke-ResikTargetCleanup -Target $target).Status | Should -BeExactly 'Success'
            @(Get-ChildItem -LiteralPath (Join-Path $script:root 'bin') | ForEach-Object { $_.Name } | Sort-Object) |
                Should -Be @('broken.cmd', 'good.exe', 'odd.exe', 'offline.exe', 'program.exe')
        }

        It 'accepts the exit code a working shim returns' {
            Mock Invoke-ResikNativeCommand {
                New-TestRunResult -Status NonZeroExit -StdOut "generated by Chocolatey's ShimGenerator`r`n Target: 'C:\x\y.exe'`r`n"
            } -ParameterFilter { ($ArgumentList -join ' ') -ceq '--shimgen-help' }
            Get-ResikChocolateyShimTarget -Path 'C:\fake\s.exe' | Should -BeExactly 'C:\x\y.exe'
        }

        It 'does not trust other output' {
            Mock Invoke-ResikNativeCommand { New-TestRunResult -StdOut " Target: 'C:\x\y.exe'" } -ParameterFilter {
                ($ArgumentList -join ' ') -ceq '--shimgen-help'
            }
            Get-ResikChocolateyShimTarget -Path 'C:\fake\s.exe' | Should -BeNullOrEmpty
        }
    }

    Context 'Test-ResikChocolateyShim' {
        It 'does not take an ordinary program for a shim' {
            Test-ResikChocolateyShim -Path (Join-Path ([Environment]::SystemDirectory) 'whoami.exe') | Should -BeFalse
        }
    }

    Context 'choco-installers' {
        BeforeEach {
            $script:tools = Join-Path $script:root 'lib\foo\tools'
            New-TestFile -Path (Join-Path $script:tools 'foo_x64.msi') -Size 900
            New-TestText -Path (Join-Path $script:tools 'chocolateyInstall.ps1') -Text "# old.zip`n`$f = Join-Path `$toolsDir 'foo_x64.msi'`nInstall-ChocolateyInstallPackage -File `$f"
        }

        It 'deletes the installer the install script used, and nothing else' {
            foreach ($kept in 'old.zip', 'other.msi', 'foo.exe', 'foo.msi.txt', 'LICENSE.txt', 'app\foo_x64.msi') {
                New-TestFile -Path (Join-Path $script:tools $kept)
            }
            $target = New-ResikChocolateyInstallerTarget
            (Invoke-ResikTargetAnalysis -Target $target).EstimatedBytes | Should -Be 900
            (Invoke-ResikTargetCleanup -Target $target).Status | Should -BeExactly 'Success'
            Join-Path $script:tools 'foo_x64.msi' | Should -Not -Exist
            foreach ($kept in 'old.zip', 'other.msi', 'foo.exe', 'foo.msi.txt', 'LICENSE.txt', 'app\foo_x64.msi', 'chocolateyInstall.ps1') {
                Join-Path $script:tools $kept | Should -Exist
            }
        }

        It 'keeps it when another script mentions that kind of file' {
            New-TestText -Path (Join-Path $script:tools 'chocolateyUninstall.ps1') -Text 'msiexec /x (Get-Item "$toolsDir\*.msi")'
            (Invoke-ResikTargetAnalysis -Target (New-ResikChocolateyInstallerTarget)).EstimatedBytes | Should -Be 0
        }

        It 'keeps it when <Marker> exists' -ForEach @(
            @{ Marker = '.SkipReducer' }, @{ Marker = 'tools\.SkipReducer' }, @{ Marker = '.chocolateyPending' }
        ) {
            New-TestFile -Path (Join-Path $script:root "lib\foo\$Marker") -Size 1
            (Invoke-ResikTargetAnalysis -Target (New-ResikChocolateyInstallerTarget)).EstimatedBytes | Should -Be 0
        }

        It 'keeps files of a package that does not use an install helper' {
            New-TestText -Path (Join-Path $script:tools 'chocolateyInstall.ps1') -Text "Copy-Item 'foo_x64.msi' C:\x"
            (Invoke-ResikTargetAnalysis -Target (New-ResikChocolateyInstallerTarget)).EstimatedBytes | Should -Be 0
        }

        It 'never looks in Chocolatey itself' {
            New-TestFile -Path (Join-Path $script:root 'lib\chocolatey\tools\a.zip')
            New-TestText -Path (Join-Path $script:root 'lib\chocolatey\tools\chocolateyInstall.ps1') -Text 'Get-ChocolateyUnzip a.zip'
            (Invoke-ResikTargetAnalysis -Target (New-ResikChocolateyInstallerTarget)).EstimatedBytes | Should -Be 900
        }
    }

    It 'refuses a file set outside the root' {
        $set = Get-ResikChocolateyFileSet -Content @($script:temp)
        { Invoke-ResikChocolateyFileDeletion -Set $set -Root $script:root -Label 'x' } | Should -Throw '*not a real folder in*'
        $set = Get-ResikChocolateyFileSet -File @((Join-Path $script:temp 'a.txt'))
        { Invoke-ResikChocolateyFileDeletion -Set $set -Root $script:root -Label 'x' } | Should -Throw '*not in a real folder in*'
    }
}

Describe 'nuget-legacy target' {
    BeforeEach {
        $script:local = Join-Path $TestDrive ('local-' + [guid]::NewGuid().ToString('N'))
        Mock Write-Host {}
        Mock Get-ResikLocalAppDataPath { $script:local }
    }

    It 'is not detected without the folder' {
        (Invoke-ResikTargetAnalysis -Target (New-ResikNuGetLegacyTarget)).Message | Should -BeLike 'Not detected:*'
    }

    It 'deletes only the packages in the folder' {
        $cache = Join-Path $script:local 'NuGet\Cache'
        New-TestFile -Path (Join-Path $cache 'a.1.0.nupkg') -Size 600
        New-TestFile -Path (Join-Path $cache 'readme.txt')
        New-TestFile -Path (Join-Path $script:local 'NuGet\v3-cache\b.nupkg')
        (Get-Item -LiteralPath (Join-Path $cache 'a.1.0.nupkg')).LastWriteTime = (Get-Date).AddDays(-1)
        (Get-Item -LiteralPath (Join-Path $cache 'a.1.0.nupkg')).CreationTime = (Get-Date).AddDays(-1)
        $target = New-ResikNuGetLegacyTarget
        (Invoke-ResikTargetAnalysis -Target $target).EstimatedBytes | Should -Be 600
        $result = Invoke-ResikTargetCleanup -Target $target
        $result.Status | Should -BeExactly 'Success'
        $result.MeasuredBytes | Should -Be 600
        Join-Path $cache 'readme.txt' | Should -Exist
        Join-Path $script:local 'NuGet\v3-cache\b.nupkg' | Should -Exist
    }
}
