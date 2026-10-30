# Logika `Deploy-App.ps1`

Opis dotyczy pliku `RemoteInstallDeployer/Deploy-App.ps1` i tylko tego, co ten plik wykonuje. Nazwy funkcji są z tego skryptu.

## 1. Cel i założone uruchomienie

Skrypt kopiuje katalog, w którym leży, na kolejne komputery z listy, uruchamia tam `install.bat` i po zakończeniu usuwa kopię. Katalog źródłowy jest katalogiem skryptu (`$PSScriptRoot`), nie bieżącym katalogiem procesu.

Założone ułożenie plików: `Deploy-App.ps1` leży obok `install.bat` i plików payloadu, w nazwanym folderze (nie w korzeniu dysku). Nazwa tego folderu jest nazwą folderu docelowego.

Na każdej stacji celem jest `C:\Temp\<nazwa-folderu-źródłowego>` (`Get-DeployRemoteTargetPath`). Po UNC to `\\<host>\C$\Temp\<nazwa-folderu>` (`Get-DeployRemoteTargetUnc`).

Operator uruchamia skrypt kontem, które może otworzyć udział administracyjny `C$` i sesję CIM/WinRM do hosta. Skrypt nie sprawdza, czy konto jest administratorem domeny, nie pyta o hasło i nie przyjmuje poświadczeń. Sesja CIM to `New-CimSession -ComputerName <host>` bez portu, bez `-Credential` i bez opcji sesji.

Dostępność hosta: najpierw TCP na porcie 5985 (WinRM HTTP), potem ścieżka `\\<host>\C$\`. Brak odpowiedzi na którymś z tych dwóch testów kończy hosta jako nieosiągalny. Port 5986 nie występuje w skrypcie.

Jedyny parametr to `-ComputerList`. Bez niego skrypt pyta o ścieżkę pliku z hostami.

## 2. Wejście, log i konsola

Na górze pliku jest wyłącznie:

- `[string]$ComputerList` — opcjonalny. Pusty lub sam biały znak jest traktowany jak brak parametru.

Nie ma `#requires`, nie ma drugiego parametru, nie ma `-Timeout`, `-Credential`, `-WhatIf` ani `-Confirm`. Limit instalacji jest stały: `$script:DeployInstallLimit = 15 minut`, ustawiony przy starcie pliku.

Przeznaczone środowisko to Windows PowerShell 5.1 (CIM, `robocopy.exe`, udział `C$`). Plik wersji nie wymusza.

Dolna część pliku, po definicjach funkcji:

1. Jeśli skrypt jest kropkowany (`$MyInvocation.InvocationName -eq '.'`), nic się nie uruchamia.
2. W przeciwnym razie, gdy widać `Invoke-DeployMain`, skrypt woła `Invoke-DeployMain -ComputerList $ComputerList` i robi `exit` z jej kodem.

Kody wyjścia procesu:

- `1` — walidacja lokalna odrzuciła start. Żaden host nie jest ruszany. Plik logu nie powstaje.
- `0` — walidacja przeszła, pętla hostów i podsumowanie się wykonały. Wyniki hostów (`FAILED`, `TIMEOUT`) nie zmieniają tego zera.

Konsola jest po angielsku. Kolor jest tylko na konsoli (`Write-Host -ForegroundColor`). Plik logu dostaje te same teksty bez koloru, każdy z prefiksem czasu lokalnego `yyyy-MM-dd HH:mm:ss` i spacją (`Write-DeployLine`).

`Get-DeployLogColor`:

| `Kind` | Kolor |
| --- | --- |
| `Separator`, `Title`, `HostBanner` | biały |
| `Meta` | szary |
| `Stage` | czerwony, gdy tekst zawiera `FAILED`; inaczej żółty, gdy zawiera `TIMEOUT`; inaczej zielony, gdy zawiera `OK`; inaczej szary |

Porównanie jest wrażliwe na wielkość liter. Linia `  Cleanup ... cleanup failed` jest szara, bo słowo `failed` jest małymi literami. Linia z `FAILED` jest czerwona.

Log (`Initialize-DeployLogger`, `New-DeployLogPath`):

