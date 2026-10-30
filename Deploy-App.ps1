param(
    [string]$ComputerList
)

$script:DeployLogWriter = $null
$script:DeployInstallLimit = [timespan]::FromMinutes(15)

function Get-DeploySeparator {
    return ('=' * 60)
}

function Get-DeployRemoteTargetPath {
    param([Parameter(Mandatory)][string]$FolderName)
    return ('C:\Temp\' + $FolderName)
}

function Get-DeployRemoteTargetUnc {
    param(
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][string]$FolderName
    )
    return ('\\' + $Hostname + '\C$\Temp\' + $FolderName)
}

function Get-DeployLogColor {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )
    switch ($Kind) {
        'Separator'  { return [ConsoleColor]::White }
        'Title'      { return [ConsoleColor]::White }
        'HostBanner' { return [ConsoleColor]::White }
        'Meta'       { return [ConsoleColor]::Gray }
        'Stage' {
            if ($Text.Contains('FAILED')) { return [ConsoleColor]::Red }
            if ($Text.Contains('TIMEOUT')) { return [ConsoleColor]::Yellow }
            if ($Text.Contains('OK')) { return [ConsoleColor]::Green }
            return [ConsoleColor]::Gray
        }
        default { return [ConsoleColor]::Gray }
    }
}

function Get-DeployOutcomeFromReason {
    param([Parameter(Mandatory)][string]$Reason)
    if ($Reason -eq 'OK') { return 'OK' }
    if ($Reason -eq 'TIMEOUT (still running)') { return 'TIMEOUT' }
    return 'FAILED'
}

function New-DeployHostResult {
    param(
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][string]$Reason,
        [bool]$PayloadFolderCreated = $false,
        [bool]$CleanupFailed = $false,
        [int]$CopyFiles = 0,
        [long]$CopyBytes = 0
    )
    return [pscustomobject]@{
        Hostname             = $Hostname
        Outcome              = Get-DeployOutcomeFromReason -Reason $Reason
        Reason               = $Reason
        PayloadFolderCreated = [bool]$PayloadFolderCreated
        CleanupFailed        = [bool]$CleanupFailed
        CopyFiles            = $CopyFiles
        CopyBytes            = $CopyBytes
    }
}

function New-DeployLogPath {
    param(
        [Parameter(Mandatory)][string]$LogsDirectory,
        [Parameter(Mandatory)][datetime]$Stamp
    )
    $stampText = $Stamp.ToString('yyyyMMdd-HHmmss')
    $candidate = Join-Path $LogsDirectory ('deploy-' + $stampText + '.log')
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    $i = 2
    while ($true) {
        $candidate = Join-Path $LogsDirectory ('deploy-' + $stampText + '-' + $i + '.log')
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
        $i++
    }
}

function Initialize-DeployLogger {
    param(
        [Parameter(Mandatory)][string]$LogsDirectory,
        [Parameter(Mandatory)][datetime]$Stamp
    )
    if (-not (Test-Path -LiteralPath $LogsDirectory)) {
        New-Item -ItemType Directory -Path $LogsDirectory | Out-Null
    }
    $path = New-DeployLogPath -LogsDirectory $LogsDirectory -Stamp $Stamp
    $script:DeployLogWriter = New-Object System.IO.StreamWriter($path, $false)
    $script:DeployLogWriter.AutoFlush = $true
}

function Close-DeployLogger {
    if ($null -ne $script:DeployLogWriter) {
        $script:DeployLogWriter.Close()
        $script:DeployLogWriter = $null
    }
}

function Write-DeployLine {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Kind
    )
    $color = Get-DeployLogColor -Kind $Kind -Text $Text
    Write-Host $Text -ForegroundColor $color
    if ($null -ne $script:DeployLogWriter) {
        $prefix = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $script:DeployLogWriter.WriteLine($prefix + ' ' + $Text)
    }
}

function Get-DeployHeaderLines {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$TargetPath,
        [Parameter(Mandatory)][int]$HostCount,
        [Parameter(Mandatory)][string]$ListPath
    )
    $sep = Get-DeploySeparator
    return @(
        $sep,
        ' Remote install deployer',
        (' Source : ' + $SourcePath),
        (' Target : ' + $TargetPath),
        (' Hosts  : ' + $HostCount + ' (from ' + $ListPath + ')'),
        ' Timeout: 15 minutes (install is not killed on timeout)',
        $sep
    )
}

