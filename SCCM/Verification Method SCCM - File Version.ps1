<#
 Przed użyciem w SCCM zmień:
- $FilePath na pełną ścieżkę pliku z zasobem wersji
- $ExpectedVersion na wymaganą wersję, od 2 do 4 członów, np. 1.2.3.4
- $Compare na Equals (dokładnie ta wersja) albo Minimum (ta wersja lub nowsza)
- Wersja jest brana z liczb w zasobie pliku, nie z tekstu FileVersion. Write-Host i exit 0 zostaw bez zmian.
#>

$ErrorActionPreference = 'Stop'

$FilePath = 'C:\Program Files\App\app.exe'
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
    $expected = ConvertTo-FourPartVersion $ExpectedVersion
    if (-not $expected -or [string]::IsNullOrWhiteSpace($FilePath)) { exit 0 }
    if ($Compare -notin @('Equals', 'Minimum')) { exit 0 }

    $info = (Get-Item -LiteralPath $FilePath).VersionInfo
    $actual = [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)

    $match = if ($Compare -eq 'Minimum') { $actual -ge $expected } else { $actual -eq $expected }
    if ($match) { Write-Host 'Installed' }
} catch {}

exit 0
