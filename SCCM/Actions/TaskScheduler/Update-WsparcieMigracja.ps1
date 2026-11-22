# Usuwa 9 plików PDF z folderu WSPARCIE_MIGRACJA na publicznym pulpicie
# i kopiuje jeden plik PDF z folderu WSPARCIE_MIGRACJA obok tego skryptu.
# Uzupełnij nazwy w $FilesToRemove i $FileToCopy.
# Kod wyjścia 0 to sukces. Inny kod SCCM ma widzieć jako błąd programu.

$ErrorActionPreference = 'Stop'

$FolderName = 'WSPARCIE_MIGRACJA'

$FilesToRemove = @(
    'DO_USUNIECIA_1.pdf'
    'DO_USUNIECIA_2.pdf'
    'DO_USUNIECIA_3.pdf'
    'DO_USUNIECIA_4.pdf'
    'DO_USUNIECIA_5.pdf'
    'DO_USUNIECIA_6.pdf'
    'DO_USUNIECIA_7.pdf'
    'DO_USUNIECIA_8.pdf'
    'DO_USUNIECIA_9.pdf'
)

$FileToCopy = 'DO_SKOPIOWANIA.pdf'

$PublicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')

if ([string]::IsNullOrWhiteSpace($PublicDesktop)) {
    Write-Host 'Nie można ustalić ścieżki publicznego pulpitu.'
    exit 1
}

$Destination = Join-Path $PublicDesktop $FolderName

if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
    Write-Host "Brak folderu docelowego: $Destination"
    exit 1
}

$Source = Join-Path $PSScriptRoot $FolderName
$SourceFile = Join-Path $Source $FileToCopy

if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) {
    Write-Host "Brak pliku do skopiowania: $SourceFile"
    exit 1
}

foreach ($Name in $FilesToRemove) {
    $Path = Join-Path $Destination $Name
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Write-Host "Brak pliku do usunięcia: $Path"
        exit 1
    }
}

foreach ($Name in $FilesToRemove) {
    Remove-Item -LiteralPath (Join-Path $Destination $Name) -Force
    Write-Host "Usunięto: $Name"
}

Copy-Item -LiteralPath $SourceFile -Destination (Join-Path $Destination $FileToCopy) -Force
Write-Host "Skopiowano: $FileToCopy"

exit 0