function Write-DeployHeader {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$FolderName,
        [Parameter(Mandatory)][int]$HostCount,
        [Parameter(Mandatory)][string]$ListPath
    )
    $target = Get-DeployRemoteTargetPath -FolderName $FolderName
    $lines = Get-DeployHeaderLines -SourcePath $SourcePath -TargetPath $target -HostCount $HostCount -ListPath $ListPath
    Write-DeployLine -Kind 'Separator' -Text $lines[0]
    Write-DeployLine -Kind 'Title' -Text $lines[1]
    Write-DeployLine -Kind 'Meta' -Text $lines[2]
    Write-DeployLine -Kind 'Meta' -Text $lines[3]
    Write-DeployLine -Kind 'Meta' -Text $lines[4]
    Write-DeployLine -Kind 'Meta' -Text $lines[5]
    Write-DeployLine -Kind 'Separator' -Text $lines[6]
}

function Get-DeployStageLines {
    param(
        [Parameter(Mandatory)][string]$Reason,
        [bool]$PayloadFolderCreated = $false,
        [bool]$CleanupFailed = $false,
        [int]$CopyFiles = 0,
        [long]$CopyBytes = 0
    )
    $copyStart = '  Copy ... start'
    $copyComplete = '  Copy ... complete: ' + $CopyFiles + ' files, ' + $CopyBytes + ' bytes'
    $copyFail = '  Copy ... FAILED (copy)'
    $installSkip = '  Install ... skipped'
    $cleanupNothing = '  Cleanup ... skipped (nothing created)'
    $cleanupDeleted = '  Cleanup ... deleted'
    $cleanupFail = '  Cleanup ... cleanup failed'
    $cleanupRunning = '  Cleanup ... skipped (still running)'
    $cleanupDone = $cleanupDeleted
    if ($CleanupFailed) { $cleanupDone = $cleanupFail }

    if ($Reason -eq 'FAILED (unreachable)') {
        return [pscustomobject]@{
            Copy    = @('  Copy ... FAILED (unreachable)')
            Install = @($installSkip)
            Cleanup = @($cleanupNothing)
        }
    }
    if ($Reason -eq 'FAILED (copy)') {
        $cu = @($cleanupNothing)
        if ($PayloadFolderCreated) { $cu = @($cleanupDone) }
        return [pscustomobject]@{
            Copy    = @($copyStart, $copyFail)
            Install = @($installSkip)
            Cleanup = $cu
        }
    }
    if ($Reason -eq 'FAILED (start)') {
        return [pscustomobject]@{
            Copy    = @($copyStart, $copyComplete)
            Install = @('  Install ... FAILED (start)')
            Cleanup = @($cleanupDone)
        }
    }
    if ($Reason -eq 'TIMEOUT (still running)') {
        return [pscustomobject]@{
            Copy    = @($copyStart, $copyComplete)
            Install = @('  Install ... waiting', '  Install ... TIMEOUT (still running)')
            Cleanup = @($cleanupRunning)
        }
    }
    return [pscustomobject]@{
        Copy    = @($copyStart, $copyComplete)
        Install = @('  Install ... waiting', ('  Install ... ' + $Reason))
        Cleanup = @($cleanupDone)
    }
}

function Get-DeploySummaryLines {
    param([object[]]$Results)
    if ($null -eq $Results) { $Results = @() }
    $ok = @($Results | Where-Object { $_.Outcome -eq 'OK' }).Count
    $failed = @($Results | Where-Object { $_.Outcome -eq 'FAILED' }).Count
    $timeout = @($Results | Where-Object { $_.Outcome -eq 'TIMEOUT' }).Count
    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add((Get-DeploySeparator))
    [void]$lines.Add('OK      : ' + $ok)
    [void]$lines.Add('FAILED  : ' + $failed)
    [void]$lines.Add('TIMEOUT : ' + $timeout)
    $failedItems = @($Results | Where-Object { $_.Outcome -eq 'FAILED' })
    if ($failedItems.Count -gt 0) {
        [void]$lines.Add('FAILED:')
        foreach ($item in $failedItems) {
            $reason = $item.Reason
            if ($item.CleanupFailed) { $reason = $reason + ', cleanup failed' }
            [void]$lines.Add('  ' + $item.Hostname + ' - ' + $reason)
        }
    }
    $timeoutItems = @($Results | Where-Object { $_.Outcome -eq 'TIMEOUT' })
    if ($timeoutItems.Count -gt 0) {
        [void]$lines.Add('TIMEOUT:')
        foreach ($item in $timeoutItems) {
            [void]$lines.Add('  ' + $item.Hostname + ' - TIMEOUT (still running)')
        }
    }
    $leftover = @($Results | Where-Object { $_.Outcome -eq 'OK' -and $_.CleanupFailed })
    if ($leftover.Count -gt 0) {
        [void]$lines.Add('Leftover (OK, cleanup failed):')
        foreach ($item in $leftover) {
            [void]$lines.Add('  ' + $item.Hostname)
        }
    }
    return $lines.ToArray()
}

