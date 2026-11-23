function Get-AzureAdJoinedValue {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $null
    }

    $found = [regex]::Matches($Text, '(?im)^\s*AzureAdJoined\s*:\s*(YES|NO)\s*$')
    if ($found.Count -eq 0) {
        return $null
    }

    $unique = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($match in $found) {
        [void]$unique.Add($match.Groups[1].Value.ToUpperInvariant())
    }

    if ($unique.Count -ne 1) {
        return $null
    }

    foreach ($item in $unique) {
        return $item
    }
}

function Get-DetectionResult {
    param(
        [string]$Value,
        [string]$FailureReason
    )

    if (-not [string]::IsNullOrEmpty($FailureReason)) {
        return [pscustomobject]@{
            ExitCode = 1
            Message  = $FailureReason
        }
    }

    if ($Value -eq 'NO') {
        return [pscustomobject]@{
            ExitCode = 0
            Message  = 'AzureAdJoined=NO'
        }
    }

    if ($Value -eq 'YES') {
        return [pscustomobject]@{
            ExitCode = 0
            Message  = ''
        }
    }

    return [pscustomobject]@{
        ExitCode = 1
        Message  = 'AzureAdJoined value not found'
    }
}

function Resolve-DsregcmdPath {
    param(
        [string]$SystemRoot = $env:SystemRoot,
        [bool]$Is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem,
        [bool]$Is64BitProcess = [Environment]::Is64BitProcess
    )

    if ($Is64BitOperatingSystem -and -not $Is64BitProcess) {
        return (Join-Path $SystemRoot 'sysnative\dsregcmd.exe')
    }

    return (Join-Path $SystemRoot 'System32\dsregcmd.exe')
}

function Invoke-AzureAdJoinedDetection {
    param(
        [string]$DsregcmdPath = (Resolve-DsregcmdPath),
        [int]$TimeoutMilliseconds = 30000,
        [string]$Arguments = '/status'
    )

    if (-not (Test-Path -LiteralPath $DsregcmdPath -PathType Leaf)) {
        return (Get-DetectionResult -FailureReason 'dsregcmd.exe not found')
    }

    $process = New-Object System.Diagnostics.Process
    try {
        $process.StartInfo.FileName = $DsregcmdPath
        $process.StartInfo.Arguments = $Arguments
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true

        $started = $false
        try {
            $started = $process.Start()
        }
        catch {
            return (Get-DetectionResult -FailureReason 'dsregcmd.exe failed to start')
        }

        if (-not $started) {
            return (Get-DetectionResult -FailureReason 'dsregcmd.exe failed to start')
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill() } catch { }
            try { $process.WaitForExit() } catch { }
            try { $null = $stdoutTask.Result } catch { }
            try { $null = $stderrTask.Result } catch { }
            return (Get-DetectionResult -FailureReason 'dsregcmd.exe timed out')
        }

        # WaitForExit(int) can return before async redirected reads finish.
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $null = $stderrTask.Result

        $value = Get-AzureAdJoinedValue -Text $stdout
        if (-not [string]::IsNullOrEmpty($value)) {
            return (Get-DetectionResult -Value $value)
        }

        return (Get-DetectionResult)
    }
    finally {
        $process.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-AzureAdJoinedDetection
        if (-not [string]::IsNullOrEmpty($result.Message)) {
            Write-Host $result.Message
        }
        exit $result.ExitCode
    }
    catch {
        Write-Host 'detection script failed'
        exit 1
    }
}
