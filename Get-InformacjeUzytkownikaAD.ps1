<#
Skrypt pyta administratora o użytkownika domeny i pokazuje osobno, czy konto
jest włączone oraz czy jest zablokowane po błędnych hasłach, a potem ograniczony
zestaw właściwości.

Get-ADUser -Identity przyjmuje nazwę wyróżniającą (DN), GUID (objectGUID),
SID (objectSid) albo SamAccountName (sAMAccountName). UPN nie jest poprawnym
identyfikatorem -Identity, więc wpis ze znakiem @ i bez znaku = jest szukany
filtrem UserPrincipalName -eq.

Czas blokady to właściwość AccountLockoutTime. W modelu modułu jest to czas
lokalny wyprowadzony z atrybutu LDAP lockoutTime. PasswordLastSet też jest
czasem lokalnym (atrybut pwdLastSet). LastLogonDate pochodzi z lastLogonTimestamp
i nie jest replikowane na każdy kontroler domeny.

Ścieżka OU nie zawiera pierwszego składnika DN (CN konta) ani składników DC.
Zostają OU oraz CN kontenerów, od najwyższego do najbliższego kontu,
rozdzielone " / ".
#>

$WlasciwosciUzytkownika = @(
    'Enabled'
    'LockedOut'
    'AccountLockoutTime'
    'PasswordLastSet'
    'PasswordExpired'
    'PasswordNeverExpires'
    'DisplayName'
    'GivenName'
    'Surname'
    'SamAccountName'
    'UserPrincipalName'
    'EmailAddress'
    'OfficePhone'
    'MobilePhone'
    'Department'
    'Title'
    'Manager'
    'DistinguishedName'
    'LastLogonDate'
)

function Format-DataLokalna {
    param(
        $Data,
        [string]$GdyBrak
    )
    if ($null -eq $Data) {
        if ([string]::IsNullOrEmpty($GdyBrak)) {
            return $null
        }
        return $GdyBrak
    }
    return ([datetime]$Data).ToString('yyyy-MM-dd HH:mm:ss')
}

function Format-TakNie {
    param([bool]$Wartosc)
    if ($Wartosc) {
        return 'Tak'
    }
    return 'Nie'
}

function Format-StatusWlaczenia {
    param($Enabled)
    if ($Enabled -eq $true) {
        return 'Tak (konto włączone)'
    }
    return 'Nie (konto wyłączone)'
}

function Format-StatusBlokady {
    param($LockedOut)
    if ($LockedOut -eq $true) {
        return 'Tak (konto zablokowane)'
    }
    return 'Nie (konto niezablokowane)'
}

function Format-LiniaStatusu {
    param(
        [string]$Etykieta,
        [string]$Wartosc
    )
    return ('{0} {1}' -f $Etykieta.PadRight(24), $Wartosc)
}

function Format-Pole {
    param($Wartosc)
    if ($null -eq $Wartosc) {
        return '(brak)'
    }
    $tekst = ([string]$Wartosc).Trim()
    if ($tekst.Length -eq 0) {
        return '(brak)'
    }
    return $tekst
}

function ConvertTo-SciezkaOu {
    param([string]$DistinguishedName)
    if ([string]::IsNullOrWhiteSpace($DistinguishedName)) {
        return '(brak)'
    }

    $czesci = [regex]::Split($DistinguishedName, '(?<!\\),')
    $nazwy = @()
    for ($i = 1; $i -lt $czesci.Count; $i++) {
        $fragment = [regex]::Replace($czesci[$i].Trim(), '\\(.)', '$1')
        if ($fragment -match '^(?i)DC=') {
            continue
        }
        if ($fragment -match '^(?i)(?:OU|CN)=(.+)$') {
            $nazwy += $Matches[1]
        }
    }

    if ($nazwy.Count -eq 0) {
        return '(brak)'
    }

    [array]::Reverse($nazwy)
    return ($nazwy -join ' / ')
}