function Get-DeploySummaryLineKind {
    param(
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line
    )
    if ($Index -eq 0) { return 'Separator' }
    if ($Line.StartsWith('  ') -and ($Line.Contains('FAILED') -or $Line.Contains('TIMEOUT'))) {
        return 'Stage'
    }
    return 'Meta'
}

function Write-DeploySummary {
    param([object[]]$Results)
    $lines = Get-DeploySummaryLines -Results $Results
    $i = 0
    foreach ($line in $lines) {
        $kind = Get-DeploySummaryLineKind -Index $i -Line $line
        Write-DeployLine -Kind $kind -Text $line
        $i++
    }
}

function ConvertFrom-DeployHostList {
    param([string[]]$Lines)
    $result = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Lines) { return @() }
    foreach ($line in $Lines) {
        if ($null -eq $line) { continue }
        $t = $line.Trim()
        if ($t.Length -eq 0) { continue }
        if ($t.StartsWith('#')) { continue }
        [void]$result.Add($t)
    }
    return $result.ToArray()
}

function Test-DeployRobocopyAvailable {
    return [bool](Get-Command -Name 'robocopy.exe' -ErrorAction SilentlyContinue)
}

function Get-DeployComputerListPath {
    param([string]$ComputerList)
    $raw = $ComputerList
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $raw = Read-Host 'Computer list file path:'
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $raw = $raw.Trim()
    if (-not [System.IO.Path]::IsPathRooted($raw)) {
        $raw = Join-Path (Get-Location).Path $raw
    }
    return [System.IO.Path]::GetFullPath($raw)
}

function Invoke-DeployLocalValidation {
    param(
        [string]$ComputerList,
        [string]$ScriptRoot
    )
    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
        Write-Host 'ERROR: script must live in a named folder, not a drive root.'
        return [pscustomobject]@{ ExitCode = 1 }
    }
    $sourcePath = $ScriptRoot.TrimEnd('\', '/')
    $folderName = [System.IO.Path]::GetFileName($sourcePath)
    if ($sourcePath -match '^[A-Za-z]:$') { $folderName = '' }
    if ([string]::IsNullOrWhiteSpace($folderName)) {
        Write-Host 'ERROR: script must live in a named folder, not a drive root.'
        return [pscustomobject]@{ ExitCode = 1 }
    }
    $bat = Join-Path $sourcePath 'install.bat'
    if (-not (Test-Path -LiteralPath $bat -PathType Leaf)) {
        Write-Host ('ERROR: install.bat not found in ' + $sourcePath + '. Nothing was deployed.')
        return [pscustomobject]@{ ExitCode = 1 }
    }
    if (-not (Test-DeployRobocopyAvailable)) {
        Write-Host 'ERROR: robocopy.exe not found in PATH. Nothing was deployed.'
        return [pscustomobject]@{ ExitCode = 1 }
    }
    $listPath = Get-DeployComputerListPath -ComputerList $ComputerList
    if ([string]::IsNullOrWhiteSpace($listPath)) {
        Write-Host 'ERROR: computer list file path was not provided.'
        return [pscustomobject]@{ ExitCode = 1 }
    }
    if (-not (Test-Path -LiteralPath $listPath -PathType Leaf)) {
        Write-Host ('ERROR: computer list file not found: ' + $listPath + '.')
        return [pscustomobject]@{ ExitCode = 1 }
    }
    $lines = Get-Content -LiteralPath $listPath -Encoding utf8
    $hosts = @(ConvertFrom-DeployHostList -Lines $lines)
    if ($hosts.Count -eq 0) {
        Write-Host ('ERROR: computer list contains no hostnames: ' + $listPath + '.')
        return [pscustomobject]@{ ExitCode = 1 }
    }
    return [pscustomobject]@{
        ExitCode   = 0
        SourcePath = $sourcePath
        FolderName = $folderName
        ListPath   = $listPath
        Hosts      = $hosts
    }
}

