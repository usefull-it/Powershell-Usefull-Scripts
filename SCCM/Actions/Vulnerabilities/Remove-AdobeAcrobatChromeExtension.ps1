#Requires -Version 5.1
<#
.SYNOPSIS
    Removes the Adobe Acrobat PDF Chrome extension from every local user profile.

.DESCRIPTION
    Deletes this folder from every browser profile under each Windows user profile:

        AppData\Local\Google\User Data\<profile>\Extensions\efaidnbmnnnibpcajpcglclefindmkaj
        AppData\Local\Google\Chrome\User Data\<profile>\Extensions\efaidnbmnnnibpcajpcglclefindmkaj

    The second path is the documented Chrome location. The first is the path observed
    on the vulnerable machines. <profile> is Default, Profile 1, and any other directory.

    Chrome reinstalls an extension that is still registered, so the script also:
      - adds the extension id to the machine ExtensionInstallBlocklist
      - removes a machine-wide external-extension registration for the same id

    Chrome is closed only when at least one extension folder is present, because a
    running browser locks those files and can recreate them on exit.

    Exit 0: no extension folder remains and the blocklist contains the id (or "*").
    Exit 1: a folder is still present, the blocklist was not written, or the script failed.

    SCCM installation program (deployment type: Script Installer):
        powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\Remove-AdobeAcrobatChromeExtension.ps1

    Installation behavior: Install for system.
    Logon requirement: Whether or not a user is logged on.
    Leave "Run installation and uninstall program as 32-bit process on 64-bit clients" unchecked.
    The script opens the 64-bit registry view itself.

    Keep the constants below identical to Detect-AdobeAcrobatChromeExtension.ps1.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ExtensionId = 'efaidnbmnnnibpcajpcglclefindmkaj'
$UserDataRelativeRoots = @(
    'AppData\Local\Google\User Data'
    'AppData\Local\Google\Chrome\User Data'
)
$BlocklistSubKey = 'SOFTWARE\Policies\Google\Chrome\ExtensionInstallBlocklist'
$ExternalSubKeys = @(
    "SOFTWARE\Google\Chrome\Extensions\$ExtensionId"
    "SOFTWARE\WOW6432Node\Google\Chrome\Extensions\$ExtensionId"
)
$SkippedProfileSids = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')
$LogPath = Join-Path $env:ProgramData 'Remove-AdobeAcrobatChromeExtension.log'

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding Ascii
}

function Open-LocalMachine64 {
    return [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64)
}

function Get-UserProfileDirectories {
    $found = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    function Add-ProfilePath {
        param([string]$RawPath)
        if ([string]::IsNullOrWhiteSpace($RawPath)) { return }
        $expanded = [Environment]::ExpandEnvironmentVariables($RawPath)
        $full = [System.IO.Path]::GetFullPath($expanded)
        $key = $full.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { return }
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { return }
        $seen[$key] = $true
        $found.Add($full)
    }

    $base = Open-LocalMachine64
    try {
        $profileList = $base.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList', $false)
        if (-not $profileList) {
            throw 'HKLM ProfileList is missing.'
        }
        try {
            # Default user template is not a SID subkey. New profiles are copied from it.
            Add-ProfilePath -RawPath ([string]$profileList.GetValue('Default'))

            foreach ($sid in $profileList.GetSubKeyNames()) {
                if ($sid.EndsWith('.bak')) { continue }
                if ($SkippedProfileSids -contains $sid) { continue }

                $sidKey = $profileList.OpenSubKey($sid, $false)
                if (-not $sidKey) { continue }
                try {
                    Add-ProfilePath -RawPath ([string]$sidKey.GetValue('ProfileImagePath'))
                }
                finally {
                    $sidKey.Close()
                }
            }
        }
        finally {
            $profileList.Close()
        }
    }
    finally {
        $base.Close()
    }

    return $found
}