function Test-Kontynuacja {
    param([string]$Odpowiedz)
    if ([string]::IsNullOrWhiteSpace($Odpowiedz)) {
        return $false
    }
    return $Odpowiedz.Trim() -eq 'T'
}

function Format-Ramka {
    param(
        [string]$Tytul,
        [string[]]$Linie
    )
    $sep = '=' * 60
    $wiersze = @($sep, $Tytul, $sep, '')
    foreach ($linia in $Linie) {
        $wiersze += $linia
    }
    $wiersze += ''
    $wiersze += $sep
    return ($wiersze -join [Environment]::NewLine)
}

function Get-KomunikatBrakuModulu {
    param(
        $DostepnyModul = (Get-Module -ListAvailable -Name ActiveDirectory)
    )

    $brak = $false
    if ($null -eq $DostepnyModul) {
        $brak = $true
    }
    elseif ($DostepnyModul -is [System.Array] -and $DostepnyModul.Count -eq 0) {
        $brak = $true
    }

    if (-not $brak) {
        return $null
    }

    return Format-Ramka -Tytul 'Brak modułu ActiveDirectory' -Linie @(
        'Na tym komputerze nie znaleziono modułu ActiveDirectory.'
        'Zainstaluj narzędzia administracji zdalnej RSAT (Remote Server Administration Tools)'
        'z modułem ActiveDirectory i uruchom skrypt ponownie.'
    )
}