function Invoke-DeployMain {
    param(
        [string]$ComputerList,
        [string]$ScriptRoot
    )
    if ([string]::IsNullOrWhiteSpace($ScriptRoot)) {
        $ScriptRoot = $PSScriptRoot
    }
    $validation = Invoke-DeployLocalValidation -ComputerList $ComputerList -ScriptRoot $ScriptRoot
    if ($validation.ExitCode -ne 0) { return 1 }
    $stamp = Get-Date
    try {
        $logsDir = Join-Path $validation.SourcePath 'logs'
        Initialize-DeployLogger -LogsDirectory $logsDir -Stamp $stamp
        Write-DeployHeader -SourcePath $validation.SourcePath -FolderName $validation.FolderName -HostCount @($validation.Hosts).Count -ListPath $validation.ListPath
        $results = New-Object System.Collections.Generic.List[object]
        $n = 0
        $total = @($validation.Hosts).Count
        foreach ($h in $validation.Hosts) {
            $n++
            $r = Invoke-DeployHost -Hostname $h -Index $n -Total $total -SourcePath $validation.SourcePath -FolderName $validation.FolderName -ListPath $validation.ListPath
            [void]$results.Add($r)
        }
        Write-DeploySummary -Results $results.ToArray()
        return 0
    }
    finally {
        Close-DeployLogger
    }
}

function Test-DeployTcpPort {
    param(
        [Parameter(Mandatory)][string]$Hostname,
        [int]$Port = 5985,
        [int]$TimeoutMs = 15000
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $client = $null
    try {
        $dnsAr = [System.Net.Dns]::BeginGetHostAddresses($Hostname, $null, $null)
        if (-not $dnsAr.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $resolved = [System.Net.Dns]::EndGetHostAddresses($dnsAr)
        if ($null -eq $resolved) { return $false }
        $addrs = @($resolved)
        if ($addrs.Count -lt 1 -or $null -eq $addrs[0]) { return $false }
        $ip = [System.Net.IPAddress]$addrs[0]
        $remaining = $TimeoutMs - [int]$sw.ElapsedMilliseconds
        if ($remaining -lt 1) { $remaining = 1 }
        $client = New-Object System.Net.Sockets.TcpClient($ip.AddressFamily)
        $ar = $client.BeginConnect($ip, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($remaining, $false)) { return $false }
        $client.EndConnect($ar)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $client) { $client.Close() }
    }
}

function Wait-DeployChildProcess {
    param(
        [Parameter(Mandatory)][string]$Command,
        [int]$TimeoutMs = 15000
    )
    $exe = (Get-Process -Id $PID).Path
    $quote = [string][char]34
    $tick = [string][char]96
    $escaped = $Command.Replace($quote, ($tick + $quote))
    $arg = '-NoProfile -NonInteractive -Command ' + $quote + $escaped + $quote
    $sp = @{
        FilePath = $exe
        ArgumentList = $arg
        PassThru = $true
    }
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $sp['WindowStyle'] = 'Hidden'
    }
    $proc = $null
    try {
        $proc = Start-Process @sp
        $exited = $proc.WaitForExit($TimeoutMs)
        if (-not $exited) {
            try { $proc.Kill() } catch { }
            return $false
        }
        return ($proc.ExitCode -eq 0)
    }
    catch {
        if ($null -ne $proc) {
            try {
                if (-not $proc.HasExited) { $proc.Kill() }
            }
            catch { }
        }
        return $false
    }
    finally {
        if ($null -ne $proc) {
            try { $proc.Dispose() } catch { }
        }
    }
}

function Test-DeployAdminShare {
    param(
        [Parameter(Mandatory)][string]$Hostname,
        [int]$TimeoutMs = 15000
    )
    $unc = '\\' + $Hostname + '\C$\'
    $safe = $unc.Replace("'", "''")
    $command = "try { if (Test-Path -LiteralPath '$safe') { exit 0 } else { exit 1 } } catch { exit 1 }"
    try {
        return [bool](Wait-DeployChildProcess -Command $command -TimeoutMs $TimeoutMs)
    }
    catch {
        return $false
    }
}

function Test-DeployHostReachable {
    param([Parameter(Mandatory)][string]$Hostname)
    try {
        if (-not (Test-DeployTcpPort -Hostname $Hostname -Port 5985 -TimeoutMs 15000)) {
            return $false
        }
    }
    catch {
        return $false
    }
    try {
        if (-not (Test-DeployAdminShare -Hostname $Hostname -TimeoutMs 15000)) {
            return $false
        }
    }
    catch {
        return $false
    }
    return $true
}

