<#
.SYNOPSIS
    Kopiuje AppLauncher na dysk lokalny i tworzy skrót na pulpicie publicznym.

.NOTES
    Skrypt przygotowany bezpośrednio dla aplikacji SCCM, typ wdrożenia Instalator Skryptowy.
    Instalacja dla systemu. Opcję procesu 32-bitowego zostaw wyłączoną.

    Program instalacyjny:
    %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-AppLauncher.ps1

    Metoda wykrywania: cała treść pliku Detect-AppLauncher.ps1, wklejona jako skrypt PowerShell.

    Układ paczki:
    Install-AppLauncher.ps1
    Detect-AppLauncher.ps1
    AppLauncher\
        AppLauncher.exe
        app\
        runtime\

    Wartości FolderDocelowy, NazwaPlikuExe, NazwaFolderuAplikacji, NazwaFolderuRuntime
    i NazwaSkrotu muszą być takie same w Detect-AppLauncher.ps1.
#>

[CmdletBinding()]
param(
    [string]$NazwaFolderuZrodla = "AppLauncher",

    <# Puste = folder NazwaFolderuZrodla leżący obok tego skryptu. #>
    [string]$FolderZrodlowy = "",

    <# Pełna ścieżka na stacji. #>
    [string]$FolderDocelowy = "C:\AppLauncher",

    [string]$NazwaPlikuExe = "AppLauncher.exe",

    [string]$NazwaFolderuAplikacji = "app",

    [string]$NazwaFolderuRuntime = "runtime",

    <# Nazwa skrótu na pulpicie, bez rozszerzenia .lnk. #>
    [string]$NazwaSkrotu = "AppLauncher",

    <# Puste = ikona z pliku exe. Inaczej nazwa pliku .ico w folderze źródłowym albo pełna ścieżka. #>
    [string]$PlikIkony = "AppLauncher.ico",

    <# Puste = pulpit publiczny, widoczny dla wszystkich użytkowników. #>
    [string]$FolderPulpitu = ""
)


$ErrorActionPreference = "Stop"


function Stop-Instalacja {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Komunikat
    )

    Write-Error -Message $Komunikat -ErrorAction Continue
    exit 1
}


if ([string]::IsNullOrWhiteSpace($FolderZrodlowy)) {
    $FolderZrodlowy = Join-Path $PSScriptRoot $NazwaFolderuZrodla
}


if ([string]::IsNullOrWhiteSpace($FolderPulpitu)) {
    $FolderPulpitu = [Environment]::GetFolderPath("CommonDesktopDirectory")
}

if ([string]::IsNullOrWhiteSpace($FolderPulpitu)) {
    $FolderPulpitu = Join-Path $env:PUBLIC "Desktop"
}