- Katalog: `<źródło>\logs`. Tworzony, gdy go nie ma.
- Nazwa: `deploy-yyyyMMdd-HHmmss.log`. Znacznik jest z jednego `Get-Date` na początku udanego przebiegu, nie z każdej linii.
- Gdy ta nazwa już istnieje: `deploy-<znacznik>-2.log`, potem `-3`, i dalej bez górnego limitu.
- `StreamWriter` z dopisywaniem wyłączonym (istniejący plik o wybranej nazwie byłby nadpisany; kolizja jest omijana nową nazwą). `AutoFlush = $true`. Skrypt nie ustawia kodowania writera.
- Zamknięcie w `finally` funkcji `Invoke-DeployMain` (`Close-DeployLogger`), także gdy później poleci wyjątek.

`Write-Progress` paska kopii nie idzie do logu.

Błędy walidacji idą zwykłym `Write-Host`, zanim powstanie logger. Nie mają prefiksu czasu i nie trafiają do pliku.

## 3. Sekwencja główna

Po definicjach funkcji realny start to wywołanie `Invoke-DeployMain`. Kolejność:

1. Gdy `ScriptRoot` jest pusty, podstaw `$PSScriptRoot`. Bezpośrednie uruchomienie nie podaje `ScriptRoot`, więc źródłem jest katalog skryptu.
2. `Invoke-DeployLocalValidation`. Gdy `ExitCode` nie jest `0`, zwróć `1`. Koniec. Bez logu, bez hostów.
3. `Get-Date` jako znacznik logu.
4. W `try`:
   1. `Initialize-DeployLogger` na `<źródło>\logs`.
   2. `Write-DeployHeader`.
   3. Pusta lista wyników.
   4. Hosty po kolei, jeden po drugim, w kolejności z pliku. Dla każdego: `Invoke-DeployHost`. Nie ma równoległości, kolejek ani powtórzeń po błędzie. Duplikaty z listy są wykonywane osobno. Skrypt nie usuwa powtórek.
   5. `Write-DeploySummary` na zebrane wyniki.
   6. Zwróć `0`.
5. W `finally`: `Close-DeployLogger`.

Pętla hostów nie ma własnego `try`. Nieobsłużony wyjątek z hosta przerywa pętlę, pomija podsumowanie i pomija `return 0`. `finally` i tak zamyka log. `exit` na dole pliku wtedy nie dostaje kodu z `Invoke-DeployMain`.

## 4. Walidacja lokalna

`Invoke-DeployLocalValidation` kończy się na pierwszym błędzie. Komunikat jest dokładnie taki, jak poniżej. Kropka na końcu ścieżki, tam gdzie jest w tekście, jest częścią komunikatu.

1. Pusty `ScriptRoot`, albo po obcięciu końcowych `\` i `/` nazwa folderu jest pusta. Ścieżka dopasowana do `^[A-Za-z]:$` też daje pustą nazwę. Komunikat, bez zdania o braku wdrożenia:

   `ERROR: script must live in a named folder, not a drive root.`

2. Brak pliku `install.bat` w katalogu źródłowym (`Test-Path -PathType Leaf`):

   `ERROR: install.bat not found in <źródło>. Nothing was deployed.`

3. Brak `robocopy.exe` w `PATH` (`Get-Command`, `Test-DeployRobocopyAvailable`):

   `ERROR: robocopy.exe not found in PATH. Nothing was deployed.`

4. Ścieżka listy (`Get-DeployComputerListPath`):
   - parametr pusty lub biały → `Read-Host` z tekstem `Computer list file path:`;
   - po promptcie nadal pusto → `ERROR: computer list file path was not provided.`;
   - wartość jest obcinana `Trim`;
   - ścieżka względna jest składana z `(Get-Location).Path`, czyli z bieżącym katalogiem procesu, nie z katalogiem skryptu;
   - na końcu `GetFullPath`.

5. Plik listy nie istnieje albo nie jest plikiem:

   `ERROR: computer list file not found: <pełna-ścieżka>.`

6. Odczyt `Get-Content -LiteralPath -Encoding utf8` i `ConvertFrom-DeployHostList`. Zostają linie po `Trim`, które nie są puste i nie zaczynają się od `#`. Zero hostów:

   `ERROR: computer list contains no hostnames: <pełna-ścieżka>.`

Linia `host # komentarz` nie jest komentarzem. Cały przycięty tekst staje się nazwą hosta. Wielkość liter zostaje. Skrypt nie sprawdza, czy to poprawna nazwa DNS.

Sukces zwraca `ExitCode = 0`, `SourcePath`, `FolderName`, `ListPath`, `Hosts`.

## 5. Nagłówek przebiegu

