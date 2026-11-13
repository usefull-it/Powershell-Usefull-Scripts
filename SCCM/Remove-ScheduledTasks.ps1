<#
Usuwa lokalne zadania Harmonogramu zadań o nazwach zdefiniowanych w tablicy $NazwyZadan.
Skrypt jest przeznaczony do programu pakietu SCCM uruchamianego na kliencie
(domyślnie jako SYSTEM).

Uruchomienie programu pakietu:
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ".\Remove-ScheduledTasks.ps1"

Na 64-bitowym Windowsie klient SCCM startuje 32-bitowy powershell.exe.
Skrypt przełącza się wtedy na %SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe
i kończy się kodem wyjścia tego procesu.

Nazwy do usunięcia są w tablicy $NazwyZadan. Domyślnie jest ich 6.
Kolejną nazwę dopisuje się jako następny element tablicy. Wartości
TU-WPISZ-NAZWĘ-ZADANIA-1 … 6 są szablonem: dopóki któraś zostanie,
skrypt nic nie usuwa i kończy się kodem 1.

Porównanie nazwy jest dokładne i nie rozróżnia wielkości liter.
Ta sama nazwa w kilku folderach Harmonogramu oznacza każde z tych zadań.
Znaków * ? oraz znaku \ w nazwie skrypt nie przyjmuje. \ oddziela folder
od nazwy, a * w -TaskName jest zapytaniem wieloznacznym (Microsoft Learn,
Get-ScheduledTask, parametr -TaskName).

Brak zadania o podanej nazwie jest sukcesem. Ponowne wdrożenie pakietu
na komputerze, z którego zadanie już zniknęło, też kończy się kodem 0.
Kod 1 oznacza błąd konfiguracji, brak uprawnień albo zadanie, które
po próbie usunięcia nadal jest w Harmonogramie.

Usuwana jest rejestracja zadania. Plik, który zadanie uruchamiało,
zostaje. Działający już proces zadania nie jest zatrzymywany.
Pusty folder Harmonogramu może zostać po usunięciu ostatniego zadania.

Log: %SystemRoot%\Temp\Remove-ScheduledTasks_rrrrMMdd_ggmmss_fff.log
Kod wyjścia: 0 gdy każda nazwa z listy jest nieobecna po zakończeniu
pracy skryptu. W pozostałych przypadkach kod wyjścia to 1.
#>

#Requires -Version 5.1
<#
Sześć nazw startowych. Dopisz kolejny cudzysłów z nazwą, aby dodać następną.
Zostawiony wpis TU-WPISZ-NAZWĘ-ZADANIA-<numer> blokuje usuwanie.
#>

$NazwyZadan = @(
    'TU-WPISZ-NAZWĘ-ZADANIA-1'
    'TU-WPISZ-NAZWĘ-ZADANIA-2'
    'TU-WPISZ-NAZWĘ-ZADANIA-3'
    'TU-WPISZ-NAZWĘ-ZADANIA-4'
    'TU-WPISZ-NAZWĘ-ZADANIA-5'
    'TU-WPISZ-NAZWĘ-ZADANIA-6'
)

<#
32-bitowy proces na 64-bitowym systemie nie jest procesem, w którym ma iść usuwanie.
Sysnative istnieje tylko dla procesu 32-bitowego i wskazuje prawdziwy System32.
#>

if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Write-Host 'Uruchom skrypt z pliku (powershell.exe -File). Wklejenie do konsoli 32-bitowej nie wyznacza pliku do ponownego uruchomienia.'
        exit 1
    }

    $powershell64 = Join-Path $env:WinDir 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell64)) {
        Write-Host "Brak 64-bitowego powershell.exe: $powershell64"
        exit 1
    }

    # Kod wyjścia i tekst logu wracają do procesu, który uruchomił program pakietu.
    try {
        & $powershell64 -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath
        $kod64 = $LASTEXITCODE
    }
    catch {
        Write-Host ("Nie udało się uruchomić 64-bitowego PowerShell: {0}" -f $_.Exception.Message)
        exit 1
    }

    if ($null -eq $kod64) {
        exit 1
    }

    exit $kod64
}


