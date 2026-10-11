# Maven local repository target (analysis only)
# (https://maven.apache.org/settings.html).
#
# Maven has no command that cleans the whole local repository
# (dependency:purge-local-repository works on one project at a time), and the
# repository holds artifacts that offline builds and locally installed
# projects depend on. Resik therefore only reports its size, and never
# deletes it.
#
# The repository is <localRepository> in %USERPROFILE%\.m2\settings.xml, else
# %USERPROFILE%\.m2\repository. ${user.home} and ${env.NAME} in the setting
# are expanded; other expressions are reported as unsupported. A
# localRepository set only in the Maven installation's conf\settings.xml or
# with -Dmaven.repo.local is not detected.

function Get-ResikMavenRepository {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # A parameter so tests can use their own folder.
        [string] $UserHome = $env:USERPROFILE
    )

    $path = Join-Path $UserHome '.m2\repository'
    $settingsFile = Join-Path $UserHome '.m2\settings.xml'
    if (Test-Path -LiteralPath $settingsFile -PathType Leaf) {
        try {
            $settings = New-Object System.Xml.XmlDocument
            $settings.XmlResolver = $null
            $settings.Load($settingsFile)
        }
        catch {
            throw "Could not read ${settingsFile}: $($_.Exception.Message)"
        }
        $node = $settings.SelectSingleNode("/*[local-name()='settings']/*[local-name()='localRepository']")
        if ($null -ne $node -and $node.InnerText.Trim()) {
            $configured = $node.InnerText.Trim()
            $configured = $configured.Replace('${user.home}', $UserHome)
            $configured = [regex]::Replace($configured, '\$\{env\.([A-Za-z0-9_]+)\}', {
                    param($match)
                    [string][Environment]::GetEnvironmentVariable($match.Groups[1].Value)
                })
            if ($configured.Contains('${')) {
                throw "The localRepository setting in $settingsFile uses an expression Resik does not expand: $configured"
            }
            $path = $configured.Replace('/', '\')
        }
    }

    $path = $path.TrimEnd('\')
    $issue = Get-ResikPathSafetyIssue -Path $path
    if ($issue) { throw "Not measuring the Maven repository: $issue" }
    [System.IO.Path]::GetFullPath($path)
}

function Invoke-ResikMavenDetection {
    $repository = Get-ResikMavenRepository
    if (-not (Test-Path -LiteralPath $repository -PathType Container)) {
        return [pscustomobject]@{ Available = $false; Details = "No Maven local repository at $repository" }
    }
    [pscustomobject]@{ Available = $true; Details = $repository }
}

function Invoke-ResikMavenAnalysis {
    $repository = Get-ResikMavenRepository
    $size = Measure-ResikDirectory -Path $repository
    $details = "$repository ($($size.Files) files). Maven has no command to clean it; Resik does not clean it."
    if ($size.Unreadable -gt 0) { $details += " $($size.Unreadable) folder(s) could not be read." }
    [pscustomobject]@{ EstimatedBytes = $size.Bytes; Details = $details }
}

function New-ResikMavenTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'maven' -Name 'Maven local repository' -Category Developer -RiskLevel Medium `
        -Description ('Analysis only: reports the size of the Maven local repository. It holds the dependencies ' +
            'of your projects and artifacts you installed locally, and Maven has no command to clean it, so ' +
            'Resik does not delete anything here.') `
        -Detect { Invoke-ResikMavenDetection } `
        -Analyze { Invoke-ResikMavenAnalysis }
}
