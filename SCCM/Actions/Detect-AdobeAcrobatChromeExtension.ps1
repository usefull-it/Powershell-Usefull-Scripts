#Requires -Version 5.1
<#
.SYNOPSIS
    SCCM detection script. Paste this file into the deployment type detection method.

.DESCRIPTION
    Configuration Manager treats the deployment type as Installed only when this
    process exits 0 and STDOUT is not empty. Empty STDOUT with exit 0 means
    Not installed. Any non-zero exit, or empty STDOUT with text on STDERR, means
    Unknown and the install program will not run.

    STDOUT is written only when every copy of the extension folder is gone and
    the machine blocklist contains the extension id or "*". Do not add Write-Error,
    Write-Warning, or any other host output.

    Keep the constants and lookup functions identical to
    Remove-AdobeAcrobatChromeExtension.ps1.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ExtensionId = 'efaidnbmnnnibpcajpcglclefindmkaj'
$UserDataRelativeRoots = @(
    'AppData\Local\Google\User Data'
    'AppData\Local\Google\Chrome\User Data'
)
$BlocklistSubKey = 'SOFTWARE\Policies\Google\Chrome\ExtensionInstallBlocklist'
$SkippedProfileSids = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20')

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

try {
    $profiles = @(Get-UserProfileDirectories)
    $folders = @(Get-ExtensionDirectories -ProfileDirectories $profiles)
    if ($folders.Count -eq 0 -and (Test-ExtensionBlocked)) {
        Write-Host 'Removed'
    }
    exit 0
}
catch {
    exit 1
}
