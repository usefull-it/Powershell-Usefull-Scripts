<#
.SYNOPSIS
    Metoda wykrywania AppLauncher dla Configuration Manager.

.NOTES
    Wklej całą treść tego pliku w typie wdrożenia:
    Detection Method → Use a custom script → PowerShell.
    Opcję „Run script as 32-bit process on 64-bit clients” zostaw wyłączoną.

    Pusty STDOUT i kod 0 = aplikacja nie jest zainstalowana.
    Dowolny tekst na STDOUT i kod 0 = aplikacja jest zainstalowana.
    Kod inny niż 0 = błąd skryptu (stan Unknown), a nie brak instalacji.

    Wartości muszą być zgodne z Install-AppLauncher.ps1.
    Ten skrypt nie czyta plików z paczki. Sprawdza tylko stan stacji.
#>

[CmdletBinding()]
param(
    <# Pełna ścieżka na stacji. Ta sama wartość co w Install-AppLauncher.ps1. #>
    [string]$FolderDocelowy = "C:\AppLauncher",

    [string]$NazwaPlikuExe = "AppLauncher.exe",

    [string]$NazwaFolderuAplikacji = "app",

    [string]$NazwaFolderuRuntime = "runtime",

    <# Nazwa skrótu na pulpicie, bez rozszerzenia .lnk. #>
    [string]$NazwaSkrotu = "AppLauncher",

    <# Puste = pulpit publiczny, widoczny dla wszystkich użytkowników. #>
    [string]$FolderPulpitu = ""
)


$ErrorActionPreference = "Stop"


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


$celPelny = [System.IO.Path]::GetFullPath($FolderDocelowy).TrimEnd("\")
$sciezkaExe = Join-Path $celPelny $NazwaPlikuExe
$sciezkaAplikacji = Join-Path $celPelny $NazwaFolderuAplikacji
$sciezkaRuntime = Join-Path $celPelny $NazwaFolderuRuntime
$sciezkaSkrotu = Join-Path $FolderPulpitu $NazwaSkrotu

$plikiSa = (Test-Path -LiteralPath $sciezkaExe -PathType Leaf) -and
    (Test-Path -LiteralPath $sciezkaAplikacji -PathType Container) -and
    (Test-Path -LiteralPath $sciezkaRuntime -PathType Container) -and
    (Test-Path -LiteralPath $sciezkaSkrotu -PathType Leaf)


<# Przy braku plików albo złym skrócie nic nie wypisujemy. #>
if ($plikiSa) {
    $powloka = New-Object -ComObject WScript.Shell
    $skrot = $powloka.CreateShortcut($sciezkaSkrotu)
    $celSkrotu = $skrot.TargetPath
    $katalogSkrotu = $skrot.WorkingDirectory

    $celZgodny = -not [string]::IsNullOrWhiteSpace($celSkrotu) -and
        ([System.IO.Path]::GetFullPath($celSkrotu) -eq $sciezkaExe)

    $katalogZgodny = -not [string]::IsNullOrWhiteSpace($katalogSkrotu) -and
        ([System.IO.Path]::GetFullPath($katalogSkrotu) -eq $celPelny)

    if ($celZgodny -and $katalogZgodny) {
        Write-Host "Installed"
    }
}


exit 0