function Write-InformacjeKonta {
    param($Konto)

    Write-Host ''
    Write-Host '--- Status konta ---' -ForegroundColor Cyan
    Write-Host (Format-LiniaStatusu -Etykieta 'Konto włączone' -Wartosc (Format-StatusWlaczenia -Enabled $Konto.Enabled))
    Write-Host (Format-LiniaStatusu -Etykieta 'Konto zablokowane' -Wartosc (Format-StatusBlokady -LockedOut $Konto.LockedOut))
    if ($Konto.LockedOut -eq $true) {
        $czasBlokady = Format-DataLokalna -Data $Konto.AccountLockoutTime -GdyBrak 'Czas blokady jest niedostępny'
        Write-Host (Format-LiniaStatusu -Etykieta 'Czas blokady' -Wartosc $czasBlokady)
    }

    $haslo = Format-DataLokalna -Data $Konto.PasswordLastSet -GdyBrak 'Hasło nigdy nie zostało ustawione'
    Write-Host (Format-LiniaStatusu -Etykieta 'Ostatnia zmiana hasła' -Wartosc $haslo)
    Write-Host (Format-LiniaStatusu -Etykieta 'Hasło wygasło' -Wartosc (Format-TakNie -Wartosc ($Konto.PasswordExpired -eq $true)))
    Write-Host (Format-LiniaStatusu -Etykieta 'Hasło bezterminowe' -Wartosc (Format-TakNie -Wartosc ($Konto.PasswordNeverExpires -eq $true)))

    Write-Host ''
    Write-Host '--- Tożsamość ---' -ForegroundColor Cyan
    Write-Host (Format-LiniaStatusu -Etykieta 'Nazwa wyświetlana' -Wartosc (Format-Pole $Konto.DisplayName))
    Write-Host (Format-LiniaStatusu -Etykieta 'Imię' -Wartosc (Format-Pole $Konto.GivenName))
    Write-Host (Format-LiniaStatusu -Etykieta 'Nazwisko' -Wartosc (Format-Pole $Konto.Surname))
    Write-Host (Format-LiniaStatusu -Etykieta 'SamAccountName' -Wartosc (Format-Pole $Konto.SamAccountName))
    Write-Host (Format-LiniaStatusu -Etykieta 'UserPrincipalName' -Wartosc (Format-Pole $Konto.UserPrincipalName))

    Write-Host ''
    Write-Host '--- Kontakt ---' -ForegroundColor Cyan
    Write-Host (Format-LiniaStatusu -Etykieta 'E-mail' -Wartosc (Format-Pole $Konto.EmailAddress))
    Write-Host (Format-LiniaStatusu -Etykieta 'Telefon służbowy' -Wartosc (Format-Pole $Konto.OfficePhone))
    Write-Host (Format-LiniaStatusu -Etykieta 'Telefon komórkowy' -Wartosc (Format-Pole $Konto.MobilePhone))

    $tekstPrzelozonego = '(brak)'
    if (-not [string]::IsNullOrWhiteSpace([string]$Konto.Manager)) {
        try {
            $przelozony = Get-ADUser -Identity $Konto.Manager -Properties DisplayName, SamAccountName -ErrorAction Stop
            $tekstPrzelozonego = (Format-Pole $przelozony.DisplayName) + ' (' + (Format-Pole $przelozony.SamAccountName) + ')'
        }
        catch {
            $tekstPrzelozonego = [string]$Konto.Manager
        }
    }

    Write-Host ''
    Write-Host '--- Organizacja ---' -ForegroundColor Cyan
    Write-Host (Format-LiniaStatusu -Etykieta 'Dział' -Wartosc (Format-Pole $Konto.Department))
    Write-Host (Format-LiniaStatusu -Etykieta 'Stanowisko' -Wartosc (Format-Pole $Konto.Title))
    Write-Host (Format-LiniaStatusu -Etykieta 'Przełożony' -Wartosc $tekstPrzelozonego)

    Write-Host ''
    Write-Host '--- Jednostka organizacyjna ---' -ForegroundColor Cyan
    Write-Host (Format-LiniaStatusu -Etykieta 'Ścieżka OU' -Wartosc (ConvertTo-SciezkaOu -DistinguishedName $Konto.DistinguishedName))

    $logowanie = Format-DataLokalna -Data $Konto.LastLogonDate -GdyBrak 'Brak danych o ostatnim logowaniu'
    Write-Host ''
    Write-Host '--- Ostatnie logowanie ---' -ForegroundColor Cyan
    Write-Host (Format-LiniaStatusu -Etykieta 'Ostatnie logowanie' -Wartosc $logowanie)

    Write-Host ''
    Write-Host '--- Grupy ---' -ForegroundColor Cyan
    try {
        $suroweGrupy = Get-ADPrincipalGroupMembership -Identity $Konto.DistinguishedName -ErrorAction Stop | Sort-Object -Property Name
        $liczbaGrup = 0
        foreach ($grupa in $suroweGrupy) {
            $liczbaGrup++
            Write-Host (Format-LiniaStatusu -Etykieta 'Grupa' -Wartosc (Format-Pole $grupa.Name))
        }
        if ($liczbaGrup -eq 0) {
            Write-Host (Format-LiniaStatusu -Etykieta 'Grupy' -Wartosc '(brak)')
        }
    }
    catch {
        $opisGrup = (('Nie udało się pobrać grup: ' + [string]$_.Exception.Message) -replace '\s+', ' ').Trim()
        Write-Host (Format-LiniaStatusu -Etykieta 'Grupy' -Wartosc $opisGrup) -ForegroundColor Red
    }

    Write-Host ''
    Write-Host ('=' * 60)
}

function Invoke-PytanieKontynuacji {
    $odpowiedz = Read-Host 'Sprawdzić kolejnego użytkownika? [T/N]'
    if (Test-Kontynuacja -Odpowiedz $odpowiedz) {
        return
    }
    Write-Host ''
    Write-Host 'Koniec sprawdzania kont.'
    exit 0
}

