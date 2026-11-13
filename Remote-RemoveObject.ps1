<#
Usuwa wskazany plik albo katalog na jednostkach domenowych z pliku tekstowego.

Uruchomienie:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Remote-RemoveObject.ps1" -Sciezka "C:\DoUsuniecia\folder"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Remote-RemoveObject.ps1" -Sciezka "D:\DoUsuniecia\plik.txt" -ListaKomputerow "D:\lista\komputery.txt"

Domyślna lista: komputery.txt obok tego skryptu. Jedna nazwa jednostki w wierszu.
Puste wiersze i wiersze zaczynające się od # (po obcięciu spacji) są pomijane.
Ta sama ścieżka jest używana na każdej jednostce. To lokalna ścieżka na dysku
jednostki, na przykład C:\Folder\plik.txt albo D:\Folder\plik.txt. Musi być
bezwzględna. Skrypt odrzuca korzeń dysku, segmenty "." i "..", znaki
wieloznaczne oraz ścieżkę UNC podaną przez operatora.

Skrypt zakłada uruchomienie kontem administratora z dostępem do WinRM i do
udziałów administracyjnych. Nie prosi o poświadczenia i nie sprawdza tych
uprawnień. Kasowanie idzie przez udział administracyjny dysku ze ścieżki:
C:\Folder\plik.txt na jednostce PC staje się \\PC\C$\Folder\plik.txt,
a D:\Folder\plik.txt staje się \\PC\D$\Folder\plik.txt.

Katalog jest usuwany razem z zawartością. Bez parametru -Recurse polecenie
Remove-Item pyta o potwierdzenie, a -Confirm:$false tego pytania nie wyłącza
(zgodnie z dokumentacją Microsoft Learn, Remove-Item, Windows PowerShell 5.1). 
-LiteralPath nie rozwija symboli * i ?. Po Remove-Item skrypt sprawdza, czy obiekt zniknął.
Łącze katalogowe (junction) jest usuwane; zawartość jego celu zostaje.

Brak obiektu na jednostce liczy się jako błąd tej jednostki.
Log powstaje obok skryptu. Kod wyjścia: 0 tylko gdy każda jednostka z listy
zakończyła usuwanie powodzeniem. W pozostałych przypadkach kod wyjścia to 1.
#>

[CmdletBinding()]
param(
    #Lokalna ścieżka pliku lub katalogu na dysku jednostki docelowej.
    [string]$Sciezka,

    #Pusta wartość oznacza komputery.txt obok skryptu.
    [string]$ListaKomputerow
)

if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Write-Host 'Uruchom skrypt z pliku (powershell.exe -File). Wklejenie do konsoli nie wyznacza folderu skryptu.'
    exit 1
}

if ([string]::IsNullOrWhiteSpace($ListaKomputerow)) {
    $ListaKomputerow = Join-Path $PSScriptRoot 'komputery.txt'
}

$ProgressPreference = 'SilentlyContinue'
$ConfirmPreference = 'None'
$poprawnie = 0
$blednie = 0
$log = Join-Path $PSScriptRoot ('Remote-RemoveObject_{0:yyyyMMdd_HHmmss_fff}.log' -f (Get-Date))
$sep = '=' * 72


function Write-Log {
    param(
        [string]$Komputer,
        [string]$Krok,
        [string]$Wynik,
        [string]$Szczegoly
    )

    $wiersze = @(
        ('{0:yyyy-MM-dd HH:mm:ss} | {1} | {2} | {3}' -f (Get-Date), $Komputer, $Krok, $Wynik)
    )
    if ($Szczegoly) {
        $wiersze += $Szczegoly.TrimEnd()
    }
    $wiersze += ('-' * 40)
    $tekst = ($wiersze -join [Environment]::NewLine) + [Environment]::NewLine
    [System.IO.File]::AppendAllText($log, $tekst, (New-Object System.Text.UTF8Encoding $false))
}


#Podsumowanie liczników w konsoli i w logu.
function Write-Podsumowanie {
    Write-Host ''
    Write-Host $sep
    Write-Host 'Podsumowanie jednostek'
    Write-Host ("Poprawnie: {0}" -f $poprawnie)
    Write-Host ("Błędnie:   {0}" -f $blednie)
    Write-Host ("Razem:     {0}" -f ($poprawnie + $blednie))
    Write-Host "Log:       $log"
    Write-Host $sep
    Write-Log -Komputer '-' -Krok 'podsumowanie' -Wynik 'INFO' -Szczegoly ("Poprawnie: {0}; Błędnie: {1}" -f $poprawnie, $blednie)
}


