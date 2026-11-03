#Requires -Version 5.1
<#
 Collect Ethernet diagnostics from domain stations (WinRM HTTP 5985, c$ share).
 Run from an elevated PowerShell session on an admin station, as a domain administrator.
#>


# === CONFIGURATION - edit before running === #
$ComputerListPath = Join-Path $PSScriptRoot 'hosts.txt'  # hosts list: one hostname per line
$OutputRoot       = Join-Path $PSScriptRoot 'OutputEthernet'  # results: OutputEthernet\<hostname>\
$LogPath          = Join-Path $PSScriptRoot 'ethernet-diag.log'
$EventDays        = 7                                    # event log: last N days
            # === END CONFIGURATION === #

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
    Write-Log "Hosts list not found: $ComputerListPath" -Level Error
    throw "Hosts list not found: $ComputerListPath"
}

$collect = {
    param($EventDays, $RemoteStaging)

    if (Test-Path -LiteralPath $RemoteStaging) {
        Remove-Item -LiteralPath $RemoteStaging -Recurse -Force
    }
    New-Item -ItemType Directory -Path $RemoteStaging -Force | Out-Null

    # 5.1 WinRM: native stderr (e.g. dot3svc Stopped) becomes ErrorRecord; PS 2>&1 would abort Invoke-Command -ErrorAction Stop.
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
        'No events in the requested window.' | Out-File -FilePath $csv -Encoding utf8
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
        'No Ethernet adapter (NdisPhysicalMedium 802.3).' |
            Out-File -FilePath $adapterFile -Encoding utf8
    }

    [pscustomobject]@{
        EthernetAdapterCount = $ethernet.Count
    }
}

Write-Log 'Start collecting Ethernet diagnostics.'

$computers = foreach ($line in Get-Content -LiteralPath $ComputerListPath -Encoding UTF8) {
    $name = $line.Trim()
    if ($name -and -not $name.StartsWith('#')) {
        $name
    }
}

foreach ($Computer in $computers) {
    try {
        Write-Log "Start host: $Computer"

        try {
            $null = Test-WSMan -ComputerName $Computer -ErrorAction Stop
            Write-Log "WinRM OK: $Computer" -Level Success
        }
        catch {
            Write-Log "WinRM failed, skipped: $Computer - $($_.Exception.Message)" -Level Error
            continue
        }

        $localDir = Join-Path $OutputRoot $Computer
        New-Item -ItemType Directory -Path $localDir -Force | Out-Null

        $result = Invoke-Command -ComputerName $Computer -ScriptBlock $collect `
            -ArgumentList $EventDays, $RemoteStaging -ErrorAction Stop

        if ($result.EthernetAdapterCount -eq 0) {
            Write-Log "No Ethernet adapter: $Computer" -Level Warn
        }

        $uncRoot = '\\' + $Computer + '\c$' + $RemoteStaging.Substring(2)
        Write-Log "Copying from $Computer..."
        Copy-Item -Path ($uncRoot + '\*') -Destination $localDir -Force -ErrorAction Stop
        Write-Log "Copy finished: $Computer" -Level Success

        Remove-Item -LiteralPath $uncRoot -Recurse -Force -ErrorAction Stop
        Write-Log "Removed temp folder: $Computer" -Level Success
        Write-Log "Finished host: $Computer" -Level Success
    }
    catch {
        Write-Log "Error [$Computer]: $($_.Exception.Message)" -Level Error
    }
}

Write-Log 'Finished collecting Ethernet diagnostics.' -Level Success
