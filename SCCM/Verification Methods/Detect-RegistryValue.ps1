<#
 Przed użyciem w SCCM zmień:
- $KeyPath na klucz pod HKLM, bez HKLM:\ , np. SOFTWARE\Vendor\App
- $ValueName na nazwę wartości w tym kluczu
- $ExpectedValue na oczekiwany tekst; zostaw puste, jeśli wystarczy samo istnienie wartości
Sprawdzane są widoki 32- i 64-bitowe. Skrypt działa jako SYSTEM. Write-Host i exit 0 zostaw bez zmian.
#>

$ErrorActionPreference = 'Stop'

$KeyPath = 'SOFTWARE\Vendor\App'
$ValueName = 'Version'
$ExpectedValue = '1.0'

if ([string]::IsNullOrWhiteSpace($KeyPath) -or [string]::IsNullOrWhiteSpace($ValueName)) {
    exit 0
}

$found = $false
$views = @(
    [Microsoft.Win32.RegistryView]::Registry64
    [Microsoft.Win32.RegistryView]::Registry32
)

foreach ($view in $views) {
    $base = $null
    $key = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine,
            $view
        )
        $key = $base.OpenSubKey($KeyPath)
        if (-not $key) { continue }

        $actual = $key.GetValue($ValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($null -eq $actual) { continue }

        if ([string]::IsNullOrWhiteSpace($ExpectedValue) -or ([string]$actual -eq $ExpectedValue)) {
            $found = $true
            break
        }
    } catch {
        continue
    } finally {
        if ($key) { $key.Dispose() }
        if ($base) { $base.Dispose() }
    }
}

if ($found) { Write-Host 'Installed' }
exit 0
