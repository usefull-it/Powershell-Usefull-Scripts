#Requires -Version 5.1
<#
 Collect Bluetooth diagnostics from domain stations (WinRM HTTP 5985, c$ share).
 Run from an elevated PowerShell session on an admin station, as a domain administrator.
#>


# === CONFIGURATION - edit before running === #
$ComputerListPath = Join-Path $PSScriptRoot 'hosts.txt'  # hosts list: one hostname per line
$OutputRoot       = Join-Path $PSScriptRoot 'OutputBluetooth'  # results: OutputBluetooth\<hostname>\
$LogPath          = Join-Path $PSScriptRoot 'bluetooth-diag.log'
$EventDays        = 7                                    # event log: last N days
            # === END CONFIGURATION === #

$RemoteStaging = 'C:\Windows\Temp\BluetoothDiagCollect'

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

    $start = (Get-Date).AddDays(-[int]$EventDays)
    foreach ($item in @(
            @{ LogName = 'Microsoft-Windows-Bluetooth-Policy/Operational'; File = 'bluetooth-policy-operational.csv' },
            @{ LogName = 'Microsoft-Windows-Bluetooth-Bthmini/Operational'; File = 'bluetooth-bthmini-operational.csv' }
        )) {
        $csv = Join-Path $RemoteStaging $item.File
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName   = $item.LogName
            StartTime = $start
        } -ErrorAction SilentlyContinue)
        if ($events.Count -gt 0) {
            $events | Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
                Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
        }
        else {
            'No events in the requested window.' | Out-File -FilePath $csv -Encoding utf8
        }
    }

    $pnpFile = Join-Path $RemoteStaging 'pnp-bluetooth.txt'
    $pnp = @()
    try {
        $pnp = @(Get-PnpDevice -Class Bluetooth -ErrorAction Stop)
        if ($pnp.Count -gt 0) {
            $pnp | Select-Object Status, Class, FriendlyName, InstanceId, Problem |
                Format-List | Out-File -FilePath $pnpFile -Encoding utf8
        }
        else {
            'No Bluetooth PnP devices.' | Out-File -FilePath $pnpFile -Encoding utf8
        }
    }
    catch {
        $_.Exception.Message | Out-File -FilePath $pnpFile -Encoding utf8
    }

    # MSFT_NetAdapter.NdisPhysicalMedium: BlueTooth = 10
    $adapterFile = Join-Path $RemoteStaging 'netadapter-bluetooth.txt'
    $bluetooth = @()
    try {
        $bluetooth = @(Get-NetAdapter -ErrorAction Stop | Where-Object {
                $_.NdisPhysicalMedium -eq 10
            })
        if ($bluetooth.Count -gt 0) {
            $bluetooth | Format-List -Property * | Out-File -FilePath $adapterFile -Encoding utf8
        }
        else {
            'No Bluetooth adapter (NdisPhysicalMedium BlueTooth).' |
                Out-File -FilePath $adapterFile -Encoding utf8
        }
    }
    catch {
        $_.Exception.Message | Out-File -FilePath $adapterFile -Encoding utf8
    }

    [pscustomobject]@{
        PnpBluetoothCount     = $pnp.Count
        BluetoothAdapterCount = $bluetooth.Count
    }
}

Write-Log 'Start collecting Bluetooth diagnostics.'

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

        if ($result.PnpBluetoothCount -eq 0) {
            Write-Log "No Bluetooth PnP devices: $Computer" -Level Warn
        }
        if ($result.BluetoothAdapterCount -eq 0) {
            Write-Log "No Bluetooth adapter: $Computer" -Level Warn
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

Write-Log 'Finished collecting Bluetooth diagnostics.' -Level Success