`Write-DeployHeader` / `Get-DeployHeaderLines`. Separator (`Get-DeploySeparator`) to 60 znaków `=`. Spacje w liniach są takie, jak w skrypcie:

```text
============================================================
 Remote install deployer
 Source : <pełna ścieżka źródła>
 Target : C:\Temp\<nazwa-folderu>
 Hosts  : <liczba> (from <pełna ścieżka listy>)
 Timeout: 15 minutes (install is not killed on timeout)
============================================================
```

`Target` jest zawsze lokalną ścieżką na stacji docelowej, bez nazwy hosta. Liczba hostów jest liczbą linii po filtrze, nie liczbą unikalnych nazw.

## 6. Potok jednego hosta

`Invoke-DeployHost` dostaje hosta, numer, liczbę hostów, źródło, nazwę folderu i ścieżkę listy. Najpierw baner, `Kind = HostBanner`:

`[n/N] <hostname>`

Dalej albo szybkie wyjście „nieosiągalny”, albo kopia, start, czekanie i sprzątanie. Następny host startuje dopiero po powrocie z tego potoku.

### 6.1. Sonda: TCP 5985, potem `C$`

`Test-DeployHostReachable`. Wyjątek z któregoś testu daje „nieosiągalny”. Drugi test nie startuje, gdy pierwszy zwróci fałsz.

**TCP, `Test-DeployTcpPort`.** Port `5985`, limit `15000` ms na DNS i połączenie razem.

1. Start stopera.
2. `Dns.BeginGetHostAddresses`. Czekanie na wynik zużywa ten sam budżet 15 s. Timeout DNS → fałsz.
3. Brak adresu albo pusty pierwszy adres → fałsz.
4. Używany jest tylko pierwszy adres (`$addrs[0]`), z jego rodziną (IPv4 albo IPv6). Pozostałe adresy nie są próbowane.
5. Na `BeginConnect` zostaje reszta budżetu, co najmniej 1 ms.
6. Timeout połączenia albo wyjątek → fałsz. W `finally` klient TCP jest zamykany.