$FolderPulpitu = [System.IO.Path]::GetFullPath($FolderPulpitu).TrimEnd("\")


if ($NazwaSkrotu -notlike "*.lnk") {
    $NazwaSkrotu = "$NazwaSkrotu.lnk"
}


$zrodloPelne = [System.IO.Path]::GetFullPath($FolderZrodlowy)

if ($zrodloPelne.TrimEnd("\") -eq [System.IO.Path]::GetPathRoot($zrodloPelne).TrimEnd("\")) {
    Stop-Instalacja "Folder źródłowy nie może być katalogiem głównym dysku."
}

$zrodloPelne = $zrodloPelne.TrimEnd("\")
$sciezkaExeZrodla = Join-Path $zrodloPelne $NazwaPlikuExe

<# Niepełna paczka nie może ruszyć kopii, która już działa na stacji. #>
if (-not (Test-Path -LiteralPath $zrodloPelne -PathType Container)) {
    Stop-Instalacja "Brak folderu źródłowego: $zrodloPelne"
}

if (-not (Test-Path -LiteralPath $sciezkaExeZrodla -PathType Leaf)) {
    Stop-Instalacja "Brak pliku uruchomieniowego: $sciezkaExeZrodla"
}

foreach ($podfolder in @($NazwaFolderuAplikacji, $NazwaFolderuRuntime)) {
    $sciezkaPodfolderu = Join-Path $zrodloPelne $podfolder

    if (-not (Test-Path -LiteralPath $sciezkaPodfolderu -PathType Container)) {
        Stop-Instalacja "Brak podfolderu: $sciezkaPodfolderu"
    }
}


$zrodloIkony = $null

if (-not [string]::IsNullOrWhiteSpace($PlikIkony)) {
    if ([System.IO.Path]::IsPathRooted($PlikIkony)) {
        $zrodloIkony = [System.IO.Path]::GetFullPath($PlikIkony)
    }
    else {
        $zrodloIkony = Join-Path $zrodloPelne $PlikIkony
    }

    if (-not (Test-Path -LiteralPath $zrodloIkony -PathType Leaf)) {
        Stop-Instalacja "Brak pliku ikony: $zrodloIkony"
    }

    if ([System.IO.Path]::GetExtension($zrodloIkony) -ne ".ico") {
        Stop-Instalacja "Ikona musi być plikiem .ico: $zrodloIkony"
    }
}


$celPelny = [System.IO.Path]::GetFullPath($FolderDocelowy)

if ($celPelny.TrimEnd("\") -eq [System.IO.Path]::GetPathRoot($celPelny).TrimEnd("\")) {
    Stop-Instalacja "Folder docelowy nie może być katalogiem głównym dysku."
}

$celPelny = $celPelny.TrimEnd("\")

if ($zrodloPelne -eq $celPelny) {
    Stop-Instalacja "Folder źródłowy i docelowy nie mogą być tym samym katalogiem."
}

<#
    /MIR kasuje w celu pliki nieobecne w źródle, więc cel nie może leżeć
    w katalogu systemowym ani na pulpicie publicznym.
#>
$folderyChronione = @(
    $env:SystemRoot
    ${env:ProgramFiles}
    ${env:ProgramFiles(x86)}
    $FolderPulpitu
)

foreach ($folderChroniony in $folderyChronione) {
    if ([string]::IsNullOrWhiteSpace($folderChroniony)) {
        continue
    }

    $folderChroniony = [System.IO.Path]::GetFullPath($folderChroniony).TrimEnd("\")
    $tenSam = $celPelny.Equals($folderChroniony, [System.StringComparison]::OrdinalIgnoreCase)
    $wSrodku = $celPelny.StartsWith($folderChroniony + "\", [System.StringComparison]::OrdinalIgnoreCase)

    if ($tenSam -or $wSrodku) {
        Stop-Instalacja "Folder docelowy nie może leżeć w katalogu chronionym: $celPelny"
    }
}


<#
    /MIR uzupełnia pliki i przy aktualizacji usuwa z celu te, których nie ma już w źródle.
    /R:1 /W:1 ogranicza ponowienia. Bez /256 robocopy zachowuje długie ścieżki.
    Kod 8 i wyższy oznacza błąd. Kody 0–7 oznaczają udane kopiowanie.
#>

$robocopy = Join-Path $env:SystemRoot "System32\robocopy.exe"

if (-not (Test-Path -LiteralPath $robocopy -PathType Leaf)) {
    Stop-Instalacja "Brak programu robocopy: $robocopy"
}

$argumentyKopiowania = @(
    $zrodloPelne
    $celPelny
    "/MIR"
    "/R:1"
    "/W:1"
    "/MT:8"
    "/NP"
    "/NFL"
    "/NDL"
)

& $robocopy @argumentyKopiowania
$kodKopiowania = $LASTEXITCODE

if ($kodKopiowania -ge 8) {
    Stop-Instalacja "Kopiowanie nie powiodło się. Kod robocopy: $kodKopiowania"
}


$sciezkaExe = Join-Path $celPelny $NazwaPlikuExe

if (-not (Test-Path -LiteralPath $sciezkaExe -PathType Leaf)) {
    Stop-Instalacja "Po kopiowaniu brakuje pliku: $sciezkaExe"
}

foreach ($podfolder in @($NazwaFolderuAplikacji, $NazwaFolderuRuntime)) {
    $sciezkaPodfolderu = Join-Path $celPelny $podfolder

    if (-not (Test-Path -LiteralPath $sciezkaPodfolderu -PathType Container)) {
        Stop-Instalacja "Po kopiowaniu brakuje podfolderu: $sciezkaPodfolderu"
    }
}


<# Ikona skrótu musi leżeć na dysku lokalnym. Cache Configuration Manager bywa czyszczony. #>
$sciezkaIkonyLokalnej = $null

if ($zrodloIkony) {
    $sciezkaIkonyLokalnej = Join-Path $celPelny ([System.IO.Path]::GetFileName($zrodloIkony))

    if ([System.IO.Path]::GetFullPath($zrodloIkony) -ne $sciezkaIkonyLokalnej) {
        Copy-Item -LiteralPath $zrodloIkony -Destination $sciezkaIkonyLokalnej -Force
    }

    if (-not (Test-Path -LiteralPath $sciezkaIkonyLokalnej -PathType Leaf)) {
        Stop-Instalacja "Po kopiowaniu brakuje ikony: $sciezkaIkonyLokalnej"
    }
}


if (-not (Test-Path -LiteralPath $FolderPulpitu -PathType Container)) {
    New-Item -ItemType Directory -Path $FolderPulpitu -Force | Out-Null
}

$sciezkaSkrotu = Join-Path $FolderPulpitu $NazwaSkrotu
$powloka = New-Object -ComObject WScript.Shell
$skrot = $powloka.CreateShortcut($sciezkaSkrotu)

<# Katalog roboczy to folder aplikacji, bo launcher szuka podfolderów app i runtime obok siebie. #>
$skrot.TargetPath = $sciezkaExe
$skrot.WorkingDirectory = $celPelny

if ($sciezkaIkonyLokalnej) {
    $skrot.IconLocation = "$sciezkaIkonyLokalnej,0"
}

$skrot.Save()


$zapisany = $powloka.CreateShortcut($sciezkaSkrotu)

if ([string]::IsNullOrWhiteSpace($zapisany.TargetPath)) {
    Stop-Instalacja "Skrót nie ma celu: $sciezkaSkrotu"
}

if ([System.IO.Path]::GetFullPath($zapisany.TargetPath) -ne $sciezkaExe) {
    Stop-Instalacja "Skrót nie wskazuje na $sciezkaExe"
}

if ([System.IO.Path]::GetFullPath($zapisany.WorkingDirectory) -ne $celPelny) {
    Stop-Instalacja "Katalog roboczy skrótu jest inny niż $celPelny"
}

if ($sciezkaIkonyLokalnej) {
    $nazwaIkony = [System.IO.Path]::GetFileName($sciezkaIkonyLokalnej)
    $ikonaZapisana = $zapisany.IconLocation.IndexOf($nazwaIkony, [System.StringComparison]::OrdinalIgnoreCase) -ge 0

    if (-not $ikonaZapisana) {
        Stop-Instalacja "Skrót nie dostał ikony: $sciezkaIkonyLokalnej"
    }
}


Write-Output "Zainstalowano: $sciezkaExe"
Write-Output "Skrót: $sciezkaSkrotu"
exit 0
