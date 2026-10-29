# Przed użyciem w SCCM zmień:
# - $Manufacturer na producenta; * jest dozwolone, np. Intel*. Puste pomija ten filtr
# - $DeviceClass na klasę, np. NET. Puste pomija ten filtr. Przynajmniej jedno z tych dwóch pól musi zostać
# - $ExpectedVersion na DriverVersion, od 2 do 4 członów, np. 24.60.0.3
# - $Compare na Equals (dokładnie ta wersja) albo Minimum (ta wersja lub nowsza)
# Write-Host i exit 0 zostaw bez zmian.

$ErrorActionPreference = 'Stop'

$Manufacturer = 'Intel*'
$DeviceClass = 'NET'
$ExpectedVersion = '1.0.0.0'
$Compare = 'Minimum'

function ConvertTo-FourPartVersion {
    param([string]$Text)
    if ($Text -notmatch '^\d+(\.\d+){1,3}$') { return $null }
    $parts = @($Text.Split('.'))
    while ($parts.Count -lt 4) { $parts += '0' }
    return [version]::new([int]$parts[0], [int]$parts[1], [int]$parts[2], [int]$parts[3])
}

try {
    $expected = ConvertTo-FourPartVersion $ExpectedVersion
    if (-not $expected) { exit 0 }
    if ($Compare -notin @('Equals', 'Minimum')) { exit 0 }
    if ([string]::IsNullOrWhiteSpace($Manufacturer) -and [string]::IsNullOrWhiteSpace($DeviceClass)) {
        exit 0
    }

    $versions = @(
        Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
            Where-Object {
                ([string]::IsNullOrWhiteSpace($Manufacturer) -or $_.Manufacturer -like $Manufacturer) -and
                ([string]::IsNullOrWhiteSpace($DeviceClass) -or $_.DeviceClass -eq $DeviceClass) -and
                $_.DriverVersion
            } |
            Select-Object -ExpandProperty DriverVersion
    )

    $match = $false
    foreach ($version in $versions) {
        $actual = ConvertTo-FourPartVersion ([string]$version)
        if (-not $actual) { continue }
        if ($Compare -eq 'Minimum' -and $actual -ge $expected) { $match = $true }
        if ($Compare -eq 'Equals' -and $actual -eq $expected) { $match = $true }
    }

    if ($match) { Write-Host 'Installed' }
} catch {}

exit 0
