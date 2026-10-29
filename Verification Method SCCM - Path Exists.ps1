# Przed użyciem w SCCM zmień tylko $Path na pełną ścieżkę pliku albo folderu.
# Przykład: C:\Program Files\App\app.exe
# Skrypt działa jako SYSTEM. Write-Host i exit 0 zostaw bez zmian.

$ErrorActionPreference = 'Stop'

$Path = 'C:\Program Files\App\app.exe'

try {
    if ([string]::IsNullOrWhiteSpace($Path)) { exit 0 }

    if (Test-Path -LiteralPath $Path) {
        Write-Host 'Installed'
    }
} catch {}

exit 0
