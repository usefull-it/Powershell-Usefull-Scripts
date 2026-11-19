<#
Odłącza jednostki od Microsoft Entra ID i odświeża zasady grupy komputera.

Uruchomienie:
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Remote-DisconnectEntraID.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Remote-DisconnectEntraID.ps1" -ListaKomputerow "D:\lista\komputery.txt"

Domyślna lista: komputery.txt obok tego skryptu. Jedna nazwa jednostki w wierszu.
Puste wiersze i wiersze zaczynające się od # (po obcięciu spacji) są pomijane.

Konto operatora musi mieć prawa administratora na jednostkach z dostępem do WinRM.
W domenie wystarcza Kerberos (standardowe PSRemoting), dlatego nie używamy parametru -Credential.
dsregcmd /leave wymaga podniesienia uprawnień na jednostce docelowej — daje je zdalna sesja administratora.
Klient WinRM nie wymaga podniesienia uprawnień na maszynie operatora, stąd brak parametru -RunAsAdministrator.
Oba polecenia uruchamia zdalna sesja. Katalog wybiera bitowość tej sesji: proces 64-bitowy używa System32, a proces 32-bitowy na 64-bitowym Windows używa Sysnative, bo inaczej WOW64 podmienia System32 na SysWOW64 i nie znajduje dsregcmd.exe.

Pomoc dsregcmd opisuje "/leave" jako "Performs Hybrid Unjoin". Na jednostce hybrydowej zadanie
Automatic-Device-Join może zarejestrować ją ponownie po restarcie i logowaniu domenowym.
Skrypt nie restartuje jednostek i nie wyłącza tego zadania. Kod wyjścia procesu: 0 tylko gdy
każda jednostka z listy przeszła oba kroki; w pozostałych przypadkach 1.
#>


[CmdletBinding()]
param(
    #Pusta wartość oznacza komputery.txt obok skryptu.
    [string]$ListaKomputerow
)

if ([string]::IsNullOrWhiteSpace($ListaKomputerow)) {
    $ListaKomputerow = Join-Path $PSScriptRoot 'komputery.txt'
}


$ProgressPreference = 'SilentlyContinue'
$poprawnie = 0
$blednie = 0
$log = Join-Path $PSScriptRoot ('Odlacz-Entra-Gpupdate_{0:yyyyMMdd_HHmmss_fff}.log' -f (Get-Date))
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


#Funkcja wyświetlająca podsumowanie wyników.
function Write-Podsumowanie {
    Write-Host ''
    Write-Host $sep
    Write-Host 'Podsumowanie'
    Write-Host ("Poprawnie: {0}" -f $poprawnie)
    Write-Host ("Błędnie:   {0}" -f $blednie)
    Write-Host "Log:       $log"
    Write-Host $sep
    Write-Log -Komputer '-' -Krok 'podsumowanie' -Wynik 'INFO' -Szczegoly ("Poprawnie: {0}; Błędnie: {1}" -f $poprawnie, $blednie)
}


function Invoke-PolecenieSystemowe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Komputer,

        [Parameter(Mandatory = $true)]
        [string]$NazwaPliku,

        [Parameter(Mandatory = $true)]
        [string[]]$Argumenty
    )

    Invoke-Command -ComputerName $Komputer -ErrorAction Stop -ArgumentList $NazwaPliku, $Argumenty -ScriptBlock {
        param(
            [string]$NazwaPliku,
            [string[]]$Argumenty
        )

        $ErrorActionPreference = 'Continue'

        function Get-KatalogSystemowy {
            <#
            Proces 32-bitowy na 64-bitowym Windows widzi System32 jako SysWOW64.
            dsregcmd.exe jest tylko w prawdziwym System32. Sysnative omija to przekierowanie
            i jest widoczny wyłącznie z procesu 32-bitowego, dlatego proces 64-bitowy zostaje przy System32.
            #>
            if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
                return (Join-Path $env:SystemRoot 'Sysnative')
            }

            return (Join-Path $env:SystemRoot 'System32')
        }

        $exe = Join-Path (Get-KatalogSystemowy) $NazwaPliku

        if (-not (Test-Path -LiteralPath $exe)) {
            return [pscustomobject]@{ ExitCode = 1; Output = "Brak pliku: $exe" }
        }

        $Argumenty = @($Argumenty)
        $linie = & $exe @Argumenty 2>&1

        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = (($linie | Out-String).TrimEnd())
        }
    }
}


