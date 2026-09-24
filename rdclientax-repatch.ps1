<#
.SYNOPSIS
    Re-applies the GetTempPath2W -> GetTempPathW import patch to WSL's rdclientax.dll.

.DESCRIPTION
    WSL bundles a Remote Desktop client (msrdc.exe + rdclientax.dll) for WSLg. Recent
    builds statically import kernel32!GetTempPath2W, which only exists on Windows 11
    (build 22000+) / Server 2022. On Windows 10 the loader fails with ERROR_PROC_NOT_FOUND
    (127) and msrdc shows a repeating "Entry Point Not Found" dialog naming rdclientax.dll.

    GetTempPath2W and GetTempPathW have identical signatures and identical behaviour for a
    process not running as SYSTEM/LocalService/NetworkService. msrdc runs as the interactive
    user under WSLg, so rewriting the import name is behaviour-preserving here.

    The patch is erased by every WSL update (the Store updates WSL automatically), hence
    this script. It locates the import entry by parsing the PE import table rather than
    using a fixed offset, so it keeps working across new WSL/MSRDC builds.

    Safety: verifies the DLL actually fails to load before touching it, backs up first,
    and automatically restores the backup if the patched file still does not load.

.PARAMETER DryRun
    Report what would change; write nothing.

.PARAMETER Restore
    Restore the most recent backup instead of patching.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\rdclientax-repatch.ps1

.NOTES
    Requires elevation (self-elevates via UAC). Breaks the file's Authenticode signature.
    Unsupported modification - the supported alternatives are disabling WSLg
    (guiApplications=false in .wslconfig) or upgrading to Windows 11.
#>
[CmdletBinding()]
param(
    [string]$DllPath = "C:\Program Files\WSL\rdclientax.dll",
    [switch]$DryRun,
    [switch]$Restore,
    [string]$LogTo
)

$ErrorActionPreference = 'Stop'
$OldName = "GetTempPath2W"
$NewName = "GetTempPathW"
$BackupDir = Join-Path $env:LOCALAPPDATA "rdclientax-backup"

$script:Lines = @()
function Say($msg) {
    $script:Lines += $msg
    Write-Host $msg
}

# ---------------------------------------------------------------- elevation --
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# -DryRun only reads, and Program Files is readable by standard users, so skip UAC there.
if (-not (Test-Admin) -and -not $DryRun) {
    $log = Join-Path $env:TEMP "rdclientax-repatch.log"
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
           '-DllPath', "`"$DllPath`"", '-LogTo', "`"$log`"")
    if ($DryRun)  { $a += '-DryRun' }
    if ($Restore) { $a += '-Restore' }

    Write-Host "Requesting elevation (approve the UAC prompt)..."
    try { Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList $a }
    catch { Write-Host "Elevation declined or failed: $($_.Exception.Message)"; exit 1 }

    if (Test-Path $log) { Get-Content $log | Write-Host; Remove-Item $log -Force }
    exit
}

# --------------------------------------------------------------- PE parsing --
function Get-PeInfo([byte[]]$b) {
    $lfanew = [BitConverter]::ToUInt32($b, 0x3C)
    if ([BitConverter]::ToUInt32($b, $lfanew) -ne 0x00004550) { throw "not a PE file" }
    $coff = $lfanew + 4
    $nsec = [BitConverter]::ToUInt16($b, $coff + 2)
    $optSize = [BitConverter]::ToUInt16($b, $coff + 16)
    $opt = $coff + 20
    $pe32p = ([BitConverter]::ToUInt16($b, $opt) -eq 0x20B)
    $ddOff = $opt + $(if ($pe32p) { 112 } else { 96 })

    $sections = @()
    $secOff = $opt + $optSize
    for ($i = 0; $i -lt $nsec; $i++) {
        $s = $secOff + ($i * 40)
        $sections += [pscustomobject]@{
            VirtualAddress  = [BitConverter]::ToUInt32($b, $s + 12)
            VirtualSize     = [BitConverter]::ToUInt32($b, $s + 8)
            SizeOfRawData   = [BitConverter]::ToUInt32($b, $s + 16)
            PointerToRawData= [BitConverter]::ToUInt32($b, $s + 20)
        }
    }
    [pscustomobject]@{
        Pe32Plus    = $pe32p
        Sections    = $sections
        ImportRva   = [BitConverter]::ToUInt32($b, $ddOff + (1 * 8))
    }
}

