BeforeAll {
    . (Join-Path $PSScriptRoot 'TestSetup.ps1')
}

Describe 'Analysis-only targets' {
    It '<Id> has no Clean operation, so it is never cleaned' -ForEach @(
        @{ Id = 'gradle' }
        @{ Id = 'maven' }
        @{ Id = 'jetbrains' }
    ) {
        $target = @(Get-ResikTargetCatalog) | Where-Object { $_.Id -eq $Id }
        $target.Clean | Should -BeNullOrEmpty
        (Invoke-ResikTargetCleanup -Target $target).Status | Should -BeExactly 'Unsupported'
    }
}

Describe 'gradle target' {
    BeforeEach {
        $script:savedGradleHome = $env:GRADLE_USER_HOME
        $script:gradleHome = Join-Path $TestDrive ('gradle-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $script:gradleHome 'caches\modules-2\a.jar') -Size 3000
        New-TestFile -Path (Join-Path $script:gradleHome 'wrapper\dists\gradle-8.10-bin\x.zip') -Size 2000
        New-TestFile -Path (Join-Path $script:gradleHome 'daemon\8.10\daemon.log') -Size 100
        New-TestFile -Path (Join-Path $script:gradleHome 'gradle.properties') -Size 50
        $env:GRADLE_USER_HOME = $script:gradleHome
    }

    AfterEach {
        $env:GRADLE_USER_HOME = $script:savedGradleHome
    }

    It 'defaults to %USERPROFILE%\.gradle' {
        $env:GRADLE_USER_HOME = $null
        Get-ResikGradleUserHome | Should -BeExactly (Join-Path $env:USERPROFILE '.gradle')
    }

    It 'is not detected without a Gradle user home' {
        $env:GRADLE_USER_HOME = Join-Path $TestDrive 'missing-gradle'
        (Invoke-ResikTargetAnalysis -Target (New-ResikGradleTarget)).Status | Should -BeExactly 'Skipped'
    }

    It 'reports caches, wrapper distributions, and daemon logs, but not settings' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikGradleTarget)

        $result.Status | Should -BeExactly 'AnalysisOnly'
        $result.EstimatedBytes | Should -Be 5100
        $result.Message | Should -BeLike "$script:gradleHome (caches 2.9 KB, wrapper\dists 2.0 KB, daemon 100 B). *Resik does not clean it."
    }

    It 'does not measure a protected location' {
        $env:GRADLE_USER_HOME = $env:USERPROFILE
        (Invoke-ResikTargetAnalysis -Target (New-ResikGradleTarget)).Message | Should -BeLike '*Not measuring the Gradle user home*'
    }
}

Describe 'maven target' {
    BeforeEach {
        $script:userHome = Join-Path $TestDrive ('home-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $script:userHome '.m2\repository\org\x\1.0\x-1.0.jar') -Size 1500
    }

    It 'defaults to .m2\repository' {
        Get-ResikMavenRepository -UserHome $script:userHome | Should -BeExactly (Join-Path $script:userHome '.m2\repository')
    }

    It 'reads localRepository from settings.xml with <Value>' -ForEach @(
        @{ Value = '${user.home}/custom/repo'; Expected = '{home}\custom\repo' }
        @{ Value = '${env.RESIK_TEST_M2}\repo'; Expected = '{home}\from-env\repo' }
        @{ Value = 'C:\maven-repo'; Expected = 'C:\maven-repo' }
    ) {
        $env:RESIK_TEST_M2 = Join-Path $script:userHome 'from-env'
        try {
            $settings = "<settings xmlns=`"http://maven.apache.org/SETTINGS/1.2.0`"><localRepository>$Value</localRepository></settings>"
            New-Item -ItemType Directory -Force -Path (Join-Path $script:userHome '.m2') | Out-Null
            Set-Content -LiteralPath (Join-Path $script:userHome '.m2\settings.xml') -Value $settings -Encoding UTF8
            Get-ResikMavenRepository -UserHome $script:userHome | Should -BeExactly ($Expected.Replace('{home}', $script:userHome))
        }
        finally { $env:RESIK_TEST_M2 = $null }
    }

    It 'rejects an expression it cannot expand' {
        Set-Content -LiteralPath (Join-Path $script:userHome '.m2\settings.xml') -Encoding UTF8 `
            -Value '<settings><localRepository>${repo.root}/m2</localRepository></settings>'
        { Get-ResikMavenRepository -UserHome $script:userHome } | Should -Throw '*does not expand*'
    }

    It 'measures the repository' {
        Mock Get-ResikMavenRepository { Join-Path $script:userHome '.m2\repository' }
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikMavenTarget)
        $result.Status | Should -BeExactly 'AnalysisOnly'
        $result.EstimatedBytes | Should -Be 1500
        $result.Message | Should -BeLike '*(1 files). Maven has no command to clean it; Resik does not clean it.'
    }
}

Describe 'jetbrains target' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ('JetBrains-' + [guid]::NewGuid().ToString('N'))
        New-TestFile -Path (Join-Path $script:root 'PyCharm2023.1\caches\content.dat') -Size 1000
        New-TestFile -Path (Join-Path $script:root 'PyCharm2023.1\index\stubs.dat') -Size 2000
        New-TestFile -Path (Join-Path $script:root 'PyCharm2023.1\LocalHistory\changes.dat') -Size 5000
        New-TestFile -Path (Join-Path $script:root 'IntelliJIdea2025.2\caches\x.dat') -Size 300
        New-TestFile -Path (Join-Path $script:root 'consentOptions\accepted') -Size 10
        Mock Get-ResikJetBrainsSystemRoot { $script:root }
    }

    It 'is not detected without IDE caches' {
        Mock Get-ResikJetBrainsSystemRoot { Join-Path $TestDrive 'no-jetbrains' }
        (Invoke-ResikTargetAnalysis -Target (New-ResikJetBrainsTarget)).Status | Should -BeExactly 'Skipped'
    }

    It 'reports caches and indexes per IDE, never Local History' {
        $result = Invoke-ResikTargetAnalysis -Target (New-ResikJetBrainsTarget)

        $result.Status | Should -BeExactly 'AnalysisOnly'
        $result.EstimatedBytes | Should -Be 3300
        $result.Message | Should -BeLike "$script:root (IntelliJIdea2025.2 300 B, PyCharm2023.1 2.9 KB). Use File | Invalidate Caches*"
    }
}
