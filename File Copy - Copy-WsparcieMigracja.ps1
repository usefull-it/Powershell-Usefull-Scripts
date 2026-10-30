# Kopiuje folder WSPARCIE_MIGRACJA z treści pakietu SCCM na publiczny pulpit.
# Kody robocopy 0-7 to sukces. 2 i 3 pojawiają się, gdy na pulpicie są pliki spoza pakietu i te pliki zostają.
# Kod 8 i wyższy SCCM ma widzieć jako błąd programu.

$ErrorActionPreference = 'Stop'

$FolderName = 'WSPARCIE_MIGRACJA'
$Source = Join-Path $PSScriptRoot $FolderName
$PublicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')

if ([string]::IsNullOrWhiteSpace($PublicDesktop)) {
    Write-Host 'Nie można ustalić ścieżki publicznego pulpitu.'
    exit 1
}

if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
    Write-Host "Brak folderu źródłowego: $Source"
    exit 1
}

$Destination = Join-Path $PublicDesktop $FolderName

& robocopy.exe $Source $Destination /E /R:2 /W:5 /NP
$RobocopyExit = $LASTEXITCODE

if ($RobocopyExit -ge 8) {
    exit $RobocopyExit
}

exit 0
