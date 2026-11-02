<#
Przed użyciem w SCCM zmień tylko $ServiceName na nazwę usługi z services.msc (pole Nazwa usługi).
Nie wpisuj nazwy wyświetlanej. Znaki * i ? są ignorowane.
Wystarczy, że usługa istnieje; nie musi działać. Write-Host i exit 0 zostaw bez zmian.
#>

$ErrorActionPreference = 'Stop'

$ServiceName = 'ServiceName'

try {
    if ([string]::IsNullOrWhiteSpace($ServiceName) -or $ServiceName -match '[*?]') {
        exit 0
    }

    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Write-Host 'Installed'
    }
} catch {}

exit 0