function Test-ReparsePoint {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $item = Get-Item -LiteralPath $LiteralPath -Force
    return [bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Get-ExtensionDirectories {
    param([Parameter(Mandatory)][string[]]$ProfileDirectories)

    $found = New-Object System.Collections.Generic.List[string]
    foreach ($profile in $ProfileDirectories) {
        foreach ($relativeRoot in $UserDataRelativeRoots) {
            $userData = Join-Path $profile $relativeRoot
            if (-not (Test-Path -LiteralPath $userData -PathType Container)) { continue }
            if (Test-ReparsePoint -LiteralPath $userData) {
                throw "Refusing to walk a reparse point: $userData"
            }

            foreach ($browserProfile in @(Get-ChildItem -LiteralPath $userData -Force -Directory)) {
                if ($browserProfile.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    throw "Refusing to walk a reparse point: $($browserProfile.FullName)"
                }
                $candidate = Join-Path $browserProfile.FullName "Extensions\$ExtensionId"
                if (Test-Path -LiteralPath $candidate -PathType Container) {
                    $found.Add($candidate)
                }
            }
        }
    }

    return $found
}

function Test-ExtensionBlocked {
    $base = Open-LocalMachine64
    try {
        $key = $base.OpenSubKey($BlocklistSubKey, $false)
        if (-not $key) { return $false }
        try {
            foreach ($name in $key.GetValueNames()) {
                $value = [string]$key.GetValue($name)
                if ($value -eq $ExtensionId -or $value -eq '*') { return $true }
            }
            return $false
        }
        finally {
            $key.Close()
        }
    }
    finally {
        $base.Close()
    }
}

function Set-ExtensionBlocked {
    $base = Open-LocalMachine64
    try {
        $key = $base.CreateSubKey($BlocklistSubKey)
        if (-not $key) { throw "Could not create HKLM\$BlocklistSubKey" }
        try {
            foreach ($name in $key.GetValueNames()) {
                $value = [string]$key.GetValue($name)
                if ($value -eq $ExtensionId -or $value -eq '*') {
                    Write-Log "Blocklist already contains '$value'."
                    return
                }
            }

            $next = 1
            foreach ($name in $key.GetValueNames()) {
                $parsed = 0
                if ([int]::TryParse($name, [ref]$parsed) -and $parsed -ge $next) {
                    $next = $parsed + 1
                }
            }

            $key.SetValue($next.ToString(), $ExtensionId, [Microsoft.Win32.RegistryValueKind]::String)
            Write-Log "Added blocklist value $next = $ExtensionId"
        }
        finally {
            $key.Close()
        }
    }
    finally {
        $base.Close()
    }
}

function Remove-ExternalRegistration {
    $base = Open-LocalMachine64
    try {
        foreach ($subKey in $ExternalSubKeys) {
            try {
                $base.DeleteSubKeyTree($subKey)
                Write-Log "Deleted HKLM\$subKey"
            }
            catch {
                # PowerShell wraps the .NET ArgumentException from a missing key.
                $inner = $_.Exception
                while ($inner.InnerException) { $inner = $inner.InnerException }
                if ($inner -isnot [System.ArgumentException]) { throw }
                Write-Log "No HKLM\$subKey"
            }
        }
    }
    finally {
        $base.Close()
    }
}

function Clear-ReadOnlyAttribute {
    param([Parameter(Mandatory)][System.IO.FileSystemInfo]$Item)
    if ($Item.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
        $Item.Attributes = $Item.Attributes -bxor [System.IO.FileAttributes]::ReadOnly
    }
}

function Remove-TreeNoFollow {
    param([Parameter(Mandatory)][string]$LiteralPath)

    if (Test-ReparsePoint -LiteralPath $LiteralPath) {
        throw "Refusing to delete a reparse point: $LiteralPath"
    }

    # Windows PowerShell 5.1: Remove-Item -Recurse has a known issue.
    # Enumerate children and delete them directly instead. Do not use -Recurse,
    # so a junction inside the tree cannot be followed.
    foreach ($child in @(Get-ChildItem -LiteralPath $LiteralPath -Force)) {
        if ($child.PSIsContainer) {
            Remove-TreeNoFollow -LiteralPath $child.FullName
        }
        else {
            Clear-ReadOnlyAttribute -Item $child
            Remove-Item -LiteralPath $child.FullName -Force
        }
    }

    $directory = Get-Item -LiteralPath $LiteralPath -Force
    Clear-ReadOnlyAttribute -Item $directory
    Remove-Item -LiteralPath $LiteralPath -Force
}

function Remove-ExtensionDirectory {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if (-not (Test-Path -LiteralPath $LiteralPath)) { return $true }

    try {
        Remove-TreeNoFollow -LiteralPath $LiteralPath
    }
    catch {
        Write-Log "Delete failed for ${LiteralPath}: $($_.Exception.Message)"
        return $false
    }

    return -not (Test-Path -LiteralPath $LiteralPath)
}

function Stop-ChromeProcesses {
    Write-Log 'Stopping chrome.exe so the extension files can be deleted.'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $processes = @(Get-Process -Name 'chrome' -ErrorAction SilentlyContinue)
        if ($processes.Count -eq 0) { return }
        foreach ($process in $processes) {
            try {
                $process.Kill()
            }
            catch {
                Write-Log "Could not stop chrome.exe pid $($process.Id): $($_.Exception.Message)"
            }
        }
        Start-Sleep -Seconds 2
    }
}

$failed = $false
try {
    Write-Log 'Start'
    Set-ExtensionBlocked
    Remove-ExternalRegistration

    $profiles = @(Get-UserProfileDirectories)
    Write-Log ("Profiles in scope: {0}" -f $profiles.Count)

    $folders = @(Get-ExtensionDirectories -ProfileDirectories $profiles)
    if ($folders.Count -gt 0) {
        Stop-ChromeProcesses
        foreach ($folder in $folders) {
            Write-Log "Removing $folder"
            $removed = Remove-ExtensionDirectory -LiteralPath $folder
            if (-not $removed) {
                Start-Sleep -Seconds 2
                $removed = Remove-ExtensionDirectory -LiteralPath $folder
            }
            if (-not $removed) {
                Write-Log "Still present: $folder"
                $failed = $true
            }
        }
    }

    $remaining = @(Get-ExtensionDirectories -ProfileDirectories $profiles)
    foreach ($folder in $remaining) {
        Write-Log "Remaining folder: $folder"
        $failed = $true
    }
    if (-not (Test-ExtensionBlocked)) {
        Write-Log 'Blocklist does not contain the extension id.'
        $failed = $true
    }
}
catch {
    Write-Log "FAILED: $($_.Exception.Message)"
    exit 1
}

if ($failed) {
    Write-Log 'Finished with remaining extension folders or without the blocklist.'
    exit 1
}

Write-Log 'Success'
exit 0
