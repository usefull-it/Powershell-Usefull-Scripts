<#
Przed użyciem w SCCM zmień tylko $ProductCode na GUID produktu MSI, razem z nawiasami.
GUID jest we właściwościach MSI albo w kluczu Uninstall.
Skrypt działa jako SYSTEM i widzi instalacje per-machine. Write-Host i exit 0 zostaw bez zmian.
#>

$ErrorActionPreference = 'Stop'

$ProductCode = '{00000000-0000-0000-0000-000000000000}'

try {
    if ($ProductCode -notmatch '^\{[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$') {
        exit 0
    }

    $installer = New-Object -ComObject WindowsInstaller.Installer
    if ($installer.ProductState($ProductCode) -eq 5) {
        Write-Host 'Installed'
    }
} catch {}

exit 0