function Convert-RvaToOffset($pe, [uint32]$rva) {
    foreach ($s in $pe.Sections) {
        $span = [Math]::Max($s.VirtualSize, $s.SizeOfRawData)
        if ($rva -ge $s.VirtualAddress -and $rva -lt ($s.VirtualAddress + $span)) {
            return [int]($s.PointerToRawData + ($rva - $s.VirtualAddress))
        }
    }
    return -1
}

function Read-CString([byte[]]$b, [int]$off) {
    $end = $off
    while ($end -lt $b.Length -and $b[$end] -ne 0) { $end++ }
    [Text.Encoding]::ASCII.GetString($b, $off, $end - $off)
}

# Returns file offsets of every import-by-name string equal to $OldName.
function Find-ImportNameSites([byte[]]$b, $pe, [string]$target) {
    $sites = @()
    if ($pe.ImportRva -eq 0) { return $sites }
    $d = Convert-RvaToOffset $pe $pe.ImportRva
    if ($d -lt 0) { return $sites }

    $step = if ($pe.Pe32Plus) { 8 } else { 4 }

    while ($true) {
        $oft = [BitConverter]::ToUInt32($b, $d)
        $nameRva = [BitConverter]::ToUInt32($b, $d + 12)
        $ft = [BitConverter]::ToUInt32($b, $d + 16)
        if ($nameRva -eq 0) { break }

        $dll = Read-CString $b (Convert-RvaToOffset $pe $nameRva)
        $intRva = if ($oft -ne 0) { $oft } else { $ft }
        $t = Convert-RvaToOffset $pe $intRva

        if ($t -ge 0) {
            while ($true) {
                # Read as two DWORDs: avoids 64-bit literals, which PowerShell parses as
                # signed Int64 and overflows. Ordinal flag is the top bit of the thunk.
                $lo = [BitConverter]::ToUInt32($b, $t)
                $hi = if ($pe.Pe32Plus) { [BitConverter]::ToUInt32($b, $t + 4) } else { 0 }
                if ($lo -eq 0 -and $hi -eq 0) { break }

                $isOrdinal = if ($pe.Pe32Plus) { ($hi -shr 31) -eq 1 } else { ($lo -shr 31) -eq 1 }
                if (-not $isOrdinal) {
                    $strOff = Convert-RvaToOffset $pe ([uint32]($lo -band 0x7FFFFFFF))
                    if ($strOff -ge 0) {
                        # +2 skips the 2-byte hint
                        if ((Read-CString $b ($strOff + 2)) -eq $target) {
                            $sites += [pscustomobject]@{ Dll = $dll; Offset = $strOff + 2 }
                        }
                    }
                }
                $t += $step
            }
        }
        $d += 20
    }
    return $sites
}