#Sprawdzanie, czy plik z listą jednostek istnieje.
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


#Filtrujemy listę jednostek, pomijając puste wiersze i wiersze zaczynające się od # (po obcięciu spacji).
$nazwy = @(
    $surowe | ForEach-Object {
        $linia = $_.Trim()
        if ($linia -and -not $linia.StartsWith('#')) { $linia }
    }
)


Write-Host $sep
Write-Host "Lista: $ListaKomputerow"
Write-Host "Log:   $log"
Write-Host ("Jednostek do przetworzenia: {0}" -f $nazwy.Count)
Write-Host $sep
Write-Log -Komputer '-' -Krok 'start' -Wynik 'INFO' -Szczegoly ("Lista: {0}; jednostek: {1}" -f $ListaKomputerow, $nazwy.Count)


#Sprawdzanie, czy lista jednostek jest pusta.
if ($nazwy.Count -eq 0) {
    $komunikat = 'Lista jednostek jest pusta (po pominięciu pustych wierszy i komentarzy). Nic nie wykonano.'
    Write-Host $komunikat
    Write-Log -Komputer '-' -Krok 'lista' -Wynik 'BŁĄD' -Szczegoly $komunikat
    Write-Podsumowanie
    if ($MyInvocation.InvocationName -ne '.') { exit 1 }
    return
}

