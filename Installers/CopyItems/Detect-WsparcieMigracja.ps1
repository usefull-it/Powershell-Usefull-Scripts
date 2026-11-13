# W SCCM: typ wdrożenia -> Metoda wykrywania -> Użyj niestandardowego skryptu -> PowerShell, wklej ten skrypt.
# Wykryta tylko gdy są skrót Status Migracji.lnk i MigrationPanel.ps1. Inaczej pusty STDOUT, exit 0.
# Checkbox 32-bit nie wpływa na te ścieżki (nie System32).

$shortcut = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'WSPARCIE_MIGRACJA\Status Migracji.lnk'
$panel = 'C:\temp\NarzedziaMigracyjne\MigrationPanel.ps1'

if ((Test-Path -LiteralPath $shortcut) -and (Test-Path -LiteralPath $panel)) {
    Write-Output 'Installed'
}

exit 0
