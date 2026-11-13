# W katalogu treści SCCM muszą leżeć ten instalator, Status Migracji.bat,
# MigrationPanel.ps1 oraz MigrationIcon.ico.
# Proponowana komenda instalacji:
# powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-WsparcieMigracja.ps1

$panelSource = Join-Path $PSScriptRoot 'MigrationPanel.ps1'
$batchSource = Join-Path $PSScriptRoot 'Status Migracji.bat'
$iconSource = Join-Path $PSScriptRoot 'MigrationIcon.ico'

if (-not (Test-Path -LiteralPath $panelSource)) {
    Write-Error "Brak pliku zrodlowego: $panelSource"
    exit 1
}
if (-not (Test-Path -LiteralPath $batchSource)) {
    Write-Error "Brak pliku zrodlowego: $batchSource"
    exit 1
}
if (-not (Test-Path -LiteralPath $iconSource)) {
    Write-Error "Brak pliku zrodlowego: $iconSource"
    exit 1
}

$toolDir = 'C:\temp\NarzedziaMigracyjne'
if (-not (Test-Path -LiteralPath $toolDir)) {
    New-Item -ItemType Directory -Path $toolDir -ErrorAction Stop | Out-Null
}
Copy-Item -LiteralPath $panelSource -Destination (Join-Path $toolDir 'MigrationPanel.ps1') -Force -ErrorAction Stop
Copy-Item -LiteralPath $batchSource -Destination (Join-Path $toolDir 'Status Migracji.bat') -Force -ErrorAction Stop
Copy-Item -LiteralPath $iconSource -Destination (Join-Path $toolDir 'MigrationIcon.ico') -Force -ErrorAction Stop

# Tylko skrót .lnk. Innych plików w tym folderze nie usuwamy ani nie nadpisujemy.
$desktopDir = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'WSPARCIE_MIGRACJA'
if (-not (Test-Path -LiteralPath $desktopDir)) {
    New-Item -ItemType Directory -Path $desktopDir -ErrorAction Stop | Out-Null
}

$shortcutPath = Join-Path $desktopDir 'Status Migracji.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $toolDir 'Status Migracji.bat'
$shortcut.WorkingDirectory = $toolDir
$shortcut.IconLocation = (Join-Path $toolDir 'MigrationIcon.ico') + ',0'
$shortcut.WindowStyle = 1
$shortcut.Save()

exit 0