#Pętla przetwarzania jednostek z listy.
$i = 0
foreach ($nazwa in $nazwy) {
    $i++
    $postep = '[{0}/{1}]' -f $i, $nazwy.Count
    Write-Host ''
    Write-Host $sep
    Write-Host "$postep $nazwa"
    Write-Host $sep


    $leave = $null
    try {
        #Wywołanie dsregcmd /leave z sesją zdalną administratora.
        $leave = Invoke-PolecenieSystemowe -Komputer $nazwa -NazwaPliku 'dsregcmd.exe' -Argumenty @('/leave')
    }
    catch {
        $szczegoly = ($_ | Out-String).TrimEnd()
        Write-Host "$postep $nazwa | krok 1/2 | dsregcmd /leave | BŁĄD | $($_.Exception.Message)"
        Write-Host "$postep $nazwa | krok 2/2 | gpupdate /target:computer /force | POMINIĘTO"
        Write-Host "$postep $nazwa | wynik jednostki | BŁĄD"
        Write-Log -Komputer $nazwa -Krok 'dsregcmd /leave' -Wynik 'BŁĄD' -Szczegoly $szczegoly
        Write-Log -Komputer $nazwa -Krok 'gpupdate /target:computer /force' -Wynik 'POMINIĘTO' -Szczegoly 'Pominięto, bo dsregcmd /leave się nie powiódł.'
        $blednie++
        continue
    }


    if ($null -eq $leave) {
        $kodLeave = $null
        $tekstLeave = 'Brak wyniku z sesji zdalnej.'
    }
    else {
        $kodLeave = $leave.ExitCode
        $tekstLeave = [string]$leave.Output
    }

    <#
    MS Learn nie podaje kodu wyjścia dsregcmd. Sukces: kod 0 i komunikat z biblioteki dsreg.dll z wersji 10.0.26100 (25H2)
    "Device successfully unjoined from Azure AD." Zdania błędu z tej biblioteki unieważniają wynik.
    #>

    $leaveOk = ($kodLeave -eq 0) -and ($tekstLeave -match 'Device successfully unjoined from Azure AD')
    if ($tekstLeave -match 'unjoin from Azure AD failed|must be run in elevated context|administrative privileges|Leave failed with') {
        $leaveOk = $false
    }

    #Sprawdzanie, czy dsregcmd /leave się powiódł.
    if ($leaveOk) {
        Write-Host "$postep $nazwa | krok 1/2 | dsregcmd /leave | OK"
        Write-Log -Komputer $nazwa -Krok 'dsregcmd /leave' -Wynik 'OK' -Szczegoly ("kod={0}`r`n{1}" -f $kodLeave, $tekstLeave)
    }
    else {
        Write-Host "$postep $nazwa | krok 1/2 | dsregcmd /leave | BŁĄD"
        Write-Host "$postep $nazwa | krok 2/2 | gpupdate /target:computer /force | POMINIĘTO"
        Write-Host "$postep $nazwa | wynik jednostki | BŁĄD"
        Write-Log -Komputer $nazwa -Krok 'dsregcmd /leave' -Wynik 'BŁĄD' -Szczegoly ("kod={0}`r`n{1}" -f $kodLeave, $tekstLeave)
        Write-Log -Komputer $nazwa -Krok 'gpupdate /target:computer /force' -Wynik 'POMINIĘTO' -Szczegoly 'Pominięto, bo dsregcmd /leave się nie powiódł.'
        $blednie++
        continue
    }


    $gp = $null
    try {
        #Wywołanie gpupdate /target:computer /force z sesją zdalną administratora.
        $gp = Invoke-PolecenieSystemowe -Komputer $nazwa -NazwaPliku 'gpupdate.exe' -Argumenty @('/target:computer', '/force')
    }


    catch {
        #Sprawdzanie, czy gpupdate /target:computer /force się powiódł.
        $szczegoly = ($_ | Out-String).TrimEnd()
        Write-Host "$postep $nazwa | krok 2/2 | gpupdate /target:computer /force | BŁĄD | $($_.Exception.Message)"
        Write-Host "$postep $nazwa | wynik jednostki | BŁĄD"
        Write-Log -Komputer $nazwa -Krok 'gpupdate /target:computer /force' -Wynik 'BŁĄD' -Szczegoly $szczegoly
        $blednie++
        continue
    }


    if ($null -eq $gp) {
        $kodGp = $null
        $tekstGp = 'Brak wyniku z sesji zdalnej.'
    }
    else {
        $kodGp = $gp.ExitCode
        $tekstGp = [string]$gp.Output
    }

    <#
    MS Learn nie podaje kodu wyjścia gpupdate. Sukces: kod 0 i brak zdań błędów z angielskiej wersji gpupdate.exe.mui.
    Typowy tekst sukcesu to "Computer Policy update has completed successfully.", ale na
    zlokalizowanym systemie może go nie być, dlatego skrypt go nie wymaga.
    #>

    $gpFail = $tekstGp -match 'could not be updated successfully|Computer Policy update has not completed|Computer Policy Update Failed|Failed to update policy|Access Denied\. Administrator permissions'
    $gpOk = ($kodGp -eq 0) -and -not $gpFail

    if ($gpOk) {
        Write-Host "$postep $nazwa | krok 2/2 | gpupdate /target:computer /force | OK"
        Write-Host "$postep $nazwa | wynik jednostki | OK"
        Write-Log -Komputer $nazwa -Krok 'gpupdate /target:computer /force' -Wynik 'OK' -Szczegoly ("kod={0}`r`n{1}" -f $kodGp, $tekstGp)
        $poprawnie++
    }
    else {
        Write-Host "$postep $nazwa | krok 2/2 | gpupdate /target:computer /force | BŁĄD"
        Write-Host "$postep $nazwa | wynik jednostki | BŁĄD"
        Write-Log -Komputer $nazwa -Krok 'gpupdate /target:computer /force' -Wynik 'BŁĄD' -Szczegoly ("kod={0}`r`n{1}" -f $kodGp, $tekstGp)
        $blednie++
    }
}


#Wyświetlenie podsumowania wyników.
Write-Podsumowanie
if ($blednie -eq 0) {
    if ($MyInvocation.InvocationName -ne '.') { exit 0 }
    return
}

if ($MyInvocation.InvocationName -ne '.') { exit 1 }