function Test-DeployListInsideSource {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$ListPath
    )
    $src = [System.IO.Path]::GetFullPath($SourcePath).TrimEnd('\', '/').ToLowerInvariant()
    $list = [System.IO.Path]::GetFullPath($ListPath).ToLowerInvariant()
    $prefix = $src + [IO.Path]::DirectorySeparatorChar
    $alt = $src + '/'
    return $list.StartsWith($prefix) -or $list.StartsWith($alt) -or $list.StartsWith(($src + '\').ToLowerInvariant())
}

function Get-DeployRobocopyArgumentList {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationUnc,
        [Parameter(Mandatory)][string]$ListPath
    )
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($SourcePath, $DestinationUnc, '/E', '/R:2', '/W:3', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/NC', '/NS', '/XF', 'Deploy-App.ps1')) {
        [void]$list.Add($item)
    }
    if (Test-DeployListInsideSource -SourcePath $SourcePath -ListPath $ListPath) {
        [void]$list.Add([System.IO.Path]::GetFileName($ListPath))
    }
    [void]$list.Add('/XD')
    [void]$list.Add('logs')
    return $list.ToArray()
}

function Test-DeployRobocopySuccess {
    param([Parameter(Mandatory)][int]$ExitCode)
    return ($ExitCode -ge 0 -and $ExitCode -le 7)
}

function Get-DeployFolderInventory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$ExcludeFileNames = @(),
        [string[]]$ExcludeDirectoryNames = @()
    )
    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $bytes = [long]0
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Files = 0; Bytes = 0; FilesList = @() }
    }
    $excludeFilesSet = @{}
    foreach ($n in $ExcludeFileNames) { $excludeFilesSet[$n.ToLowerInvariant()] = $true }
    $excludeDirsSet = @{}
    foreach ($n in $ExcludeDirectoryNames) { $excludeDirsSet[$n.ToLowerInvariant()] = $true }
    Get-ChildItem -LiteralPath $Path -Force | ForEach-Object {
        if ($_.PSIsContainer) {
            if ($excludeDirsSet.ContainsKey($_.Name.ToLowerInvariant())) { return }
            $inner = Get-DeployFolderInventory -Path $_.FullName -ExcludeFileNames $ExcludeFileNames -ExcludeDirectoryNames $ExcludeDirectoryNames
            foreach ($f in $inner.FilesList) { [void]$files.Add($f) }
            $bytes += $inner.Bytes
        }
        else {
            if ($excludeFilesSet.ContainsKey($_.Name.ToLowerInvariant())) { return }
            [void]$files.Add($_)
            $bytes += $_.Length
        }
    }
    return [pscustomobject]@{
        Files     = $files.Count
        Bytes     = $bytes
        FilesList = $files.ToArray()
    }
}

function Get-DeployCopyPercent {
    param(
        [long]$CopiedBytes,
        [long]$ExpectedBytes,
        [int]$CopiedFiles,
        [int]$ExpectedFiles
    )
    if ($ExpectedBytes -gt 0) {
        $p = [int][Math]::Floor(($CopiedBytes * 100) / $ExpectedBytes)
        if ($p -gt 100) { $p = 100 }
        return $p
    }
    if ($ExpectedFiles -gt 0) {
        $p = [int][Math]::Floor(($CopiedFiles * 100) / $ExpectedFiles)
        if ($p -gt 100) { $p = 100 }
        return $p
    }
    return 100
}

function New-DeployRemoteTemp {
    param([Parameter(Mandatory)][string]$Hostname)
    $tempUnc = '\\' + $Hostname + '\C$\Temp'
    try {
        if (-not (Test-Path -LiteralPath $tempUnc)) {
            New-Item -ItemType Directory -Path $tempUnc -ErrorAction Stop | Out-Null
        }
        return $true
    }
    catch {
        return $false
    }
}

function ConvertTo-DeployProcessArgumentString {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]]$ArgumentList
    )
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($token in $ArgumentList) {
        if ([string]::IsNullOrEmpty($token) -or $token.Contains(' ')) {
            [void]$parts.Add('"' + $token + '"')
        }
        else {
            [void]$parts.Add($token)
        }
    }
    return ($parts.ToArray() -join ' ')
}

function Start-DeployRobocopyProcess {
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    $stdout = [System.IO.Path]::GetTempFileName()
    $stderr = [System.IO.Path]::GetTempFileName()
    $argString = ConvertTo-DeployProcessArgumentString -ArgumentList $ArgumentList
    $p = Start-Process -FilePath 'robocopy.exe' -ArgumentList $argString -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    Add-Member -InputObject $p -NotePropertyName '_stdout' -NotePropertyValue $stdout
    Add-Member -InputObject $p -NotePropertyName '_stderr' -NotePropertyValue $stderr
    return $p
}

