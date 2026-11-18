# Non-destructive analysis orchestration.
#
# Each target's Detect and Analyze scriptblocks run in isolation: a failure in
# one target produces a Failed result for that target and never stops the rest.

function Get-ResikOptionalProperty {
    # Reads a property that may be absent without tripping strict mode.
    param($InputObject, [string] $Name)
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $property.Value
}

function Invoke-ResikTargetAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Target
    )

    $ErrorActionPreference = 'Stop'
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $detection = & $Target.Detect
        if ((Get-ResikOptionalProperty $detection 'Available') -ne $true) {
            $details = Get-ResikOptionalProperty $detection 'Details'
            $message = if ($details) { "Not detected: $details" } else { 'Not detected.' }
            return New-ResikResult -TargetId $Target.Id -Operation Analyze -Status Skipped `
                -Message $message -Duration $stopwatch.Elapsed
        }

        $analysis = & $Target.Analyze
        $estimate = Get-ResikOptionalProperty $analysis 'EstimatedBytes'
        if ($null -ne $estimate) {
            $estimate = [long]$estimate
            if ($estimate -lt 0) {
                throw "Analysis returned a negative size estimate ($estimate)."
            }
        }

        New-ResikResult -TargetId $Target.Id -Operation Analyze -Status AnalysisOnly `
            -Message ([string](Get-ResikOptionalProperty $analysis 'Details')) `
            -EstimatedBytes $estimate -Duration $stopwatch.Elapsed
    }
    catch {
        New-ResikResult -TargetId $Target.Id -Operation Analyze -Status Failed `
            -Message "Analysis failed: $($_.Exception.Message)" -Duration $stopwatch.Elapsed
    }
}

function Get-ResikAnalysisWorkerScript {
    # The script a background analysis worker runs in its own runspace. It
    # loads Resik, builds the catalog, and analyzes targets by ID from the
    # shared queue until it is empty. Analysis is read-only, so a target that
    # a worker started but did not finish can safely be analyzed again.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    {
        param($SourceRoot, $Queue, $Results, $Running)
        Set-StrictMode -Version 3.0
        $ErrorActionPreference = 'Stop'
        . (Join-Path $SourceRoot 'Core\SourceFiles.ps1')
        foreach ($resikSourceFile in Get-ResikSourceFile) {
            . (Join-Path $SourceRoot $resikSourceFile)
        }
        $catalog = @{}
        foreach ($target in @(Get-ResikTargetCatalog)) { $catalog[$target.Id] = $target }

        $id = $null
        while ($Queue.TryDequeue([ref]$id)) {
            if (-not $catalog.ContainsKey($id)) {
                # Left for the main thread, which has the target itself.
                $Results[$id] = $null
                continue
            }
            $Running[$id] = $catalog[$id].Name
            try {
                $Results[$id] = Invoke-ResikTargetAnalysis -Target $catalog[$id]
            }
            finally {
                $removed = $null
                [void]$Running.TryRemove($id, [ref]$removed)
            }
        }
    }.ToString()
}

function Invoke-ResikParallelAnalysis {
    # Analyzes the targets on this thread and in background runspaces at the
    # same time; most of the time goes to starting tools and measuring
    # folders. Results are emitted in the order of Targets.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]] $Targets,

        [Parameter(Mandatory)]
        [string] $WorkerSourceRoot,

        [ValidateRange(1, 16)]
        [int] $WorkerCount = 3,

        [AllowNull()]
        [object] $Spinner = $null
    )

    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $results = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,object]'
    $running = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,string]'
    $byId = @{}
    foreach ($target in $Targets) {
        $byId[$target.Id] = $target
        $queue.Enqueue($target.Id)
    }

    $workers = New-Object System.Collections.Generic.List[object]
    try {
        $script = Get-ResikAnalysisWorkerScript
        for ($i = 0; $i -lt $WorkerCount; $i++) {
            $runspace = [runspacefactory]::CreateRunspace()
            $runspace.Open()
            $shell = [powershell]::Create()
            $shell.Runspace = $runspace
            [void]$shell.AddScript($script)
            [void]$shell.AddParameter('SourceRoot', $WorkerSourceRoot)
            [void]$shell.AddParameter('Queue', $queue)
            [void]$shell.AddParameter('Results', $results)
            [void]$shell.AddParameter('Running', $running)
            $workers.Add([pscustomobject]@{ Shell = $shell; Runspace = $runspace; Handle = $shell.BeginInvoke() })
        }

        $id = $null
        while ($queue.TryDequeue([ref]$id)) {
            Set-ResikSpinnerMessage -Spinner $Spinner -Message ("Analyzing $($byId[$id].Name) " +
                "($($results.Count + 1) of $($Targets.Count))")
            $results[$id] = Invoke-ResikTargetAnalysis -Target $byId[$id]
        }

        # Wait in short steps so that Ctrl+C can interrupt the wait.
        while (@($workers | Where-Object { -not $_.Handle.IsCompleted }).Count -gt 0) {
            $names = @($running.Values)
            if ($names.Count -gt 0) {
                Set-ResikSpinnerMessage -Spinner $Spinner -Message ("Analyzing $($names -join ', ') " +
                    "($($results.Count + 1) of $($Targets.Count))")
            }
            Start-Sleep -Milliseconds 50
        }
        foreach ($worker in $workers) {
            try {
                [void]$worker.Shell.EndInvoke($worker.Handle)
            }
            catch {
                Write-Verbose "An analysis worker failed: $($_.Exception.Message)"
            }
        }
    }
    finally {
        foreach ($worker in $workers) {
            # Stopping a worker runs its finally blocks, which stop any tool
            # it started (Invoke-ResikNativeCommand).
            if (-not $worker.Handle.IsCompleted) { $worker.Shell.Stop() }
            $worker.Shell.Dispose()
            $worker.Runspace.Dispose()
        }
    }

    $number = 0
    foreach ($target in $Targets) {
        $number++
        $result = $null
        if (-not $results.TryGetValue($target.Id, [ref]$result) -or $null -eq $result) {
            # A worker that failed to start, or a target it could not build.
            Set-ResikSpinnerMessage -Spinner $Spinner -Message "Analyzing $($target.Name) ($number of $($Targets.Count))"
            $result = Invoke-ResikTargetAnalysis -Target $target
        }
        $result
    }
}

function Invoke-ResikAnalysis {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]] $Targets = @(),

        # A running spinner (Start-ResikSpinner) that shows the current target.
        [AllowNull()]
        [object] $Spinner = $null,

        # The folder that holds Resik.ps1. When given, background workers load
        # Resik from it and analyze catalog targets by ID in parallel, so pass
        # it only for targets from Get-ResikTargetCatalog.
        [string] $WorkerSourceRoot = ''
    )

    $ids = @($Targets | ForEach-Object { [string]$_.Id })
    $canRunParallel = $WorkerSourceRoot -and $Targets.Count -ge 4 -and
        @($ids | Select-Object -Unique).Count -eq $ids.Count -and
        $ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage'
    if ($canRunParallel) {
        Invoke-ResikParallelAnalysis -Targets $Targets -WorkerSourceRoot $WorkerSourceRoot -Spinner $Spinner
        return
    }

    $number = 0
    foreach ($target in $Targets) {
        $number++
        Set-ResikSpinnerMessage -Spinner $Spinner -Message "Analyzing $($target.Name) ($number of $($Targets.Count))"
        Invoke-ResikTargetAnalysis -Target $target
    }
}
