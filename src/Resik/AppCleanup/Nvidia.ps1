# NVIDIA shader cache target (nvidia-shaders).
#
# The NVIDIA driver stores compiled DirectX and OpenGL shaders in
#   %LOCALAPPDATA%\NVIDIA\DXCache and GLCache
#   %USERPROFILE%\AppData\LocalLow\NVIDIA\DXCache, and
#   LocalLow\NVIDIA\PerDriverVersion\DXCache and GLCache
# and rebuilds them as games and apps run (the first runs may stutter a little).
# The driver has no command for this, so Resik empties the folders itself.
# Files that a running game or app has open are skipped and reported, like
# directx-shaders; no app is closed, because any program using the GPU can hold
# them.

function Get-ResikNvidiaShaderLocation {
    # Pairs of the folder and the NVIDIA folder it must stay inside.
    [CmdletBinding()]
    param()
    $local = Join-Path (Get-ResikLocalAppDataPath) 'NVIDIA'
    $low = Join-Path (Get-ResikLocalLowPath) 'NVIDIA'
    foreach ($pair in @(
            @($local, 'DXCache'), @($local, 'GLCache'), @($low, 'DXCache'),
            @($low, 'PerDriverVersion\DXCache'), @($low, 'PerDriverVersion\GLCache'))) {
        [pscustomobject]@{ Base = $pair[0]; Path = Join-Path $pair[0] $pair[1] }
    }
}

function Get-ResikNvidiaShaderFolder {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    foreach ($location in @(Get-ResikNvidiaShaderLocation)) {
        if (-not (Test-Path -LiteralPath $location.Base -PathType Container)) { continue }
        $base = Get-ResikCheckedAppRoot -Root $location.Base -AppName 'NVIDIA'
        Get-ResikExistingFolder -Path @($location.Path) -Base $base
    }
}

function Invoke-ResikNvidiaShaderDetection {
    $folders = @(Get-ResikNvidiaShaderFolder)
    if ($folders.Count -eq 0) {
        return [pscustomobject]@{ Available = $false; Details = 'No NVIDIA shader cache folders.' }
    }
    [pscustomobject]@{ Available = $true; Details = $folders -join ', ' }
}

function New-ResikNvidiaShaderTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory object only.')]
    [CmdletBinding()]
    param()

    New-ResikTarget -Id 'nvidia-shaders' -Name 'NVIDIA shader cache' -Category Windows -RiskLevel Low `
        -Description ('Deletes the shaders the NVIDIA driver compiled for games and apps (DXCache and GLCache in ' +
            '%LOCALAPPDATA%\NVIDIA and AppData\LocalLow\NVIDIA). The driver rebuilds them; games may stutter ' +
            'briefly the first time. Files in use by running programs are skipped.') `
        -Detect { Invoke-ResikNvidiaShaderDetection } `
        -Analyze { Invoke-ResikAppFolderAnalysis -Path @(Get-ResikNvidiaShaderFolder) -Where 'the NVIDIA shader cache' } `
        -Clean {
            Invoke-ResikAppFolderCleanup -Path @(Get-ResikNvidiaShaderFolder) -Where 'the NVIDIA shader cache' `
                -Label 'the NVIDIA shader cache'
        }
}
