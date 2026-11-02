#Requires -Version 5.1
<#
 Zbiór diagnostyki Ethernet ze stacji domenowych (WinRM HTTP 5985, udział c$).
 Uruchamiać z podniesionej sesji PowerShell na stacji administracyjnej, jako administrator domeny.
#>


# === KONFIGURACJA — edytuj przed uruchomieniem === #
$ComputerListPath = Join-Path $PSScriptRoot 'hosts.txt'  # lista hostów: jeden hostname w linii
$OutputRoot       = Join-Path $PSScriptRoot 'OutputEthernet'  # wyniki: OutputEthernet\<hostname>\
$LogPath          = Join-Path $PSScriptRoot 'ethernet-diag.log'
$EventDays        = 7                                    # dziennik zdarzeń: ostatnie N dni
            # === KONIEC KONFIGURACJI === #

$RemoteStaging = 'C:\Windows\Temp\EthernetDiagCollect'

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info','Success','Warn','Error')]
        [string]$Level = 'Info'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '{0} {1}' -f $stamp, $Message
    $color = @{ Info = 'White'; Success = 'Green'; Warn = 'Yellow'; Error = 'Red' }[$Level]
    Write-Host -NoNewline "$stamp " -ForegroundColor DarkGray
    Write-Host $Message -ForegroundColor $color
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $ComputerListPath)) {
    Write-Log "Nie znaleziono listy hostów: $ComputerListPath" -Level Error
    throw "Nie znaleziono listy hostów: $ComputerListPath"
}

$collect = {
    param($EventDays, $RemoteStaging)

    if (Test-Path -LiteralPath $RemoteStaging) {
        Remove-Item -LiteralPath $RemoteStaging -Recurse -Force
    }
    New-Item -ItemType Directory -Path $RemoteStaging -Force | Out-Null

    # 5.1 WinRM: stderr native (np. dot3svc Stopped) staje się ErrorRecord; PS 2>&1 urwałby Invoke-Command -ErrorAction Stop.
    cmd.exe /c "netsh lan show interfaces 2>&1" |
        Out-File -FilePath (Join-Path $RemoteStaging 'lan-interfaces.txt') -Encoding utf8
    cmd.exe /c "netsh lan show profiles 2>&1" |
        Out-File -FilePath (Join-Path $RemoteStaging 'lan-profiles.txt') -Encoding utf8
    cmd.exe /c "netsh lan show settings 2>&1" |
        Out-File -FilePath (Join-Path $RemoteStaging 'lan-settings.txt') -Encoding utf8

    $csv = Join-Path $RemoteStaging 'wired-autoconfig-operational.csv'
    $start = (Get-Date).AddDays(-[int]$EventDays)
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-Wired-AutoConfig/Operational'
        StartTime = $start
    } -ErrorAction SilentlyContinue)
    if ($events.Count -gt 0) {
        $events | Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
            Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
    }
    else {
        'Brak zdarzeń w zadanym oknie.' | Out-File -FilePath $csv -Encoding utf8
    }

    # MSFT_NetAdapter.NdisPhysicalMedium: 802.3 = 14
    $adapterFile = Join-Path $RemoteStaging 'netadapter-ethernet.txt'
    $ethernet = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
            $_.NdisPhysicalMedium -eq 14
        })
    if ($ethernet.Count -gt 0) {
        $ethernet | Format-List -Property * | Out-File -FilePath $adapterFile -Encoding utf8
    }
    else {
        'Brak adaptera Ethernet (NdisPhysicalMedium 802.3).' |
            Out-File -FilePath $adapterFile -Encoding utf8
    }

    [pscustomobject]@{
        EthernetAdapterCount = $ethernet.Count
    }
}

Write-Log 'Start zbierania diagnostyki Ethernet.'

$computers = foreach ($line in Get-Content -LiteralPath $ComputerListPath -Encoding UTF8) {
    $name = $line.Trim()
    if ($name -and -not $name.StartsWith('#')) {
        $name
    }
}

foreach ($Computer in $computers) {
    try {
        Write-Log "Start hosta: $Computer"

        try {
            $null = Test-WSMan -ComputerName $Computer -ErrorAction Stop
            Write-Log "WinRM OK: $Computer" -Level Success
        }
        catch {
            Write-Log "WinRM nieudany, pominięto: $Computer — $($_.Exception.Message)" -Level Error
            continue
        }

        $localDir = Join-Path $OutputRoot $Computer
        New-Item -ItemType Directory -Path $localDir -Force | Out-Null

        $result = Invoke-Command -ComputerName $Computer -ScriptBlock $collect `
            -ArgumentList $EventDays, $RemoteStaging -ErrorAction Stop

        if ($result.EthernetAdapterCount -eq 0) {
            Write-Log "Brak adaptera Ethernet: $Computer" -Level Warn
        }

        $uncRoot = '\\' + $Computer + '\c$' + $RemoteStaging.Substring(2)
        Write-Log "Kopiowanie z $Computer..."
        Copy-Item -Path ($uncRoot + '\*') -Destination $localDir -Force -ErrorAction Stop
        Write-Log "Kopiowanie zakończone: $Computer" -Level Success

        Remove-Item -LiteralPath $uncRoot -Recurse -Force -ErrorAction Stop
        Write-Log "Usunięto katalog tymczasowy: $Computer" -Level Success
        Write-Log "Zakończono hosta: $Computer" -Level Success
    }
    catch {
        Write-Log "Błąd [$Computer]: $($_.Exception.Message)" -Level Error
    }
}

Write-Log 'Zakończono zbieranie diagnostyki Ethernet.' -Level Success