function Copy-DeployPayload {
    param(
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$FolderName,
        [Parameter(Mandatory)][string]$ListPath
    )
    $dest = Get-DeployRemoteTargetUnc -Hostname $Hostname -FolderName $FolderName
    if (-not (New-DeployRemoteTemp -Hostname $Hostname)) {
        return [pscustomobject]@{ Success = $false; PayloadFolderCreated = $false; Files = 0; Bytes = 0 }
    }
    $excludeFiles = @('Deploy-App.ps1')
    if (Test-DeployListInsideSource -SourcePath $SourcePath -ListPath $ListPath) {
        $excludeFiles += [System.IO.Path]::GetFileName($ListPath)
    }
    $expected = Get-DeployFolderInventory -Path $SourcePath -ExcludeFileNames $excludeFiles -ExcludeDirectoryNames @('logs')
    $argList = Get-DeployRobocopyArgumentList -SourcePath $SourcePath -DestinationUnc $dest -ListPath $ListPath
    $proc = $null
    try {
        $proc = Start-DeployRobocopyProcess -ArgumentList $argList
        if ($null -eq $proc) {
            return [pscustomobject]@{ Success = $false; PayloadFolderCreated = $true; Files = 0; Bytes = 0 }
        }
        while (-not $proc.HasExited) {
            $destInv = Get-DeployFolderInventory -Path $dest -ExcludeFileNames @() -ExcludeDirectoryNames @()
            $pct = Get-DeployCopyPercent -CopiedBytes $destInv.Bytes -ExpectedBytes $expected.Bytes -CopiedFiles $destInv.Files -ExpectedFiles $expected.Files
            $status = $Hostname + ' ' + $destInv.Files + '/' + $expected.Files + ' files ' + $destInv.Bytes + '/' + $expected.Bytes + ' bytes'
            Write-Progress -Activity 'Copy' -Id 1 -Status $status -PercentComplete $pct
            Start-Sleep -Milliseconds 500
        }
        $code = [int]$proc.ExitCode
        $destFinal = Get-DeployFolderInventory -Path $dest -ExcludeFileNames @() -ExcludeDirectoryNames @()
        $ok = Test-DeployRobocopySuccess -ExitCode $code
        return [pscustomobject]@{
            Success              = $ok
            PayloadFolderCreated = $true
            Files                = $destFinal.Files
            Bytes                = $destFinal.Bytes
        }
    }
    catch {
        return [pscustomobject]@{ Success = $false; PayloadFolderCreated = $true; Files = 0; Bytes = 0 }
    }
    finally {
        if ($null -ne $proc) {
            Write-Progress -Activity 'Copy' -Id 1 -Completed
            if ($proc._stdout) { Remove-Item -LiteralPath $proc._stdout -ErrorAction SilentlyContinue }
            if ($proc._stderr) { Remove-Item -LiteralPath $proc._stderr -ErrorAction SilentlyContinue }
        }
    }
}

function Get-DeployInstallCommandLine {
    return 'cmd.exe /v:on /c "cmd.exe /c install.bat & echo !ERRORLEVEL!>.deploy-exit"'
}

function ConvertFrom-DeployExitFile {
    param([AllowNull()][string]$Content)
    if ([string]::IsNullOrWhiteSpace($Content)) { return $null }
    $t = $Content.Trim()
    $n = 0
    if (-not [int]::TryParse($t, [ref]$n)) { return $null }
    return $n
}

function Get-DeployNow { return Get-Date }

function Invoke-DeploySleep {
    param([Parameter(Mandatory)][int]$Seconds)
    Start-Sleep -Seconds $Seconds
}

function Get-DeployExitFileText {
    param([Parameter(Mandatory)][string]$UncPath)
    try {
        if (-not (Test-Path -LiteralPath $UncPath -PathType Leaf)) { return $null }
        return [System.IO.File]::ReadAllText($UncPath)
    }
    catch {
        return $null
    }
}

function New-DeployCimSession {
    param([Parameter(Mandatory)][string]$Hostname)
    return New-CimSession -ComputerName $Hostname
}

function Remove-DeployCimSession {
    param($CimSession)
    if ($null -ne $CimSession) {
        Remove-CimSession -CimSession $CimSession -ErrorAction SilentlyContinue
    }
}

