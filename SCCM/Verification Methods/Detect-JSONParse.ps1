$Path = 'C:\ŚCIEŻKA\DO\pliku.json'
$ExpectedHost = 'addon.goskope.com'

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    exit 0
}

try {
    $config = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
} catch {
    exit 0
}

if ($config.host -eq $ExpectedHost) {
    Write-Output 'Installed'
}

exit 0
