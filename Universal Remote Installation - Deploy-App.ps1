<##
Deploy-App.ps1 kopiuje folder, w którym leży, na kolejne komputery z listy
i uruchamia tam install.bat. Nie czeka na koniec instalacji i nie usuwa
folderu ze stacji.

Uruchomienie:
Deploy-App.cmd
Deploy-App.cmd -ComputerList sciezka\do\listy.txt
Bez -ComputerList skrypt pyta: Computer list file path:

Dostosowanie, każdy punkt ma własny blok komentarza niżej:
- katalog docelowy C:\Temp\<nazwa-folderu>
- port 5985 i limit 15 sekund sond
- wykluczenia robocopy
- komenda instalacji
##>

param(
    [string]$ComputerList
)

function Test-DeployIsIseHost {
    param(
        [string]$HostName,
        [switch]$HasPsIse
    )
    if ($HasPsIse) { return $true }
    if ($HostName -eq 'Windows PowerShell ISE Host') { return $true }
    return $false
}

if ($MyInvocation.InvocationName -ne '.') {
    $deployHasPsIse = $false
    $deployPsIseVar = Get-Variable -Name 'psISE' -ErrorAction SilentlyContinue
    if ($null -ne $deployPsIseVar -and $null -ne $deployPsIseVar.Value) {
        $deployHasPsIse = $true
    }
    $deployHostName = ''
    if ($null -ne $Host -and $null -ne $Host.Name) {
        $deployHostName = [string]$Host.Name
    }
    if (Test-DeployIsIseHost -HostName $deployHostName -HasPsIse:$deployHasPsIse) {
        $deployIseError = 'ERROR: This script cannot run in Windows PowerShell ISE. Run Deploy-App.cmd or %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File Deploy-App.ps1'
        Write-Host $deployIseError -ForegroundColor Red
        Write-Error $deployIseError
        exit 1
    }
}

$script:DeployLogWriter = $null
$script:DeploySeparator = ('=' * 60)

<##
Katalog docelowy na stacji to C:\Temp\<nazwa tego folderu>.
Zmiana miejsca instalacji: podmień C:\Temp\ w Get-DeployRemoteTargetPath,
\C$\Temp\ w Get-DeployRemoteTargetUnc oraz tworzenie \\host\C$\Temp
w Copy-DeployPayload. Te trzy miejsca muszą wskazywać ten sam folder.
##>


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

function Initialize-DeployLogger {
    param(
        [Parameter(Mandatory)][string]$LogsDirectory,
        [Parameter(Mandatory)][datetime]$Stamp
    )
    if (-not (Test-Path -LiteralPath $LogsDirectory)) {
        New-Item -ItemType Directory -Path $LogsDirectory | Out-Null
    }
    $stampText = $Stamp.ToString('yyyyMMdd-HHmmss')
    $candidate = Join-Path $LogsDirectory ('deploy-' + $stampText + '.log')
    if (Test-Path -LiteralPath $candidate) {
        $i = 2
        do {
            $candidate = Join-Path $LogsDirectory ('deploy-' + $stampText + '-' + $i + '.log')
            $i++
        } while (Test-Path -LiteralPath $candidate)
    }
    $script:DeployLogWriter = New-Object System.IO.StreamWriter($candidate, $false)
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
    $color = [ConsoleColor]::Gray
    if ($Kind -eq 'Separator' -or $Kind -eq 'Title' -or $Kind -eq 'HostBanner') {
        $color = [ConsoleColor]::White
    }
    elseif ($Kind -eq 'Stage') {
        if ($Text.Contains('FAILED')) { $color = [ConsoleColor]::Red }
        elseif ($Text.Contains('STARTED')) { $color = [ConsoleColor]::Green }
    }
    Write-Host $Text -ForegroundColor $color
    if ($null -ne $script:DeployLogWriter) {
        $prefix = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $script:DeployLogWriter.WriteLine($prefix + ' ' + $Text)
    }
}

function Write-DeployHeader {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$FolderName,
        [Parameter(Mandatory)][int]$HostCount,
        [Parameter(Mandatory)][string]$ListPath
    )
    $target = Get-DeployRemoteTargetPath -FolderName $FolderName
    Write-DeployLine -Kind 'Separator' -Text $script:DeploySeparator
    Write-DeployLine -Kind 'Title' -Text ' Remote install deployer'
    Write-DeployLine -Kind 'Meta' -Text (' Source : ' + $SourcePath)
    Write-DeployLine -Kind 'Meta' -Text (' Target : ' + $target)
    Write-DeployLine -Kind 'Meta' -Text (' Hosts  : ' + $HostCount + ' (from ' + $ListPath + ')')
    Write-DeployLine -Kind 'Separator' -Text $script:DeploySeparator
}