function Invoke-DeployCimCreate {
    param(
        [Parameter(Mandatory)]$CimSession,
        [Parameter(Mandatory)][string]$FolderName
    )
    $args = @{
        CommandLine      = Get-DeployInstallCommandLine
        CurrentDirectory = Get-DeployRemoteTargetPath -FolderName $FolderName
    }
    return Invoke-CimMethod -CimSession $CimSession -ClassName 'Win32_Process' -MethodName 'Create' -Arguments $args
}

function Start-DeployInstall {
    param(
        [Parameter(Mandatory)]$CimSession,
        [Parameter(Mandatory)][string]$FolderName
    )
    try {
        $out = Invoke-DeployCimCreate -CimSession $CimSession -FolderName $FolderName
        if ($null -eq $out) {
            return [pscustomobject]@{ Success = $false; ProcessId = 0 }
        }
        if (($out.ReturnValue -eq 0) -and ($out.ProcessId -gt 0)) {
            return [pscustomobject]@{ Success = $true; ProcessId = [int]$out.ProcessId }
        }
        return [pscustomobject]@{ Success = $false; ProcessId = 0 }
    }
    catch {
        return [pscustomobject]@{ Success = $false; ProcessId = 0 }
    }
}

function Test-DeployRemoteProcess {
    param(
        [Parameter(Mandatory)]$CimSession,
        [Parameter(Mandatory)][int]$ProcessId
    )
    $proc = Get-CimInstance -CimSession $CimSession -ClassName 'Win32_Process' -Filter ('ProcessId=' + $ProcessId) -ErrorAction Stop
    return ($null -ne $proc)
}

function Wait-DeployInstall {
    param(
        [Parameter(Mandatory)]$CimSession,
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$ExitFileUnc,
        [Parameter(Mandatory)][timespan]$Limit
    )
    $deadline = (Get-DeployNow) + $Limit
    while ($true) {
        try {
            $alive = Test-DeployRemoteProcess -CimSession $CimSession -ProcessId $ProcessId
        }
        catch {
            return 'TIMEOUT (still running)'
        }
        if (-not $alive) {
            $fileDeadline = (Get-DeployNow) + [timespan]::FromSeconds(10)
            while ($true) {
                $parsed = ConvertFrom-DeployExitFile -Content (Get-DeployExitFileText -UncPath $ExitFileUnc)
                if ($null -ne $parsed) {
                    if ($parsed -eq 0) { return 'OK' }
                    return ('FAILED (exit ' + $parsed + ')')
                }
                if ((Get-DeployNow) -ge $fileDeadline) { return 'FAILED (no exit code)' }
                Invoke-DeploySleep -Seconds 1
            }
        }
        if ((Get-DeployNow) -ge $deadline) {
            return 'TIMEOUT (still running)'
        }
        Invoke-DeploySleep -Seconds 5
    }
}

function Get-DeployCleanupDecision {
    param(
        [Parameter(Mandatory)][string]$Reason,
        [bool]$PayloadFolderCreated = $false
    )
    if ($Reason -eq 'FAILED (unreachable)') { return 'SkipNothingCreated' }
    if ($Reason -eq 'TIMEOUT (still running)') { return 'SkipStillRunning' }
    if ($Reason -eq 'FAILED (copy)' -and -not $PayloadFolderCreated) { return 'SkipNothingCreated' }
    return 'Delete'
}