$ConfirmPreference = 'None'
$ProgressPreference = 'SilentlyContinue'

$log = Join-Path $env:SystemRoot ('Temp\Remove-ScheduledTasks_{0:yyyyMMdd_HHmmss_fff}.log' -f (Get-Date))


# Zapis do konsoli i do logu UTF-8 bez BOM.
function Write-Wpis {
    param(
        [string]$Nazwa,
        [string]$Wynik,
        [string]$Szczegoly
    )

    $wiersze = @(
        ('{0:yyyy-MM-dd HH:mm:ss} | {1} | {2}' -f (Get-Date), $Nazwa, $Wynik)
    )
    if ($Szczegoly) {
        $wiersze += $Szczegoly.TrimEnd()
    }

    $tekstHost = $wiersze -join [Environment]::NewLine
    Write-Host $tekstHost
    $tekst = $tekstHost + [Environment]::NewLine + ('-' * 40) + [Environment]::NewLine
    [System.IO.File]::AppendAllText($log, $tekst, (New-Object System.Text.UTF8Encoding $false))
}


function Exit-ZWynikiem {
    param([int]$Kod)

    Write-Wpis -Nazwa '-' -Wynik 'Koniec' -Szczegoly ("Kod wyjścia: {0}`r`nLog: {1}" -f $Kod, $log)
    exit $Kod
}


function Test-ZadanieIstnieje {
    param(
        [string]$Nazwa,
        [string]$Sciezka
    )

    try {
        $znalezione = @(Get-ScheduledTask -TaskName $Nazwa -TaskPath $Sciezka -ErrorAction Stop)
        return ($znalezione.Count -gt 0)
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'CmdletizationQuery_NotFound*') {
            return $false
        }

        throw
    }
}


Write-Wpis -Nazwa '-' -Wynik 'Start' -Szczegoly ("Komputer: {0}`r`nProces 64-bit: {1}" -f $env:COMPUTERNAME, [Environment]::Is64BitProcess)

# Odrzucenie szablonu, symboli wieloznacznych i ścieżek, zanim cokolwiek zostanie usunięte.
$problemy = @()
$doUsuniecia = @()

