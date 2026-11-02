<#
Requires -Version 5.1
Zbiór diagnostyki Wi-Fi ze stacji domenowych (WinRM HTTP 5985, udział c$).
Uruchamiać z podniesionej sesji PowerShell na stacji administracyjnej, jako administrator domeny.
#>

# === KONFIGURACJA — edytuj przed uruchomieniem ===
$ComputerListPath = Join-Path $PSScriptRoot 'hosts.txt'  # lista hostów: jeden hostname w linii
$OutputRoot       = Join-Path $PSScriptRoot 'Output'     # wyniki: Output\<hostname>\
$LogPath          = Join-Path $PSScriptRoot 'wifi-diag.log'
$EventDays        = 7                                    # dziennik zdarzeń: ostatnie N dni
        # === KONIEC KONFIGURACJI ===

$RemoteStaging  = 'C:\Windows\Temp\WifiDiagCollect'
$WlanReportHtml = 'C:\ProgramData\Microsoft\Windows\WlanReport\wlan-report-latest.html'

function Write-Log {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
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
    throw "Nie znaleziono listy hostów: $ComputerListPath"
}

$collect = {
    param($EventDays, $RemoteStaging, $WlanReportHtml)

    if (Test-Path -LiteralPath $RemoteStaging) {
        Remove-Item -LiteralPath $RemoteStaging -Recurse -Force
    }
    New-Item -ItemType Directory -Path $RemoteStaging -Force | Out-Null

    & netsh wlan show interfaces 2>&1 |
        Out-File -FilePath (Join-Path $RemoteStaging 'wlan-interfaces.txt') -Encoding utf8
    & netsh wlan show drivers 2>&1 |
        Out-File -FilePath (Join-Path $RemoteStaging 'wlan-drivers.txt') -Encoding utf8
    & netsh wlan show profiles 2>&1 |
        Out-File -FilePath (Join-Path $RemoteStaging 'wlan-profiles.txt') -Encoding utf8
    & netsh wlan show networks mode=bssid 2>&1 |
        Out-File -FilePath (Join-Path $RemoteStaging 'wlan-networks-bssid.txt') -Encoding utf8

    $csv = Join-Path $RemoteStaging 'wlan-autoconfig-operational.csv'
    $start = (Get-Date).AddDays(-[int]$EventDays)
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName   = 'Microsoft-Windows-WLAN-AutoConfig/Operational'
        StartTime = $start
    } -ErrorAction SilentlyContinue)
    if ($events.Count -gt 0) {
        $events | Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
            Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
    }
    else {
        'Brak zdarzeń w zadanym oknie.' | Out-File -FilePath $csv -Encoding utf8
    }

    # MSFT_NetAdapter.NdisPhysicalMedium: Native 802.11 = 9, Wireless LAN = 1
    $adapterFile = Join-Path $RemoteStaging 'netadapter-wifi.txt'
    $wifi = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
            $_.NdisPhysicalMedium -eq 9 -or $_.NdisPhysicalMedium -eq 1
        })
    if ($wifi.Count -gt 0) {
        $wifi | Format-List -Property * | Out-File -FilePath $adapterFile -Encoding utf8
    }
    else {
        'Brak adaptera Wi-Fi (NdisPhysicalMedium Native 802.11 / Wireless LAN).' |
            Out-File -FilePath $adapterFile -Encoding utf8
    }

    $null = & netsh wlan show wlanreport 2>&1
    $htmlDest = Join-Path $RemoteStaging 'wlan-report-latest.html'
    $reportCopied = $false
    if (Test-Path -LiteralPath $WlanReportHtml) {
        Copy-Item -LiteralPath $WlanReportHtml -Destination $htmlDest -Force
        $reportCopied = $true
    }

    [pscustomobject]@{
        WifiAdapterCount = $wifi.Count
        WlanReportCopied = $reportCopied
    }
}

Write-Log 'Start zbierania diagnostyki Wi-Fi.'

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
            Write-Log "WinRM OK: $Computer"
        }
        catch {
            Write-Log "WinRM nieudany, pominięto: $Computer — $($_.Exception.Message)"
            continue
        }

        $localDir = Join-Path $OutputRoot $Computer
        New-Item -ItemType Directory -Path $localDir -Force | Out-Null

        $result = Invoke-Command -ComputerName $Computer -ScriptBlock $collect `
            -ArgumentList $EventDays, $RemoteStaging, $WlanReportHtml -ErrorAction Stop

        if ($result.WifiAdapterCount -eq 0) {
            Write-Log "Brak adaptera Wi-Fi: $Computer"
        }
        if (-not $result.WlanReportCopied) {
            Write-Log "Brak pliku wlanreport HTML: $Computer"
        }

        $uncRoot = '\\' + $Computer + '\c$' + $RemoteStaging.Substring(2)
        Write-Log "Kopiowanie z $Computer..."
        Copy-Item -Path ($uncRoot + '\*') -Destination $localDir -Force -ErrorAction Stop
        Write-Log "Kopiowanie zakończone: $Computer"

        Remove-Item -LiteralPath $uncRoot -Recurse -Force -ErrorAction Stop
        Write-Log "Usunięto katalog tymczasowy: $Computer"
        Write-Log "Zakończono hosta: $Computer"
    }
    catch {
        Write-Log "Błąd [$Computer]: $($_.Exception.Message)"
    }
}

Write-Log 'Zakończono zbieranie diagnostyki Wi-Fi.'