if ($MyInvocation.InvocationName -ne '.') {
    $brakModulu = Get-KomunikatBrakuModulu
    if ($null -ne $brakModulu) {
        Write-Host $brakModulu -ForegroundColor Red
        exit 1
    }

    try {
        Import-Module ActiveDirectory -ErrorAction Stop
    }
    catch {
        $powodImportu = (([string]$_.Exception.Message) -replace '\s+', ' ').Trim()
        if ([string]::IsNullOrWhiteSpace($powodImportu)) {
            $powodImportu = 'Nieznany błąd podczas ładowania modułu ActiveDirectory.'
        }
        Write-Host (Format-Ramka -Tytul 'Nie udało się załadować modułu ActiveDirectory' -Linie @($powodImportu)) -ForegroundColor Red
        exit 1
    }

    while ($true) {
        Write-Host ''
        Write-Host ('=' * 60)
        Write-Host 'Informacje o koncie użytkownika Active Directory' -ForegroundColor Cyan
        Write-Host 'Status konta, hasło i podstawowe właściwości.'
        Write-Host ('=' * 60)

        $nazwa = [string](Read-Host 'Użytkownik (SamAccountName, UPN albo DN)')
        $nazwa = $nazwa.Trim()
        if ([string]::IsNullOrWhiteSpace($nazwa)) {
            Write-Host (Format-Ramka -Tytul 'Pusta nazwa' -Linie @(
                'Nazwa użytkownika nie może być pusta.'
                'Podaj SamAccountName, UPN albo DN.'
            )) -ForegroundColor Red
            continue
        }

        $konto = $null
        $brakKonta = $false
        $blad = $null
        try {
            $szukajPoUpn = ($nazwa -like '*@*') -and ($nazwa -notmatch '=')
            if ($szukajPoUpn) {
                $upn = $nazwa.Replace("'", "''")
                $surowe = Get-ADUser -Filter "UserPrincipalName -eq '$upn'" -Properties $WlasciwosciUzytkownika -ErrorAction Stop
                $liczba = 0
                foreach ($element in $surowe) {
                    $liczba++
                    $konto = $element
                }
                if ($liczba -gt 1) {
                    $konto = $null
                    $blad = "Znaleziono więcej niż jedno konto o UPN: $nazwa"
                }
                elseif ($liczba -eq 0) {
                    $brakKonta = $true
                }
            }
            else {
                $konto = Get-ADUser -Identity $nazwa -Properties $WlasciwosciUzytkownika -ErrorAction Stop
            }
        }
        catch {
            $komunikat = (([string]$_.Exception.Message) -replace '\s+', ' ').Trim()
            $toBrak = $false
            $wyjatek = $_.Exception
            while ($null -ne $wyjatek) {
                $typ = $wyjatek.GetType().FullName
                $tekstWyjatku = [string]$wyjatek.Message
                if ($typ -eq 'Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException') {
                    $toBrak = $true
                    break
                }
                if ($tekstWyjatku -match 'Cannot find an object with identity' -or $tekstWyjatku -match 'identity not found') {
                    $toBrak = $true
                    break
                }
                $wyjatek = $wyjatek.InnerException
            }

            if ($toBrak) {
                $brakKonta = $true
            }
            else {
                if ([string]::IsNullOrWhiteSpace($komunikat)) {
                    $komunikat = 'Nieznany błąd zapytania do Active Directory.'
                }
                $blad = $komunikat
            }
        }

        if ($brakKonta) {
            Write-Host (Format-Ramka -Tytul 'Nie znaleziono konta' -Linie @(
                "Brak użytkownika o identyfikatorze: $nazwa"
                'Podaj SamAccountName, UPN, nazwę wyróżniającą (DN), GUID albo SID.'
            )) -ForegroundColor Red
            Invoke-PytanieKontynuacji
            continue
        }

        if ($null -ne $blad) {
            Write-Host (Format-Ramka -Tytul 'Błąd zapytania do Active Directory' -Linie @($blad)) -ForegroundColor Red
            Invoke-PytanieKontynuacji
            continue
        }

        Write-InformacjeKonta -Konto $konto
        Invoke-PytanieKontynuacji
    }
}