#Lokalna ścieżka na dysku jednostki, zanim powstanie ścieżka udziału.
$Sciezka = if ($null -eq $Sciezka) { '' } else { $Sciezka.Trim().Replace('/', '\').TrimEnd('\') }

$bladSciezki = $null
if ([string]::IsNullOrWhiteSpace($Sciezka)) {
    $bladSciezki = 'Nie podano ścieżki. Użyj parametru -Sciezka, na przykład -Sciezka "C:\Folder\plik.txt".'
}
elseif ($Sciezka.StartsWith('\\')) {
    $bladSciezki = "Podaj lokalną ścieżkę na dysku jednostki. Udział administracyjny buduje skrypt: $Sciezka"
}
elseif ($Sciezka -notmatch '^[A-Za-z]:\\.+$') {
    $bladSciezki = "Ścieżka musi być bezwzględna i nie może być korzeniem dysku: $Sciezka"
}
else {
    $segmenty = $Sciezka.Substring(3).Split('\')
    if ($segmenty -contains '' -or $segmenty -contains '.' -or $segmenty -contains '..') {
        $bladSciezki = "Ścieżka zawiera pusty segment albo odwołanie '.' lub '..': $Sciezka"
    }
    else {
        foreach ($znak in ([System.IO.Path]::GetInvalidPathChars() + @('*', '?'))) {
            if ($Sciezka.Contains([string]$znak)) {
                $bladSciezki = "Ścieżka zawiera niedozwolony znak: $Sciezka"
                break
            }
        }
    }
}

if ($bladSciezki) {
    Write-Host $sep
    Write-Host $bladSciezki
    Write-Log -Komputer '-' -Krok 'ścieżka' -Wynik 'BŁĄD' -Szczegoly $bladSciezki
    Write-Podsumowanie
    if ($MyInvocation.InvocationName -ne '.') { exit 1 }
    return
}


#Sprawdzenie, czy plik z listą jednostek istnieje.
if (-not (Test-Path -LiteralPath $ListaKomputerow -PathType Leaf)) {
    $komunikat = "Brak pliku z listą jednostek: $ListaKomputerow"
    Write-Host $sep
    Write-Host $komunikat
    Write-Log -Komputer '-' -Krok 'lista' -Wynik 'BŁĄD' -Szczegoly $komunikat
    Write-Podsumowanie
    if ($MyInvocation.InvocationName -ne '.') { exit 1 }
    return
}

try {
    $surowe = @(Get-Content -LiteralPath $ListaKomputerow -ErrorAction Stop)
}
catch {
    $komunikat = "Nie można odczytać listy jednostek: {0}" -f $_.Exception.Message
    Write-Host $sep
    Write-Host $komunikat
    Write-Log -Komputer '-' -Krok 'lista' -Wynik 'BŁĄD' -Szczegoly (($_ | Out-String).TrimEnd())
    Write-Podsumowanie
    if ($MyInvocation.InvocationName -ne '.') { exit 1 }
    return
}


#Puste wiersze i komentarze nie są nazwami jednostek.
$nazwy = @(
    $surowe | ForEach-Object {
        $linia = $_.Trim()
        if ($linia -and -not $linia.StartsWith('#')) { $linia }
    }
)

$literaDysku = $Sciezka.Substring(0, 1)
$resztaSciezki = $Sciezka.Substring(3)

Write-Host $sep
Write-Host "Lista:   $ListaKomputerow"
Write-Host "Ścieżka: $Sciezka"
Write-Host "Udział:  \\<jednostka>\$literaDysku`$\$resztaSciezki"
Write-Host "Log:     $log"
Write-Host ("Jednostek do przetworzenia: {0}" -f $nazwy.Count)
Write-Host $sep
Write-Log -Komputer '-' -Krok 'start' -Wynik 'INFO' -Szczegoly ("Lista: {0}; ścieżka: {1}; jednostek: {2}" -f $ListaKomputerow, $Sciezka, $nazwy.Count)

if ($nazwy.Count -eq 0) {
    $komunikat = 'Lista jednostek jest pusta (po pominięciu pustych wierszy i komentarzy). Nic nie wykonano.'
    Write-Host $komunikat
    Write-Log -Komputer '-' -Krok 'lista' -Wynik 'BŁĄD' -Szczegoly $komunikat
    Write-Podsumowanie
    if ($MyInvocation.InvocationName -ne '.') { exit 1 }
    return
}


#Kolejno każda jednostka. Błąd jednej nie przerywa listy.
$i = 0
foreach ($nazwa in $nazwy) {
    $i++
    $postep = '[{0}/{1}]' -f $i, $nazwy.Count
    Write-Host ''
    Write-Host $sep
    Write-Host "$postep $nazwa"
    Write-Host $sep

    #Nazwa z ukośnikiem zmieniłaby udział, na który trafia usuwanie.
    if ($nazwa -match '[\\/]') {
        $komunikat = "Nazwa jednostki zawiera ukośnik: $nazwa"
        Write-Host "$postep $nazwa | udział | BŁĄD | $komunikat"
        Write-Host "$postep $nazwa | wynik jednostki | BŁĄD"
        Write-Log -Komputer $nazwa -Krok 'udział' -Wynik 'BŁĄD' -Szczegoly $komunikat
        $blednie++
        continue
    }

    $udzial = '\\{0}\{1}$' -f $nazwa, $literaDysku
    $unc = '{0}\{1}' -f $udzial, $resztaSciezki
    Write-Host "$postep $nazwa | w toku | $unc"
    Write-Log -Komputer $nazwa -Krok 'start jednostki' -Wynik 'INFO' -Szczegoly $unc

    #Najpierw sam udział, żeby brak pliku nie był mylony z niedostępną jednostką.
    $udzialJest = $false
    try {
        $udzialJest = Test-Path -LiteralPath $udzial -ErrorAction Stop
    }
    catch {
        $krotko = ($_.Exception.Message -replace '\s+', ' ').Trim()
        $szczegoly = ($_ | Out-String).TrimEnd()
        Write-Host "$postep $nazwa | udział | BŁĄD | $krotko"
        Write-Host "$postep $nazwa | wynik jednostki | BŁĄD"
        Write-Log -Komputer $nazwa -Krok 'udział' -Wynik 'BŁĄD' -Szczegoly $szczegoly
        $blednie++
        continue
    }

    if (-not $udzialJest) {
        $komunikat = "Udział administracyjny jest niedostępny: $udzial"
        Write-Host "$postep $nazwa | udział | BŁĄD | $komunikat"
        Write-Host "$postep $nazwa | wynik jednostki | BŁĄD"
        Write-Log -Komputer $nazwa -Krok 'udział' -Wynik 'BŁĄD' -Szczegoly $komunikat
        $blednie++
        continue
    }

    $element = $null
    try {
        $element = Get-Item -LiteralPath $unc -Force -ErrorAction Stop
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        $komunikat = "Na jednostce nie ma obiektu: $Sciezka"
        Write-Host "$postep $nazwa | usuwanie | $Sciezka | BŁĄD | $komunikat"
        Write-Host "$postep $nazwa | wynik jednostki | BŁĄD"
        Write-Log -Komputer $nazwa -Krok 'usuwanie' -Wynik 'BŁĄD' -Szczegoly $komunikat
        $blednie++
        continue
    }
    catch {
        $krotko = ($_.Exception.Message -replace '\s+', ' ').Trim()
        $szczegoly = ($_ | Out-String).TrimEnd()
        Write-Host "$postep $nazwa | usuwanie | $Sciezka | BŁĄD | $krotko"
        Write-Host "$postep $nazwa | wynik jednostki | BŁĄD"
        Write-Log -Komputer $nazwa -Krok 'usuwanie' -Wynik 'BŁĄD' -Szczegoly $szczegoly
        $blednie++
        continue
    }

    $typ = if ($element.PSIsContainer) { 'katalog' } else { 'plik' }
    if (($element.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        $typ = "$typ (łącze)"
    }

    try {
        #Katalog wymaga -Recurse. -Force usuwa też plik ukryty i tylko do odczytu.
        if ($element.PSIsContainer) {
            Remove-Item -LiteralPath $element.FullName -Recurse -Force -ErrorAction Stop
        }
        else {
            Remove-Item -LiteralPath $element.FullName -Force -ErrorAction Stop
        }

        if (Test-Path -LiteralPath $unc -ErrorAction Stop) {
            $komunikat = "Polecenie usuwania nie zgłosiło błędu, ale obiekt nadal istnieje: $Sciezka"
            Write-Host "$postep $nazwa | usuwanie | $typ | $Sciezka | BŁĄD | $komunikat"
            Write-Host "$postep $nazwa | wynik jednostki | BŁĄD"
            Write-Log -Komputer $nazwa -Krok 'usuwanie' -Wynik 'BŁĄD' -Szczegoly ("typ={0}`r`n{1}" -f $typ, $komunikat)
            $blednie++
            continue
        }

        $komunikat = "Usunięto ${typ}: $unc"
        Write-Host "$postep $nazwa | usuwanie | $typ | $Sciezka | OK"
        Write-Host "$postep $nazwa | wynik jednostki | OK"
        Write-Log -Komputer $nazwa -Krok 'usuwanie' -Wynik 'OK' -Szczegoly ("typ={0}`r`n{1}" -f $typ, $komunikat)
        $poprawnie++
    }
    catch {
        $tekstBledu = $_.Exception.Message
        if ($_.Exception.InnerException) {
            $tekstBledu = $_.Exception.InnerException.Message
        }
        $krotko = ($tekstBledu -replace '\s+', ' ').Trim()
        Write-Host "$postep $nazwa | usuwanie | $typ | $Sciezka | BŁĄD | $krotko"
        Write-Host "$postep $nazwa | wynik jednostki | BŁĄD"
        Write-Log -Komputer $nazwa -Krok 'usuwanie' -Wynik 'BŁĄD' -Szczegoly ("typ={0}`r`n{1}" -f $typ, $tekstBledu)
        $blednie++
    }
}


#Podsumowanie po całej liście. Kod 0 tylko przy zerze błędów.
Write-Podsumowanie
if ($blednie -eq 0) {
    if ($MyInvocation.InvocationName -ne '.') { exit 0 }
    return
}

if ($MyInvocation.InvocationName -ne '.') { exit 1 }