function Write-DeploySummary {
    param([object[]]$Results)
    if ($null -eq $Results) { $Results = @() }
    $started = @($Results | Where-Object { $_.Outcome -eq 'STARTED' }).Count
    $failed = @($Results | Where-Object { $_.Outcome -eq 'FAILED' }).Count
    Write-DeployLine -Kind 'Separator' -Text $script:DeploySeparator
    Write-DeployLine -Kind 'Meta' -Text ('STARTED : ' + $started)
    Write-DeployLine -Kind 'Meta' -Text ('FAILED  : ' + $failed)
    $failedItems = @($Results | Where-Object { $_.Outcome -eq 'FAILED' })
    if ($failedItems.Count -gt 0) {
        Write-DeployLine -Kind 'Meta' -Text 'FAILED:'
        foreach ($item in $failedItems) {
            Write-DeployLine -Kind 'Stage' -Text ('  ' + $item.Hostname + ' - ' + $item.Reason)
        }
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

<##
Sonda hosta: najpierw TCP 5985, czas 15000 ms razem z DNS, tylko pierwszy adres.
Potem udział \\<host>\C$\ osobnym procesem, limit 15000 ms.
Inny port lub inny limit: zmień wartości w Test-DeployTcpPort, Test-DeployAdminShare
i w wywołaniu z Test-DeployHostReachable.
##>

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

<##
Robocopy kopiuje drzewo (/E), powtarza dwa razy co 3 sekundy i nie wypisuje listy plików.
Wykluczenia robocopy: plik Deploy-App.ps1, katalog logs oraz plik listy hostów,
gdy leży wewnątrz źródła. Kolejne wykluczenie dopisz przy /XF albo /XD.
##>

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

function Copy-DeployPayload {
    param(
        [Parameter(Mandatory)][string]$Hostname,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$FolderName,
        [Parameter(Mandatory)][string]$ListPath
    )
    $dest = Get-DeployRemoteTargetUnc -Hostname $Hostname -FolderName $FolderName
    $tempUnc = '\\' + $Hostname + '\C$\Temp'
    try {
        if (-not (Test-Path -LiteralPath $tempUnc)) {
            New-Item -ItemType Directory -Path $tempUnc -ErrorAction Stop | Out-Null
        }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Files = 0; Bytes = 0 }
    }

    $excludeFiles = @('Deploy-App.ps1')
    if (Test-DeployListInsideSource -SourcePath $SourcePath -ListPath $ListPath) {
        $excludeFiles += [System.IO.Path]::GetFileName($ListPath)
    }
    $expected = Get-DeployFolderInventory -Path $SourcePath -ExcludeFileNames $excludeFiles -ExcludeDirectoryNames @('logs')
    $argList = Get-DeployRobocopyArgumentList -SourcePath $SourcePath -DestinationUnc $dest -ListPath $ListPath

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($token in $argList) {
        if ([string]::IsNullOrEmpty($token) -or $token.Contains(' ')) {
            [void]$parts.Add('"' + $token + '"')
        }
        else {
            [void]$parts.Add($token)
        }
    }
    $argString = ($parts.ToArray() -join ' ')

    $stdout = $null
    $stderr = $null
    $proc = $null
    $progressLen = 0
    try {
        $stdout = [System.IO.Path]::GetTempFileName()
        $stderr = [System.IO.Path]::GetTempFileName()
        $proc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $argString -PassThru -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        if ($null -eq $proc) {
            return [pscustomobject]@{ Success = $false; Files = 0; Bytes = 0 }
        }

        while (-not $proc.HasExited) {
            $destInv = Get-DeployFolderInventory -Path $dest -ExcludeFileNames @() -ExcludeDirectoryNames @()
            $pct = 100
            if ($expected.Bytes -gt 0) {
                $pct = [int][Math]::Floor(($destInv.Bytes * 100) / $expected.Bytes)
            }
            elseif ($expected.Files -gt 0) {
                $pct = [int][Math]::Floor(($destInv.Files * 100) / $expected.Files)
            }
            if ($pct -gt 100) { $pct = 100 }
            if ($pct -lt 0) { $pct = 0 }
            $filled = [int][Math]::Floor(($pct * 10) / 100)
            $bar = ('#' * $filled) + ('-' * (10 - $filled))
            $line = 'Copy ' + $Hostname + ' [' + $bar + '] ' + $pct + '%'
            if ($line.Length -lt $progressLen) { $line = $line.PadRight($progressLen) }
            if ($line.Length -gt $progressLen) { $progressLen = $line.Length }
            Write-Host ("`r" + $line) -NoNewline -ForegroundColor Gray
            Start-Sleep -Milliseconds 500
        }

        $code = [int]$proc.ExitCode
        $destFinal = Get-DeployFolderInventory -Path $dest -ExcludeFileNames @() -ExcludeDirectoryNames @()
        return [pscustomobject]@{
            Success = ($code -ge 0 -and $code -le 7)
            Files   = $destFinal.Files
            Bytes   = $destFinal.Bytes
        }
    }
    catch {
        return [pscustomobject]@{ Success = $false; Files = 0; Bytes = 0 }
    }
    finally {
        if ($progressLen -gt 0) { Write-Host '' }
        if ($stdout) { Remove-Item -LiteralPath $stdout -ErrorAction SilentlyContinue }
        if ($stderr) { Remove-Item -LiteralPath $stderr -ErrorAction SilentlyContinue }
    }
}

if (-not (Get-Command -Name 'New-CimSession' -ErrorAction SilentlyContinue)) {
    function New-CimSession {
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$ComputerName)
        throw 'New-CimSession is unavailable'
    }
}
if (-not (Get-Command -Name 'Invoke-CimMethod' -ErrorAction SilentlyContinue)) {
    function Invoke-CimMethod {
        [CmdletBinding()]
        param(
            $CimSession,
            [string]$ClassName,
            [string]$MethodName,
            $Arguments
        )
        throw 'Invoke-CimMethod is unavailable'
    }
}
if (-not (Get-Command -Name 'Remove-CimSession' -ErrorAction SilentlyContinue)) {
    function Remove-CimSession {
        [CmdletBinding()]
        param($CimSession)
    }
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
        Write-DeployLine -Kind 'Stage' -Text '  Copy ... FAILED (unreachable)'
        Write-DeployLine -Kind 'Stage' -Text '  Install ... skipped'
        return [pscustomobject]@{
            Hostname = $Hostname
            Outcome  = 'FAILED'
            Reason   = 'FAILED (unreachable)'
        }
    }

    Write-DeployLine -Kind 'Stage' -Text '  Copy ... start'
    $copy = Copy-DeployPayload -Hostname $Hostname -SourcePath $SourcePath -FolderName $FolderName -ListPath $ListPath
    if (-not $copy.Success) {
        Write-DeployLine -Kind 'Stage' -Text '  Copy ... FAILED (copy)'
        Write-DeployLine -Kind 'Stage' -Text '  Install ... skipped'
        return [pscustomobject]@{
            Hostname = $Hostname
            Outcome  = 'FAILED'
            Reason   = 'FAILED (copy)'
        }
    }

    Write-DeployLine -Kind 'Stage' -Text ('  Copy ... complete: ' + $copy.Files + ' files, ' + $copy.Bytes + ' bytes')

    $session = $null
    try {
        try {
            $session = New-CimSession -ComputerName $Hostname
        }
        catch {
            $session = $null
        }

        $started = $false
        if ($null -ne $session) {
            $dir = Get-DeployRemoteTargetPath -FolderName $FolderName
            
            <##
            Komenda instalacji na stacji. Katalog jest katalogiem docelowym kopii.
            install.bat ma leżeć w tym katalogu. Skrypt nie czeka na koniec tego procesu.
            ##>

            $commandLine = 'cmd.exe /c "cd /d ' + $dir + ' & install.bat"'
            try {
                $out = Invoke-CimMethod -CimSession $session -ClassName 'Win32_Process' -MethodName 'Create' -Arguments @{ CommandLine = $commandLine }
                if ($null -ne $out -and [int]$out.ReturnValue -eq 0 -and [int]$out.ProcessId -gt 0) {
                    $started = $true
                }
            }
            catch {
                $started = $false
            }
        }

        if (-not $started) {
            Write-DeployLine -Kind 'Stage' -Text '  Install ... FAILED (start)'
            return [pscustomobject]@{
                Hostname = $Hostname
                Outcome  = 'FAILED'
                Reason   = 'FAILED (start)'
            }
        }

        Write-DeployLine -Kind 'Stage' -Text '  Install ... STARTED'
        return [pscustomobject]@{
            Hostname = $Hostname
            Outcome  = 'STARTED'
            Reason   = 'STARTED'
        }
    }
    finally {
        if ($null -ne $session) {
            Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (Get-Command -Name Invoke-DeployMain -ErrorAction SilentlyContinue) {
        $code = Invoke-DeployMain -ComputerList $ComputerList
        exit $code
    }
}