function Invoke-DeployHost {
    param(
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][int]$Index,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$FolderName,
        [Parameter(Mandatory)][string]$ListPath
    )
    Write-DeployLine -Kind 'HostBanner' -Text ('[' + $Index + '/' + $Total + '] ' + $Hostname)

    if (-not (Test-DeployHostReachable -Hostname $Hostname)) {
        $result = New-DeployHostResult -Hostname $Hostname -Reason 'FAILED (unreachable)'
        $stages = Get-DeployStageLines -Reason $result.Reason
        foreach ($line in $stages.Copy) { Write-DeployLine -Kind 'Stage' -Text $line }
        foreach ($line in $stages.Install) { Write-DeployLine -Kind 'Stage' -Text $line }
        foreach ($line in $stages.Cleanup) { Write-DeployLine -Kind 'Stage' -Text $line }
        return $result
    }

    Write-DeployLine -Kind 'Stage' -Text '  Copy ... start'
    $copy = Copy-DeployPayload -Hostname $Hostname -SourcePath $SourcePath -FolderName $FolderName -ListPath $ListPath
    if (-not $copy.Success) {
        Write-DeployLine -Kind 'Stage' -Text '  Copy ... FAILED (copy)'
        $cleanupFailed = $false
        $decision = Get-DeployCleanupDecision -Reason 'FAILED (copy)' -PayloadFolderCreated $copy.PayloadFolderCreated
        if ($decision -eq 'Delete') {
            $cleanupFailed = -not (Remove-DeployPayloadFolder -Hostname $Hostname -FolderName $FolderName)
        }
        $result = New-DeployHostResult -Hostname $Hostname -Reason 'FAILED (copy)' -PayloadFolderCreated $copy.PayloadFolderCreated -CleanupFailed $cleanupFailed
        $stages = Get-DeployStageLines -Reason $result.Reason -PayloadFolderCreated $result.PayloadFolderCreated -CleanupFailed $result.CleanupFailed
        foreach ($line in $stages.Install) { Write-DeployLine -Kind 'Stage' -Text $line }
        foreach ($line in $stages.Cleanup) { Write-DeployLine -Kind 'Stage' -Text $line }
        return $result
    }

    Write-DeployLine -Kind 'Stage' -Text ('  Copy ... complete: ' + $copy.Files + ' files, ' + $copy.Bytes + ' bytes')

    $session = $null
    try {
        try {
            $session = New-DeployCimSession -Hostname $Hostname
        }
        catch { $session = $null }
        $start = $null
        if ($null -eq $session) {
            $start = [pscustomobject]@{ Success = $false; ProcessId = 0 }
        }
        else {
            $staleExit = (Get-DeployRemoteTargetUnc -Hostname $Hostname -FolderName $FolderName) + '\.deploy-exit'
            try {
                Remove-Item -LiteralPath $staleExit -ErrorAction SilentlyContinue
            }
            catch { }
            $start = Start-DeployInstall -CimSession $session -FolderName $FolderName
        }
        if (-not $start.Success) {
            $cleanupFailed = -not (Remove-DeployPayloadFolder -Hostname $Hostname -FolderName $FolderName)
            $result = New-DeployHostResult -Hostname $Hostname -Reason 'FAILED (start)' -PayloadFolderCreated:$true -CleanupFailed $cleanupFailed -CopyFiles $copy.Files -CopyBytes $copy.Bytes
            $stages = Get-DeployStageLines -Reason $result.Reason -PayloadFolderCreated:$true -CleanupFailed $result.CleanupFailed -CopyFiles $copy.Files -CopyBytes $copy.Bytes
            foreach ($line in $stages.Install) { Write-DeployLine -Kind 'Stage' -Text $line }
            foreach ($line in $stages.Cleanup) { Write-DeployLine -Kind 'Stage' -Text $line }
            return $result
        }

        Write-DeployLine -Kind 'Stage' -Text '  Install ... waiting'
        $exitUnc = (Get-DeployRemoteTargetUnc -Hostname $Hostname -FolderName $FolderName) + '\.deploy-exit'
        $reason = Wait-DeployInstall -CimSession $session -ProcessId $start.ProcessId -ExitFileUnc $exitUnc -Limit $script:DeployInstallLimit
        $result = New-DeployHostResult -Hostname $Hostname -Reason $reason -PayloadFolderCreated:$true -CopyFiles $copy.Files -CopyBytes $copy.Bytes
        Write-DeployLine -Kind 'Stage' -Text ('  Install ... ' + $reason)

        $decision = Get-DeployCleanupDecision -Reason $reason -PayloadFolderCreated:$true
        if ($decision -eq 'Delete') {
            $result.CleanupFailed = -not (Remove-DeployPayloadFolder -Hostname $Hostname -FolderName $FolderName)
        }
        $stages = Get-DeployStageLines -Reason $reason -PayloadFolderCreated:$true -CleanupFailed $result.CleanupFailed -CopyFiles $copy.Files -CopyBytes $copy.Bytes
        foreach ($line in $stages.Cleanup) { Write-DeployLine -Kind 'Stage' -Text $line }
        return $result
    }
    finally {
        Remove-DeployCimSession -CimSession $session
    }
}

function Remove-DeployPayloadFolder {
    param(
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][string]$FolderName
    )
    $unc = Get-DeployRemoteTargetUnc -Hostname $Hostname -FolderName $FolderName
    try {
        if (Test-Path -LiteralPath $unc) {
            Remove-Item -LiteralPath $unc -Recurse -Force -ErrorAction Stop
        }
        return $true
    }
    catch {
        return $false
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (Get-Command -Name Invoke-DeployMain -ErrorAction SilentlyContinue) {
        $code = Invoke-DeployMain -ComputerList $ComputerList
        exit $code
    }
}