**Udział, `Test-DeployAdminShare`.** Osobne 15 s, nie wspólne z TCP. Sprawdzana jest ścieżka `\\<host>\C$\`, nie folder docelowy i nie port 445 osobnym testem.

`Wait-DeployChildProcess` uruchamia nowy proces tego samego pliku wykonywalnego co bieżąca sesja (`Get-Process -Id $PID`). Argumenty: `-NoProfile -NonInteractive -Command "<polecenie>"`. Na `Win32NT` okno jest `Hidden`. Polecenie dziecka:

```text
try { if (Test-Path -LiteralPath '\\<host>\C$\') { exit 0 } else { exit 1 } } catch { exit 1 }
```

Pojedynczy apostrof w ścieżce jest podwajany. Cudzysłów w tekście polecenia jest eskejpowany przed wstawieniem do `-Command`.

Dziecko ma `WaitForExit(15000)`. Kod `0` to sukces. Brak wyjścia w limicie: `Kill()` tego lokalnego procesu i fałsz. Wyjątek: próba `Kill()`, gdy proces jeszcze żyje, potem fałsz. `Dispose` w `finally`. To jedyne miejsce w skrypcie, które zabija proces. Dotyczy lokalnej sondy `C$`, nie instalacji na hoście.

Niepowodzenie sondy, bez kopii, bez CIM i bez usuwania czegokolwiek na hoście. `New-DeployHostResult` z powodem `FAILED (unreachable)`. Linie (`Get-DeployStageLines`):

```text
  Copy ... FAILED (unreachable)
  Install ... skipped
  Cleanup ... skipped (nothing created)
```

### 6.2. Kopia

Gdy sonda przejdzie, skrypt najpierw zapisuje:

`  Copy ... start`

Potem `Copy-DeployPayload`.

1. `New-DeployRemoteTemp` tworzy `\\<host>\C$\Temp`, jeśli go nie ma. Nie tworzy podfolderu payloadu i nigdy później nie usuwa samego `C:\Temp`. Niepowodzenie: kopia nieudana, `PayloadFolderCreated = $false`, zero plików, zero bajtów. Robocopy nie startuje.
2. Inwentaryzacja źródła (`Get-DeployFolderInventory`) do paska postępu. `Get-ChildItem -Force`, rekurencyjnie. Pomijane są pliki o nazwie `Deploy-App.ps1` oraz, gdy lista leży w źródle, pliki o nazwie pliku listy. Pomijane są katalogi o nazwie `logs` (całe poddrzewo). Porównanie nazw jest bez wielkości liter. To nie jest licznik wypisany przez robocopy.
3. Argumenty robocopy (`Get-DeployRobocopyArgumentList`), w tej kolejności, bez `/MIR`:

   ```text
   <źródło>
   \\<host>\C$\Temp\<folder>
   /E /R:2 /W:3 /NFL /NDL /NJH /NJS /NP /NC /NS
   /XF Deploy-App.ps1
   <nazwa-pliku-listy, tylko gdy lista jest wewnątrz źródła>
   /XD logs
   ```

   `/E` kopiuje podkatalogi, także puste. `/R:2` i `/W:3` są przekazane robocopy jako liczba powtórzeń i czas oczekiwania. Przełączniki `/NFL` `/NDL` `/NJH` `/NJS` `/NP` `/NC` `/NS` wyciszają listing robocopy. Skrypt i tak nie czyta tego listingu. `/XF` wyklucza pliki po nazwie w całym drzewie. Dodatkowa nazwa listy jest kolejnym tokenem tego samego `/XF`. `/XD logs` wyklucza katalogi o nazwie `logs`.

   Lista jest „wewnątrz źródła” (`Test-DeployListInsideSource`), gdy pełna ścieżka listy, po `ToLowerInvariant`, zaczyna się od pełnej ścieżki źródła plus separatora (`\`, `/`). Sam katalog źródła się nie liczy.

4. `Start-DeployRobocopyProcess`. Token ze spacją albo pusty dostaje cudzysłowy (`ConvertTo-DeployProcessArgumentString`). Stdout i stderr idą do plików tymczasowych. Proces: `robocopy.exe`, `-NoNewWindow`.
5. Dopóki robocopy działa: co 500 ms inwentaryzacja celu bez wykluczeń, `Write-Progress -Activity 'Copy' -Id 1`. Procent (`Get-DeployCopyPercent`): gdy oczekiwane bajty > 0, `floor(skopiowane_bajty * 100 / oczekiwane_bajty)`, maksimum 100. Inaczej, gdy oczekiwane pliki > 0, ten sam wzór na plikach. Gdy oba zera, procent to 100. Status:

   `<host> <pliki-celu>/<pliki-oczekiwane> files <bajty-celu>/<bajty-oczekiwane> bytes`

   Licznik celu obejmuje to, co już leży w folderze docelowym, także zostawione przez wcześniejszy przebieg. Pasek może więc zacząć się powyżej zera i dojść do 100, zanim robocopy skończy.
6. Po wyjściu robocopy sukcesem jest kod od 0 do 7 włącznie (`Test-DeployRobocopySuccess`). Kod 8 i wyższy oraz kod ujemny to porażka. Bity robocopy nie są rozkodowywane. Obiekt z `Copy-DeployPayload` niesie końcową inwentaryzację celu, znowu bez wykluczeń: liczba plików i suma długości. To nie jest liczba „ile robocopy skopiował w tej sesji”. Przy porażce kopii `Invoke-DeployHost` tych liczb nie przepisuje do wyniku hosta (`CopyFiles` i `CopyBytes` zostają 0) i nie wypisuje linii `complete`.
7. `finally`: gdy proces powstał, `Write-Progress -Completed` i usunięcie plików tymczasowych stdout/stderr. Ich treść nie jest logowana.

Nieudana kopia (`Success` fałsz), w tym wyjątek albo brak obiektu procesu po udanym `C:\Temp`:

- konsola: `  Copy ... FAILED (copy)`;
- `Get-DeployCleanupDecision` dla `FAILED (copy)`: `Delete` tylko gdy `PayloadFolderCreated` jest prawdą, inaczej `SkipNothingCreated`;
- przy `Delete`: `Remove-DeployPayloadFolder`;
- powód wyniku zostaje `FAILED (copy)`;
- dalej tylko linie instalacji i sprzątania, bez ponownego wypisania linii kopii:

```text
  Install ... skipped
  Cleanup ... skipped (nothing created)
```

albo, gdy folder był oznaczony jako utworzony i usuwanie się udało:

```text
  Install ... skipped
  Cleanup ... deleted
```

albo, gdy usuwanie zwróciło fałsz:

```text
  Install ... skipped
  Cleanup ... cleanup failed
```

`PayloadFolderCreated` jest prawdą dopiero po udanym utworzeniu `C:\Temp`, także gdy podfolder payloadu w ogóle nie powstał. `Remove-DeployPayloadFolder` na nieistniejącej ścieżce zwraca sukces bez `Remove-Item`, więc komunikat i tak brzmi `deleted`.

Udane kopiowanie. Jedna linia, liczby z inwentaryzacji celu:

`  Copy ... complete: <pliki> files, <bajty> bytes`

### 6.3. Usunięcie starego `.deploy-exit` i start procesu

Po udanej kopii, w `try`/`finally`. `finally` zawsze woła `Remove-DeployCimSession` (`Remove-CimSession -ErrorAction SilentlyContinue`), gdy sesja nie jest pusta.

1. `New-DeployCimSession`. Wyjątek daje pustą sesję i jest traktowany jak nieudany start. Stary `.deploy-exit` nie jest wtedy ruszany osobno; cały folder payloadu idzie do usunięcia.
2. Gdy sesja jest: `Remove-Item -ErrorAction SilentlyContinue` na `\\<host>\C$\Temp\<folder>\.deploy-exit`. Błąd usuwania jest połykany. Innych plików ten krok nie kasuje.
3. `Start-DeployInstall` → `Invoke-DeployCimCreate`: `Invoke-CimMethod` na klasie `Win32_Process`, metoda `Create`. Argumenty:
   - `CommandLine` = wynik `Get-DeployInstallCommandLine` (sekcja 6.4);
   - `CurrentDirectory` = `C:\Temp\<folder>`.
4. Start jest udany tylko gdy wynik nie jest pusty, `ReturnValue -eq 0` i `ProcessId -gt 0`. Inaczej porażka. `Create` wraca od razu. Skrypt nie czeka w tym wywołaniu na koniec instalacji.

Nieudany start: powód `FAILED (start)`, folder oznaczony jako utworzony, liczby kopii z udanego kopiowania. Zawsze próba `Remove-DeployPayloadFolder`. Linie:

```text
  Install ... FAILED (start)
  Cleanup ... deleted
```

albo `  Cleanup ... cleanup failed`. Linii `Install ... waiting` nie ma. Powód wyniku zostaje `FAILED (start)` nawet gdy sprzątanie padnie (`CleanupFailed` osobno).

### 6.4. `CommandLine` i katalog roboczy

`Get-DeployInstallCommandLine` zwraca dokładnie:

```text
cmd.exe /v:on /c "cmd.exe /c install.bat & echo !ERRORLEVEL!>.deploy-exit"
```

`CurrentDirectory` procesu to `C:\Temp\<folder>`. W linii polecenia nie ma `cd`. Względne `install.bat` i `.deploy-exit` odnoszą się do tego katalogu.

Są dwa `cmd.exe`:

- Zewnętrzny: `cmd.exe /v:on /c "..."`. `/v:on` włącza opóźnione rozwijanie. `/c` kończy ten interpreter po wykonaniu ciągu. PID z `Win32_Process.Create` to PID tego zewnętrznego `cmd.exe`. `Wait-DeployInstall` śledzi ten PID, nie PID `install.bat` i nie PID wewnętrznego `cmd`.
- Wewnętrzny, już w ciągu zewnętrznego: `cmd.exe /c install.bat`. Potem, w tym samym zewnętrznym interpreterze, operator `&` i `echo !ERRORLEVEL!>.deploy-exit`.

Zagnieżdżenie jest po to, żeby `exit` w `install.bat` nie zjadł zapisu `.deploy-exit`. `exit` bez `/b` kończy interpreter, który wykonuje batch. Gdyby `install.bat` i `echo` były w jednym `cmd`, takie `exit` zakończyłoby ten `cmd` przed `echo` i plik by nie powstał. Wewnętrzne `cmd.exe /c install.bat` bierze to `exit` na siebie. Zewnętrzny `cmd` zostaje i dochodzi do `echo`.

`&` (nie `&&`) uruchamia `echo` także wtedy, gdy `install.bat` zwróci kod inny niż zero. Inaczej niezerowy kod nie miałby pliku i po zniknięciu procesu wyszłoby `FAILED (no exit code)` zamiast `FAILED (exit N)`.

`!ERRORLEVEL!` przy `/v:on` jest czytane w chwili `echo`, czyli po powrocie wewnętrznego `cmd`. Zwykłe `%ERRORLEVEL%` zostałoby rozwinięte przy parsowaniu zewnętrznej linii, zanim `install.bat` się wykona.

Zewnętrzny `cmd` kończy się dopiero po `echo`. Gdy jego PID znika, zapis `.deploy-exit` jest już zlecony. Skrypt i tak daje plikowi do 10 s (sekcja 6.5), gdy odczyt po UNC jeszcze nie widzi liczby.

### 6.5. Czekanie, `Wait-DeployInstall`

Po udanym `Create` konsola dostaje `  Install ... waiting`. Limit to `$script:DeployInstallLimit` (15 minut) od `Get-DeployNow` w tej funkcji. Ścieżka pliku: `\\<host>\C$\Temp\<folder>\.deploy-exit`.

Pętla:

1. `Test-DeployRemoteProcess`: `Get-CimInstance Win32_Process` z filtrem `ProcessId=<pid>` i `-ErrorAction Stop`. Wyjątek tego zapytania od razu zwraca `TIMEOUT (still running)`. Nie ma dalszego czekania do 15 minut, nie ma odczytu `.deploy-exit`, nie ma zabicia procesu.
2. Gdy proces zniknął, osobne okno 10 s na plik, co 1 s (`Invoke-DeploySleep`):
   - `Get-DeployExitFileText` czyta plik (`ReadAllText`), gdy jest plikiem. Brak pliku albo błąd odczytu → brak treści.
   - `ConvertFrom-DeployExitFile`: `Trim`, potem `int.TryParse` na całość. Pusto, biało albo nie-liczba → brak kodu. Liczba całkowita, także ujemna, jest akceptowana.
   - `0` → powód `OK`.
   - inna liczba → `FAILED (exit <n>)`.
   - po 10 s nadal brak liczby → `FAILED (no exit code)`.
   Sen 1 s jest po teście czasu, więc ostatni obieg może przekroczyć te 10 s o jeden interwał. Okno pliku nie jest obcinane przez pierwotne 15 minut. Jeśli proces zniknął przy końcu limitu instalacji, odczyt pliku może wyjść poza ten limit o te około 10 s.
3. Gdy proces nadal jest i `teraz >= deadline` → `TIMEOUT (still running)`. Plik `.deploy-exit` nie jest czytany. Proces instalacji nie jest zabijany. Folder nie jest usuwany w tym kroku.
4. W przeciwnym razie sen 5 s i kolejna iteracja. Reakcja na deadline może więc przyjść do jednego interwału po progu, bo sen jest po teście czasu.

Po powrocie z czekania skrypt zapisuje `  Install ... <powód>` i buduje `New-DeployHostResult`. `CleanupFailed` jest jeszcze fałszem. Potem decyzja sprzątania i dopiero wtedy linie cleanup.

### 6.6. Sprzątanie

`Get-DeployCleanupDecision`:

| Powód | `PayloadFolderCreated` | Decyzja | Co się dzieje |
| --- | --- | --- | --- |
| `FAILED (unreachable)` | fałsz | `SkipNothingCreated` | nic na hoście nie jest usuwane |
| `FAILED (copy)` | fałsz | `SkipNothingCreated` | `New-DeployRemoteTemp` nie potwierdziło `\\<host>\C$\Temp`. Nic nie jest usuwane |
| `FAILED (copy)` | prawda | `Delete` | `Remove-DeployPayloadFolder` |
| `FAILED (start)` | prawda | `Delete` | j.w. |
| `FAILED (exit N)` | prawda | `Delete` | j.w. |
| `FAILED (no exit code)` | prawda | `Delete` | j.w. |
| `OK` | prawda | `Delete` | j.w. |
| `TIMEOUT (still running)` | prawda | `SkipStillRunning` | folder zostaje; proces instalacji zostaje |

`Remove-DeployPayloadFolder` robi `Remove-Item -LiteralPath \\<host>\C$\Temp\<folder> -Recurse -Force`. Cel to tylko ten folder. Nie ma kasowania procesu, `C:\Temp`, katalogu źródłowego ani lokalnego `logs`. Brak ścieżki (test fałsz) zwraca `$true`. Wyjątek zwraca `$false`, a wynik hosta dostaje `CleanupFailed = $true`.

Linie sprzątania (`Get-DeployStageLines`):

- `SkipNothingCreated` → `  Cleanup ... skipped (nothing created)`
- `SkipStillRunning` → `  Cleanup ... skipped (still running)`
- `Delete` i usuwanie zwróciło prawdę → `  Cleanup ... deleted`
- `Delete` i usuwanie zwróciło fałsz → `  Cleanup ... cleanup failed`

## 7. Wynik hosta a nieudane sprzątanie

`New-DeployHostResult` / `Get-DeployOutcomeFromReason`:

- powód `OK` → `Outcome` `OK`;
- powód dokładnie `TIMEOUT (still running)` → `Outcome` `TIMEOUT`;
- każdy inny powód → `Outcome` `FAILED`.

Pola: `Hostname`, `Outcome`, `Reason`, `PayloadFolderCreated`, `CleanupFailed`, `CopyFiles`, `CopyBytes`.

`CleanupFailed` nie zmienia `Outcome` ani `Reason`. Host z udaną instalacją i nieudanym usunięciem folderu zostaje `OK` / `OK`. Host z `FAILED (exit 3)` i nieudanym usunięciem zostaje `FAILED` / `FAILED (exit 3)`. Dopisek `, cleanup failed` powstaje tylko przy drukowaniu podsumowania, nie w obiekcie.

Ścieżka `TIMEOUT` nie ustawia `CleanupFailed`. Folder zostaje, bo decyzją jest `SkipStillRunning`, a nie dlatego, że usuwanie się nie udało.

## 8. Podsumowanie

`Write-DeploySummary` / `Get-DeploySummaryLines`. Liczniki są po `Outcome`. Kolejność linii:

```text
============================================================
OK      : <n>
FAILED  : <n>
TIMEOUT : <n>
```

Potem, tylko gdy są takie wyniki, w kolejności hostów z przebiegu:

```text
FAILED:
  <hostname> - <Reason>
```

Gdy u tego hosta `CleanupFailed`: `  <hostname> - <Reason>, cleanup failed`. Przykład: `  PC01 - FAILED (exit 1), cleanup failed`.

```text
TIMEOUT:
  <hostname> - TIMEOUT (still running)
```

Ta linia jest stałym tekstem, bez dopisku o sprzątaniu.

```text
Leftover (OK, cleanup failed):
  <hostname>
```

Ta sekcja jest tylko dla `Outcome` `OK` i `CleanupFailed`. `TIMEOUT` tu nie wchodzi. Samo `TIMEOUT` też zostawia folder na hoście, ale w podsumowaniu jest wyłącznie na liście `TIMEOUT:`.

Kolor linii podsumowania (`Get-DeploySummaryLineKind`): pierwsza linia to separator. Linia zaczynająca się od dwóch spacji i zawierająca `FAILED` albo `TIMEOUT` idzie jako `Stage` (czerwień albo żółć według reguł z sekcji 2). Liczniki, nagłówki `FAILED:` / `TIMEOUT:` / `Leftover...` i gołe nazwy w leftover są `Meta` (szare). Słowo `FAILED` w liczniku `FAILED  : n` nie robi linii czerwonej, bo ta linia nie zaczyna się od dwóch spacji.

## 9. Co jest kopiowane, a co wykluczone

Robocopy bierze drzewo źródła (`/E`) i dokłada je do celu. Nie ma `/MIR`: plików, których nie ma w źródle, skrypt przed kopią nie kasuje. Ponowny przebieg w folder zostawiony przez `TIMEOUT` nadpisuje pliki o tych samych ścieżkach i zostawia obce pliki. Jedyny plik kasowany przed nowym startem to istniejący `.deploy-exit`.

Wykluczone z kopii:

- każdy plik o nazwie `Deploy-App.ps1`;
- każdy plik o nazwie pliku listy, tylko gdy pełna ścieżka listy leży wewnątrz katalogu źródłowego;
- każdy katalog o nazwie `logs`, w tym `<źródło>\logs` z logiem tego przebiegu.

`install.bat` i reszta payloadu są kopiowane. Plik `.deploy-exit` ze źródła, gdyby tam leżał, też byłby skopiowany; po udanej kopii i udanej sesji CIM stary `.deploy-exit` na celu jest usuwany przed `Create`.

Mianownik paska postępu używa wykluczeń powyżej. Liczba w linii `Copy ... complete` jest z pełnej zawartości folderu docelowego po robocopy, bez tych wykluczeń. Przy świeżym celu wartości się schodzą. Przy zostawionym folderze linia `complete` liczy też stare pliki.

## 10. Czego skrypt nie usuwa

Zostaje na hoście:

- cały `C:\Temp\<folder>` przy `TIMEOUT (still running)`. Skrypt nie zabija procesu. Ten sam powód jest też wtedy, gdy zapytanie CIM o proces rzuciło wyjątek: folder i tak zostaje, bez sprawdzenia, czy instalacja jeszcze działa;
- ten sam folder, gdy `Remove-DeployPayloadFolder` zwróci fałsz (`CleanupFailed`), niezależnie od tego, czy wynik główny to `OK`, czy `FAILED`;
- `C:\Temp`, jeśli istniał albo został utworzony przez `New-DeployRemoteTemp`.

Przy `FAILED (unreachable)` skrypt nic na hoście nie tworzy i nic nie usuwa.

Lokalnie skrypt nie usuwa źródła, `install.bat`, payloadu ani katalogu `logs`.

## 11. Czego skrypt nie robi

- Nie używa WinRM HTTPS ani portu 5986.
- Nie bierze hostów równolegle.
- Nie zabija instalacji na hoście: ani po timeoutcie, ani po `FAILED`, ani po `OK`. `Kill()` jest tylko dla lokalnego dziecka sondy `C$`, które nie zdążyło wyjść w 15 s.
- Nie ma parametrów poza `-ComputerList`. Limit 15 minut, port 5985, czasy sond i czasy snu są stałe w kodzie.
- Nie przekazuje poświadczeń i nie sprawdza członkostwa w grupie administratorów.
- Nie robi pinga ICMP i nie otwiera osobnego testu portu 445.
- Nie używa `/MIR` i nie czyści celu przed kopią.
- Nie wznawia hosta i nie zmienia kolejności listy.
- Nie mapuje kodu wyjścia `install.bat` na kod wyjścia skryptu. Po przejściu walidacji proces kończy się zerem, także gdy każdy host jest `FAILED` albo `TIMEOUT`.
- Nie steruje oknem `install.bat` i nie wysyła klawiszy. Jedyny kontrakt wyniku instalacji to liczba w `.deploy-exit`.
- Nie dopisuje błędów walidacji do logu, bo logger startuje po walidacji.
- Nie uruchamia pracy po kropkowaniu pliku.

## 12. Komunikaty w kolejności, w jakiej powstają

Walidacja, konsola, bez logu. Pierwszy pasujący kończy skrypt kodem 1:

1. `ERROR: script must live in a named folder, not a drive root.`
2. `ERROR: install.bat not found in <źródło>. Nothing was deployed.`
3. `ERROR: robocopy.exe not found in PATH. Nothing was deployed.`
4. `ERROR: computer list file path was not provided.`
5. `ERROR: computer list file not found: <ścieżka>.`
6. `ERROR: computer list contains no hostnames: <ścieżka>.`

Prompt, tylko gdy `-ComputerList` jest pusty: `Computer list file path:`

Przebieg, konsola i log:

1. Nagłówek z sekcji 5.
2. Dla każdego hosta baner `[n/N] <hostname>`, potem jeden z wariantów:
   - nieosiągalny: `  Copy ... FAILED (unreachable)`, `  Install ... skipped`, `  Cleanup ... skipped (nothing created)`;
   - kopia nieudana: `  Copy ... start`, `  Copy ... FAILED (copy)`, `  Install ... skipped`, potem `skipped (nothing created)` albo `deleted` albo `cleanup failed`;
   - start nieudany: `  Copy ... start`, `  Copy ... complete: <pliki> files, <bajty> bytes`, `  Install ... FAILED (start)`, potem `deleted` albo `cleanup failed`;
   - instalacja doszła do czekania: te same dwie linie kopii, `  Install ... waiting`, potem `  Install ... OK` albo `  Install ... FAILED (exit <n>)` albo `  Install ... FAILED (no exit code)` albo `  Install ... TIMEOUT (still running)`, potem `deleted`, `cleanup failed` albo `  Cleanup ... skipped (still running)`.
3. Podsumowanie z sekcji 8.

Powody zapisywane w `Reason`, bez dopisku o sprzątaniu:

- `OK`
- `FAILED (unreachable)`
- `FAILED (copy)`
- `FAILED (start)`
- `FAILED (exit <n>)`
- `FAILED (no exit code)`
- `TIMEOUT (still running)`

Innych etykiet wyniku ten plik nie produkuje.