foreach ($surowa in @($NazwyZadan)) {
    $nazwa = ''
    if ($null -ne $surowa) {
        $nazwa = $surowa.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($nazwa)) {
        Write-Wpis -Nazwa '-' -Wynik 'Pominięto' -Szczegoly 'Pusty element listy nazw.'
        continue
    }

    if ($nazwa.Contains('*') -or $nazwa.Contains('?')) {
        $problemy += "Nazwa zawiera symbol wieloznaczny i nie zostanie użyta: $nazwa"
        continue
    }

    if ($nazwa.Contains('\')) {
        $problemy += "Nazwa zawiera ścieżkę. Podaj samą nazwę zadania, bez folderu: $nazwa"
        continue
    }

    if ($nazwa -match '^TU-WPISZ-NAZWĘ-ZADANIA-\d+$') {
        $problemy += "Na liście został szablon. Wpisz rzeczywistą nazwę zamiast: $nazwa"
        continue
    }

    if ($doUsuniecia -notcontains $nazwa) {
        $doUsuniecia += $nazwa
    }
}

if ($problemy.Count -gt 0) {
    foreach ($problem in $problemy) {
        Write-Wpis -Nazwa '-' -Wynik 'Błąd' -Szczegoly $problem
    }
    Exit-ZWynikiem 1
}

if ($doUsuniecia.Count -eq 0) {
    Write-Wpis -Nazwa '-' -Wynik 'Błąd' -Szczegoly 'Lista nazw jest pusta. Nic nie usunięto.'
    Exit-ZWynikiem 1
}


$tozsamosc = [Security.Principal.WindowsIdentity]::GetCurrent()
$konto = New-Object Security.Principal.WindowsPrincipal($tozsamosc)
if (-not $konto.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Wpis -Nazwa '-' -Wynik 'Błąd' -Szczegoly 'Skrypt wymaga uruchomienia z podniesionymi uprawnieniami (program pakietu SCCM jako SYSTEM albo administrator). Nic nie usunięto.'
    Exit-ZWynikiem 1
}

try {
    Import-Module ScheduledTasks -ErrorAction Stop
}
catch {
    Write-Wpis -Nazwa '-' -Wynik 'Błąd' -Szczegoly ("Nie załadowano modułu ScheduledTasks: {0}" -f $_.Exception.Message)
    Exit-ZWynikiem 1
}

# Pełna lista obejmuje podfoldery. Dalej zostają tylko nazwy równe wpisom z tablicy.
try {
    $katalog = @(Get-ScheduledTask -ErrorAction Stop)
}
catch {
    Write-Wpis -Nazwa '-' -Wynik 'Błąd' -Szczegoly ("Nie odczytano Harmonogramu zadań: {0}" -f $_.Exception.Message)
    Exit-ZWynikiem 1
}

$usuniete = 0
$brak = 0
$bledy = 0

foreach ($nazwa in $doUsuniecia) {
    $dopasowane = @($katalog | Where-Object { $_.TaskName -eq $nazwa })

    if ($dopasowane.Count -eq 0) {
        $brak++
        Write-Wpis -Nazwa $nazwa -Wynik 'Brak' -Szczegoly 'Zadania o tej nazwie nie ma. Stan docelowy jest już spełniony.'
        continue
    }

    foreach ($zadanie in $dopasowane) {
        $opis = '{0}{1}' -f $zadanie.TaskPath, $zadanie.TaskName
        $opisBledu = ''

        try {
            Unregister-ScheduledTask -TaskName $zadanie.TaskName -TaskPath $zadanie.TaskPath -Confirm:$false -ErrorAction Stop
        }
        catch {
            $opisBledu = $_.Exception.Message
        }

        # Skutek sprawdza ponowne zapytanie, nie sam brak wyjątku z Unregister-ScheduledTask.
        try {
            $nadalJest = Test-ZadanieIstnieje -Nazwa $zadanie.TaskName -Sciezka $zadanie.TaskPath
        }
        catch {
            $bledy++
            $szczegolyWeryfikacji = $_.Exception.Message
            if ($opisBledu) {
                $szczegolyWeryfikacji = $opisBledu + [Environment]::NewLine + $szczegolyWeryfikacji
            }
            Write-Wpis -Nazwa $opis -Wynik 'Błąd' -Szczegoly ("Nie udało się sprawdzić, czy zadanie zniknęło.`r`n{0}" -f $szczegolyWeryfikacji)
            continue
        }

        if ($nadalJest) {
            $bledy++
            if (-not $opisBledu) {
                $opisBledu = 'Po Unregister-ScheduledTask zadanie nadal jest w Harmonogramie.'
            }
            Write-Wpis -Nazwa $opis -Wynik 'Błąd' -Szczegoly $opisBledu
            continue
        }

        $usuniete++
        $dopisek = "Usunięto: $opis"
        if ($opisBledu) {
            $dopisek = $dopisek + [Environment]::NewLine + "Unregister-ScheduledTask zgłosił wyjątek, ale ponowne zapytanie nie znalazło zadania.`r`n$opisBledu"
        }
        Write-Wpis -Nazwa $opis -Wynik 'Usunięto' -Szczegoly $dopisek
    }
}

$podsumowanie = @(
    ("Usunięte obiekty zadań: {0}" -f $usuniete)
    ("Nazwy, których już nie było: {0}" -f $brak)
    ("Błędy: {0}" -f $bledy)
) -join [Environment]::NewLine

Write-Wpis -Nazwa '-' -Wynik 'Podsumowanie' -Szczegoly $podsumowanie

if ($bledy -gt 0) {
    Exit-ZWynikiem 1
}

Exit-ZWynikiem 0
