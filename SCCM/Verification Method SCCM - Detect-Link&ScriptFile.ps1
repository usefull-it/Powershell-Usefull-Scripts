<#
W SCCM: typ wdrożenia -> Metoda wykrywania -> Użyj niestandardowego skryptu -> PowerShell, wklej ten skrypt.
Wykryta tylko gdy istnieją skrót PowershellApp.lnk i PowershellApp.ps1. Inaczej pusty STDOUT, exit 0.
Checkbox 32-bit nie wpływa na te ścieżki (nie System32).
#>

$shortcut = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'PowershellApp.lnk'
$powershellApp = 'C:\temp\PowershellApp.ps1'

if ((Test-Path -LiteralPath $shortcut) -and (Test-Path -LiteralPath $powershellApp)) {
    Write-Output 'Installed'
}

exit 0
