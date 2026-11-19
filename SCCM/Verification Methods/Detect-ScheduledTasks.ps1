<#
Metoda wykrywania aplikacji SCCM dla Remove-ScheduledTasks.ps1.
Skrypt niczego nie usuwa. Wklej go w typie wdrożenia jako skrypt
PowerShell metody wykrywania. Program instalacji to Remove-ScheduledTasks.ps1.

Lista $NazwyZadan ma być taka sama jak w skrypcie usuwającym.
Kolejną nazwę dopisuje się jako następny element tablicy.

Wynik czyta klient według Microsoft Learn, Create applications,
„About custom script detection methods”:
- Żadnej nazwy z listy nie ma: jeden wiersz na STDOUT, STDERR puste, kod 0.
  Stan aplikacji: Installed. Wdrożenie jest już wykonane.
- Którakolwiek nazwa nadal jest: STDOUT puste, STDERR puste, kod 0.
  Stan aplikacji: Not installed. Klient uruchamia program instalacji.
- Zła lista albo błąd odczytu Harmonogramu: kod inny niż 0.
  Stan aplikacji: Unknown.

Na STDOUT sukcesu jest dokładnie jeden wiersz. Write-Host i Write-Error
przy kodzie 0 zmieniają ten wynik, więc przy „nadal jest” skrypt milczy.
Ostrzeżenia są wyciszone, bo niepuste STDERR przy kodzie 0 daje Unknown.

Gdy wykrywanie wystartuje jako proces 32-bitowy, skrypt przechodzi na
%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe i oddaje
jego STDOUT oraz kod wyjścia. W typie wdrożenia pole „Uruchom skrypt
jako proces 32-bitowy na klientach 64-bitowych” może zostać wyłączone.
#>

<#
Sześć nazw startowych, te same co w Remove-ScheduledTasks.ps1.
Zostawiony wpis TU-WPISZ-NAZWĘ-ZADANIA-<numer> kończy wykrywanie kodem 1.
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
32-bitowy proces na 64-bitowym systemie oddaje wykrywanie procesowi 64-bitowemu.
Sysnative istnieje tylko dla procesu 32-bitowego i wskazuje prawdziwy System32.
#>
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Write-Output 'Uruchom skrypt z pliku (powershell.exe -File).'
        exit 1
    }

    $powershell64 = Join-Path $env:WinDir 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell64)) {
        Write-Output "Brak 64-bitowego powershell.exe: $powershell64"
        exit 1
    }

    try {
        & $powershell64 -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath
        $kod64 = $LASTEXITCODE
    }
    catch {
        Write-Output ("Nie udało się uruchomić 64-bitowego PowerShell: {0}" -f $_.Exception.Message)
        exit 1
    }

    if ($null -eq $kod64) {
        exit 1
    }

    exit $kod64
}

<#
Strumienie inne niż STDOUT nie mogą nieść tekstu przy kodzie 0.
#>
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

function Stop-Wykrywanie {
    param([string]$Komunikat)

    Write-Output $Komunikat
    exit 1
}

<#
Ta sama walidacja nazw co przy usuwaniu. Zła lista nie może wyglądać
jak wykrycie zakończone sukcesem.
#>
$problemy = @()
$doSprawdzenia = @()

foreach ($surowa in @($NazwyZadan)) {
    $nazwa = ''
    if ($null -ne $surowa) {
        $nazwa = $surowa.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($nazwa)) {
        continue
    }

    if ($nazwa.Contains('*') -or $nazwa.Contains('?')) {
        $problemy += "Nazwa zawiera symbol wieloznaczny: $nazwa"
        continue
    }

    if ($nazwa.Contains('\')) {
        $problemy += "Nazwa zawiera ścieżkę. Podaj samą nazwę zadania: $nazwa"
        continue
    }

    if ($nazwa -match '^TU-WPISZ-NAZWĘ-ZADANIA-\d+$') {
        $problemy += "Na liście został szablon: $nazwa"
        continue
    }

    if ($doSprawdzenia -notcontains $nazwa) {
        $doSprawdzenia += $nazwa
    }
}

if ($problemy.Count -gt 0) {
    Stop-Wykrywanie (($problemy -join ' '))
}

if ($doSprawdzenia.Count -eq 0) {
    Stop-Wykrywanie 'Lista nazw jest pusta.'
}

<#
Klient SCCM uruchamia wykrywanie jako SYSTEM. Bez podniesionego tokenu
część zadań może być niewidoczna i dać fałszywe „wykonane poprawnie”.
#>
$tozsamosc = [Security.Principal.WindowsIdentity]::GetCurrent()
$konto = New-Object Security.Principal.WindowsPrincipal($tozsamosc)
if (-not $konto.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Stop-Wykrywanie 'Wykrywanie wymaga podniesionych uprawnień (klient SCCM jako SYSTEM).'
}

try {
    Import-Module ScheduledTasks -ErrorAction Stop
    $katalog = @(Get-ScheduledTask -ErrorAction Stop)
}
catch {
    Stop-Wykrywanie ("Nie odczytano Harmonogramu zadań: {0}" -f $_.Exception.Message)
}

<#
Jedno trafienie wystarcza, żeby nie zgłaszać wykonania. Brak każdego
wpisu z listy daje jeden wiersz STDOUT i kod 0.
#>
foreach ($nazwa in $doSprawdzenia) {
    $jest = @($katalog | Where-Object { $_.TaskName -eq $nazwa })
    if ($jest.Count -gt 0) {
        exit 0
    }
}

Write-Output 'Wykonane poprawnie'
exit 0