# ------------------------------------------------------------- loader probe --
if (-not ("NativeLoader" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NativeLoader {
  [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr LoadLibraryExW(string f, IntPtr h, uint flags);
  [DllImport("kernel32", SetLastError=true)]
  public static extern bool FreeLibrary(IntPtr h);
}
'@
}

function Test-Loads([string]$path) {
    $h = [NativeLoader]::LoadLibraryExW($path, [IntPtr]::Zero, 0x8) # ALTERED_SEARCH_PATH
    if ($h -eq [IntPtr]::Zero) {
        $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        return [pscustomobject]@{
            Ok = $false; Err = $e
            Msg = (New-Object System.ComponentModel.Win32Exception($e)).Message
        }
    }
    [void][NativeLoader]::FreeLibrary($h)   # release so the file is not locked
    [pscustomobject]@{ Ok = $true; Err = 0; Msg = "loaded" }
}

function Get-Md5([string]$p) { (Get-FileHash $p -Algorithm MD5).Hash }

function Unlock-File([string]$p) {
    & takeown /f "$p" 2>&1 | Out-Null
    & icacls "$p" /grant "*S-1-5-32-544:(F)" 2>&1 | Out-Null
    Set-ItemProperty -Path $p -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- main flow --
try {
    Say "=== rdclientax GetTempPath2W re-patch ==="
    Say "target : $DllPath"

    if (-not (Test-Path $DllPath)) { Say "ERROR: file not found. Is WSL installed?"; exit 1 }

    $ver = (Get-Item $DllPath).VersionInfo.FileVersion
    Say ("version: {0}   md5: {1}" -f $ver, (Get-Md5 $DllPath))

    # ---- restore mode
    if ($Restore) {
        if (-not (Test-Path $BackupDir)) { Say "no backup directory at $BackupDir"; exit 1 }
        $bk = Get-ChildItem $BackupDir -Filter *.bak | Sort-Object LastWriteTime -Desc |
              Select-Object -First 1
        if (-not $bk) { Say "no backups found in $BackupDir"; exit 1 }
        Say "restoring $($bk.FullName)"
        if ($DryRun) { Say "[dry run] would restore and stop"; exit 0 }
        Get-Process msrdc -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 2
        Unlock-File $DllPath
        Copy-Item $bk.FullName $DllPath -Force
        Say ("restored. md5 now {0}" -f (Get-Md5 $DllPath))
        exit 0
    }

    # ---- is the patch even needed?
    $before = Test-Loads $DllPath
    if ($before.Ok) {
        Say "DLL already loads cleanly - nothing to do."
        Say "(either already patched, or this build no longer needs GetTempPath2W)"
        exit 0
    }
    Say ("load fails: err={0} ({1})" -f $before.Err, $before.Msg)
    if ($before.Err -ne 127) {
        Say "That is NOT ERROR_PROC_NOT_FOUND(127), so this is a different fault."
        Say "Refusing to patch - investigate before forcing anything."
        exit 1
    }

    # ---- locate the import entry
    $bytes = [IO.File]::ReadAllBytes($DllPath)
    $pe = Get-PeInfo $bytes
    # @() forces an array - PowerShell unrolls a single-element result to a scalar
    $sites = @(Find-ImportNameSites $bytes $pe $OldName)

    if ($sites.Count -eq 0) {
        Say "No static import of $OldName found, yet load fails with 127."
        Say "A different symbol is missing. Refusing to patch."
        exit 1
    }
    foreach ($s in $sites) {
        Say ("found import {0} -> {1} at file offset 0x{2:X}" -f $s.Dll, $OldName, $s.Offset)
    }

    if ($DryRun) { Say "[dry run] would patch $($sites.Count) site(s); nothing written."; exit 0 }

    # ---- back up
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir | Out-Null }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backup = Join-Path $BackupDir "rdclientax-$ver-$stamp.bak"
    Copy-Item $DllPath $backup -Force
    Say "backup : $backup"

    # ---- stop the crash-looping client so nothing holds the file
    $p = Get-Process msrdc -ErrorAction SilentlyContinue
    if ($p) { $p | Stop-Process -Force; Say ("stopped msrdc PID(s): " + ($p.Id -join ',')) }
    Start-Sleep -Seconds 2

    # ---- patch in memory: overwrite name in place (new name is 1 byte shorter,
    #      so its terminator fits and the original terminator becomes padding)
    $new = [Text.Encoding]::ASCII.GetBytes($NewName)
    foreach ($s in $sites) {
        for ($i = 0; $i -lt $new.Length; $i++) { $bytes[$s.Offset + $i] = $new[$i] }
        $bytes[$s.Offset + $new.Length] = 0
    }

    Unlock-File $DllPath
    [IO.File]::WriteAllBytes($DllPath, $bytes)
    Say ("patched. md5 now {0}" -f (Get-Md5 $DllPath))

    # ---- verify, auto-rollback on failure
    $after = Test-Loads $DllPath
    if ($after.Ok) {
        Say "VERIFIED: DLL now loads successfully."
        Say "Restart WSLg (wsl --shutdown) or just let msrdc respawn."
        exit 0
    }

    Say ("STILL FAILING: err={0} ({1})" -f $after.Err, $after.Msg)
    Say "Rolling back to the backup..."
    Unlock-File $DllPath
    Copy-Item $backup $DllPath -Force
    Say ("rolled back. md5 {0}" -f (Get-Md5 $DllPath))
    Say "A newer MSRDC build likely needs more than this one symbol."
    Say "Fall back to guiApplications=false in .wslconfig, or pin an older WSL."
    exit 1
}
catch {
    Say ("ERROR: " + $_.Exception.Message)
    exit 1
}
finally {
    if ($LogTo) { $script:Lines | Out-File -FilePath $LogTo -Encoding ascii }
}
