# agy-session.ps1 — Anti-Gravity (agy) multi-account session manager
# Usage: agy-session [list|switch <matcher>|logout]
#
# agy on Windows stores credentials exclusively in Windows Credential Manager
# (target: gemini:antigravity). There is NO credential file.
#
# Directory structure:
#   sessions/<email>/<sub>/
#     credential.bin   — raw Credential Manager blob (access_token + refresh_token)
#     meta.json         — {email, name, sub, saved_at} from Google userinfo API

param(
    [string]$Command,
    [string]$Target
)

$ErrorActionPreference = "Stop"
$CredTarget = "gemini:antigravity"
$ProjectDir = $PSScriptRoot
$SessionsDir = Join-Path $ProjectDir "sessions"

# ============================================================================
# Windows Credential Manager (advapi32.dll) — x64 offset-based
# ============================================================================

$CredManDll = Join-Path $env:APPDATA "agy-session"
if (-not (Test-Path $CredManDll)) { New-Item -ItemType Directory -Force $CredManDll | Out-Null }
$CredManDllPath = Join-Path $CredManDll "CredMan.dll"

if (-not (Test-Path $CredManDllPath)) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class CredMan {
    const int O_FLAGS=0, O_TYPE=4, O_TARGET=8, O_COMMENT=16, O_LASTWRITTEN=24;
    const int O_BLOBSIZE=32, O_BLOB=40, O_PERSIST=48;
    const int O_ATTRCOUNT=52, O_ATTRS=56, O_TARGETALIAS=64, O_USER=72;

    public static byte[] Read(string target, out string userName) {
        userName = null;
        IntPtr p;
        if (!CredReadW(target, 1, 0, out p)) return null;
        try {
            int sz = Marshal.ReadInt32(p, O_BLOBSIZE);
            IntPtr bp = Marshal.ReadIntPtr(p, O_BLOB);
            userName = Marshal.PtrToStringUni(Marshal.ReadIntPtr(p, O_USER));
            byte[] b = new byte[sz];
            Marshal.Copy(bp, b, 0, sz);
            return b;
        } finally { CredFree(p); }
    }

    public static bool Write(string target, string userName, byte[] blob) {
        IntPtr p = Marshal.AllocHGlobal(80);
        try {
            Marshal.WriteInt32(p, O_FLAGS, 0);
            Marshal.WriteInt32(p, O_TYPE, 1);
            Marshal.WriteIntPtr(p, O_TARGET, S2P(target));
            Marshal.WriteIntPtr(p, O_COMMENT, IntPtr.Zero);
            Marshal.WriteInt64(p, O_LASTWRITTEN, 0);
            Marshal.WriteInt32(p, O_BLOBSIZE, blob.Length);
            IntPtr bc = Marshal.AllocHGlobal(blob.Length);
            Marshal.Copy(blob, 0, bc, blob.Length);
            Marshal.WriteIntPtr(p, O_BLOB, bc);
            Marshal.WriteInt32(p, O_PERSIST, 2);
            Marshal.WriteInt32(p, O_ATTRCOUNT, 0);
            Marshal.WriteIntPtr(p, O_ATTRS, IntPtr.Zero);
            Marshal.WriteIntPtr(p, O_TARGETALIAS, IntPtr.Zero);
            Marshal.WriteIntPtr(p, O_USER, S2P(userName ?? "antigravity"));
            return CredWriteW(p, 0);
        } finally {
            FP(Marshal.ReadIntPtr(p, O_TARGET)); FP(Marshal.ReadIntPtr(p, O_BLOB));
            FP(Marshal.ReadIntPtr(p, O_USER)); Marshal.FreeHGlobal(p);
        }
    }

    public static void Delete(string target) { CredDeleteW(target, 1, 0); }

    static IntPtr S2P(string s) => string.IsNullOrEmpty(s) ? IntPtr.Zero : Marshal.StringToHGlobalUni(s);
    static void FP(IntPtr p) { if (p != IntPtr.Zero) Marshal.FreeHGlobal(p); }

    [DllImport("advapi32", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool CredReadW(string t, int ty, int f, out IntPtr c);
    [DllImport("advapi32", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool CredWriteW(IntPtr c, int f);
    [DllImport("advapi32", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool CredDeleteW(string t, int ty, int f);
    [DllImport("advapi32")]
    static extern void CredFree(IntPtr b);
}
"@ -OutputAssembly $CredManDllPath
}
Add-Type -Path $CredManDllPath

# ============================================================================
# Credential Manager thin wrappers
# ============================================================================

function Read-Cred {
    $userName = $null
    $blob = [CredMan]::Read($CredTarget, [ref]$userName)
    if ($blob) { return [PSCustomObject]@{ UserName = $userName; Blob = $blob } }
    return $null
}

function Write-Cred($blob) {
    [CredMan]::Write($CredTarget, "antigravity", $blob) | Out-Null
}

function Remove-Cred {
    [CredMan]::Delete($CredTarget)
}

# ============================================================================
# Session Scanning
# ============================================================================

function Get-CurrentAccount {
    $cred = Read-Cred
    if (-not $cred) { return $null }
    return Get-Identity $cred.Blob
}

function Get-SavedAccounts {
    $accounts = @()
    if (-not (Test-Path $SessionsDir)) { return $accounts }
    foreach ($emailDir in Get-ChildItem $SessionsDir -Directory -ErrorAction SilentlyContinue) {
        foreach ($subDir in Get-ChildItem $emailDir.FullName -Directory -ErrorAction SilentlyContinue) {
            $metaFile = Join-Path $subDir.FullName "meta.json"
            $blobFile = Join-Path $subDir.FullName "credential.bin"
            if ((Test-Path $metaFile) -and (Test-Path $blobFile)) {
                try {
                    $meta = Get-Content $metaFile -Raw | ConvertFrom-Json
                    $accounts += [PSCustomObject]@{
                        Email    = $meta.email
                        Name     = $meta.name
                        Sub      = $meta.sub
                        SavedAt  = $meta.saved_at
                        BlobPath = $blobFile
                    }
                } catch {}
            }
        }
    }
    return $accounts | Sort-Object Email, Sub
}

# ============================================================================
# Account Identity (Google userinfo API — same method agy uses)
# ============================================================================

function Get-Identity($blob) {
    try {
        $data = [Text.Encoding]::UTF8.GetString($blob) | ConvertFrom-Json
        $activeRefresh = $data.token.refresh_token

        # 1. Fast Path: Local fingerprint match (Zero Network)
        if ($activeRefresh -and (Test-Path $SessionsDir)) {
            foreach ($emailDir in Get-ChildItem $SessionsDir -Directory -ErrorAction SilentlyContinue) {
                foreach ($subDir in Get-ChildItem $emailDir.FullName -Directory -ErrorAction SilentlyContinue) {
                    $blobFile = Join-Path $subDir.FullName "credential.bin"
                    $metaFile = Join-Path $subDir.FullName "meta.json"
                    if ((Test-Path $blobFile) -and (Test-Path $metaFile)) {
                        $savedBytes = Get-Content $blobFile -AsByteStream -ErrorAction SilentlyContinue
                        if ($savedBytes) {
                            $savedData = [Text.Encoding]::UTF8.GetString($savedBytes) | ConvertFrom-Json
                            if ($savedData.token.refresh_token -eq $activeRefresh) {
                                $meta = Get-Content $metaFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                                if ($meta) {
                                    return [PSCustomObject]@{ Email = $meta.email; Name = $meta.name; Sub = $meta.sub }
                                }
                            }
                        }
                    }
                }
            }
        }

        # 2. Slow Path: Network Fallback
        $token = $data.token.access_token
        $response = Invoke-RestMethod -Uri "https://openidconnect.googleapis.com/v1/userinfo" `
            -Headers @{Authorization="Bearer $token"} -TimeoutSec 5 -ErrorAction Stop
        return [PSCustomObject]@{ Email = $response.email; Name = $response.name; Sub = $response.sub }
    } catch { return $null }
}

# ============================================================================
# Save, Switch, Logout
# ============================================================================

function Save-Current {
    $cred = Read-Cred
    if (-not $cred) { return $null }

    $id = Get-Identity $cred.Blob
    if (-not $id) { return $null }

    $targetDir = Join-Path $SessionsDir (Join-Path $id.Email $id.Sub)
    New-Item -ItemType Directory -Force $targetDir | Out-Null
    $cred.Blob | Set-Content (Join-Path $targetDir "credential.bin") -AsByteStream

    $meta = @{ email = $id.Email; name = $id.Name; sub = $id.Sub; saved_at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
    ($meta | ConvertTo-Json) | Set-Content (Join-Path $targetDir "meta.json") -NoNewline

    return [PSCustomObject]@{ Email = $id.Email; Name = $id.Name; Sub = $id.Sub }
}

function Invoke-Switch($matcher) {
    $current = Save-Current
    $accounts = Get-SavedAccounts

    if ($accounts.Count -eq 0) {
        Write-Output "No saved accounts. Run 'agy-session' after logging in."
        exit 1
    }

    $target = $null

    # Match: exact email, sub prefix, or fuzzy email
    foreach ($a in $accounts) {
        if ($a.Email -eq $matcher) { $target = $a; break }
        if ($a.Sub.StartsWith($matcher)) { $target = $a; break }
        if ($a.Email -like "*$matcher*") { $target = $a; break }
    }

    if (-not $target) {
        Write-Output "No account matching '$matcher'. Run 'agy-session' to see saved accounts."
        exit 1
    }

    Write-Cred (Get-Content $target.BlobPath -AsByteStream)
    Write-Output "Switched to: $($target.Email)  [$($target.Name)]  (sub=$($target.Sub))"
}

function Invoke-Logout {
    $current = Save-Current
    Remove-Cred
    if ($current) {
        Write-Output "Logged out: $($current.Email)  [$($current.Name)]"
    } else {
        Write-Output "Logged out."
    }
    Write-Output "Log in with a new account, then run: agy-session"
}

# ============================================================================
# Table Rendering
# ============================================================================

function Write-Table($rows, $columns) {
    if ($rows.Count -eq 0) { return }
    $widths = @{}
    foreach ($col in $columns) { $widths[$col] = $col.Length }
    foreach ($row in $rows) {
        foreach ($col in $columns) {
            $val = if ($row.$col) { $row.$col.ToString() } else { "" }
            if ($val.Length -gt $widths[$col]) { $widths[$col] = $val.Length }
        }
    }
    $header = ""; $sep = ""
    foreach ($col in $columns) {
        $header += $col.PadRight($widths[$col] + 2)
        $sep += ("-" * $widths[$col]) + "  "
    }
    Write-Output $header; Write-Output $sep
    foreach ($row in $rows) {
        $line = ""
        foreach ($col in $columns) {
            $val = if ($row.$col) { $row.$col.ToString() } else { "" }
            $line += $val.PadRight($widths[$col] + 2)
        }
        Write-Output $line
    }
}

# ============================================================================
# Commands
# ============================================================================

function Invoke-List {
    $current = Save-Current
    $accounts = Get-SavedAccounts
    if ($accounts.Count -eq 0) { Write-Output "No saved accounts."; return }

    $curKey = if ($current) { "$($current.Email)|$($current.Sub)" } else { "" }
    $rows = @()
    foreach ($a in $accounts) {
        $rows += [PSCustomObject]@{
            A       = if ("$($a.Email)|$($a.Sub)" -eq $curKey) { "*" } else { "" }
            Email   = $a.Email
            Name    = $a.Name
            Sub     = $a.Sub
            SavedAt = $a.SavedAt
        }
    }
    Write-Output ""
    Write-Table $rows @("A", "Email", "Name", "Sub", "SavedAt")
    Write-Output ""
}

function Invoke-Interactive {
    $current = Save-Current
    if ($current) { Write-Output "Synced: $($current.Email)" }
    else { Write-Output "Not logged in. Run 'agy' to login first."; return }

    $accounts = Get-SavedAccounts
    if ($accounts.Count -eq 0) {
        Write-Output "No saved accounts yet. Run 'agy-session' again after switching accounts."
        return
    }

    $curKey = if ($current) { "$($current.Email)|$($current.Sub)" } else { "" }
    Write-Output ""
    for ($i = 0; $i -lt $accounts.Count; $i++) {
        $a = $accounts[$i]
        $marker = if ("$($a.Email)|$($a.Sub)" -eq $curKey) { "*" } else { " " }
        Write-Output "  [$i] $marker $($a.Email)  ($($a.Name))"
    }

    Write-Output "`n  [l] Full detail table"
    Write-Output "  [d] Logout (for new login)"
    Write-Output "  [q] Quit"
    $choice = Read-Host "`n>"

    switch ($choice) {
        'q' { return }
        'l' { Invoke-List }
        'd' { Invoke-Logout }
        default {
            if ($choice -match '^\d+$') {
                $idx = [int]$choice
                if ($idx -ge 0 -and $idx -lt $accounts.Count) {
                    Invoke-Switch $accounts[$idx].Email
                } else { Write-Output "Invalid index." }
            } else { Write-Output "Invalid choice." }
        }
    }
}

# ============================================================================
# Main
# ============================================================================

if (-not $Command) {
    Invoke-Interactive
} else {
    switch ($Command) {
        'list'   { Invoke-List }
        'switch' {
            if (-not $Target) { Write-Output "Usage: agy-session switch <email>"; exit 1 }
            Invoke-Switch $Target
        }
        'logout' { Invoke-Logout }
        default  { Write-Output "Unknown command. Usage: agy-session [list|switch|logout]"; exit 1 }
    }
}
