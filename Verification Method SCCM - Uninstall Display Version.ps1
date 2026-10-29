# Przed użyciem w SCCM zmień:
# - $DisplayName na nazwę z Programy i funkcje; * jest dozwolone, np. 'Vendor App*'
#   samo '*' jest ignorowane
# - $ExpectedVersion na DisplayVersion; zostaw puste, jeśli wystarczy sama nazwa
# - $Compare na Equals (dokładnie ta wersja) albo Minimum (ta wersja lub nowsza)
# Sprawdzane są oba klucze Uninstall. Write-Host i exit 0 zostaw bez zmian.

$ErrorActionPreference = 'Stop'

$DisplayName = 'Vendor App*'
$ExpectedVersion = '1.0.0.0'
$Compare = 'Equals'

function ConvertTo-FourPartVersion {
    param([string]$Text)
    if ($Text -notmatch '^\d+(\.\d+){1,3}$') { return $null }
    $parts = @($Text.Split('.'))
    while ($parts.Count -lt 4) { $parts += '0' }
    return [version]::new([int]$parts[0], [int]$parts[1], [int]$parts[2], [int]$parts[3])
}

try {
    if ([string]::IsNullOrWhiteSpace($DisplayName) -or $DisplayName -eq '*') { exit 0 }
    if ($Compare -notin @('Equals', 'Minimum')) { exit 0 }

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $entries = foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
        }
    }

    $hits = @($entries | Where-Object { $_.DisplayName -like $DisplayName })
    if ($hits.Count -eq 0) { exit 0 }

    if ([string]::IsNullOrWhiteSpace($ExpectedVersion)) {
        Write-Host 'Installed'
        exit 0
    }

    $expected = ConvertTo-FourPartVersion $ExpectedVersion
    if (-not $expected) { exit 0 }

    $match = $false
    foreach ($hit in $hits) {
        $actual = ConvertTo-FourPartVersion ([string]$hit.DisplayVersion)
        if (-not $actual) { continue }
        if ($Compare -eq 'Minimum' -and $actual -ge $expected) { $match = $true }
        if ($Compare -eq 'Equals' -and $actual -eq $expected) { $match = $true }
    }

    if ($match) { Write-Host 'Installed' }
} catch {}

exit 0
