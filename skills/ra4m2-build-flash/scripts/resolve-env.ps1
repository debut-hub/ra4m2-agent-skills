#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Locate the Renesas e² studio / FSP installation and Renesas Flash Programmer
  on THIS machine. Nothing is hardcoded to one user's disk layout.

.DESCRIPTION
  Resolution order, first hit wins:
    1. Explicit parameters (-E2Studio, -Rfp)
    2. Environment variables (RA4M2_E2STUDIO, RA4M2_RFP)
    3. Windows registry uninstall entries (works for default installs)
    4. Candidate roots + version-glob scan (works for custom install dirs)

  Output is JSON on stdout so an agent (or another script) can consume it.
  Human-readable help: -Help

.PARAMETER E2Studio
  Path to the e² studio install root, the `eclipse` folder, or `e2studio.exe`.

.PARAMETER Rfp
  Path to `rfp-cli.exe`, an RFP install folder, or `RFPV3.exe`.

.PARAMETER Quiet
  Suppress the non-JSON diagnostic lines on stderr.

.PARAMETER SearchRoot
  Extra directory root to scan for an e² studio install. Repeatable. Used by the
  test suite to simulate machines whose tools live in unusual places. Registry and
  environment discovery still run first, so this only widens the scan.

.EXAMPLE
  pwsh -File resolve-env.ps1
  # {"ok":true,"e2studio":{...},"toolchain":{...},"make":{...},"rfp":{...},"serial":{...}}

.EXAMPLE
  $env:RA4M2_E2STUDIO = 'E:\Tools\e2studio'
  pwsh -File resolve-env.ps1
#>
[CmdletBinding()]
param(
    [string]$E2Studio,
    [string]$Rfp,
    [string[]]$SearchRoot = @(),
    [switch]$Help,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    exit 0
}

# Diagnostics go straight to the process stderr via .NET, bypassing PowerShell's
# stream system entirely. That guarantees stdout holds ONLY the JSON payload, so
# `$json = & script.ps1 2>$null | ConvertFrom-Json` always works.
function Write-Note($msg) { if (-not $Quiet) { [Console]::Error.WriteLine("[resolve-env] $msg") } }

# --------------------------------------------------------------------------
# Registry: uninstall entries are the most reliable signal for default installs
# --------------------------------------------------------------------------
function Get-FromRegistry {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entries = @()
    foreach ($k in $keys) {
        try { $entries += Get-ItemProperty $k -ErrorAction SilentlyContinue } catch { }
    }

    $e2 = $null
    $rfp = $null

    foreach ($e in $entries) {
        if (-not $e.DisplayName) { continue }
        $loc = $e.InstallLocation
        if (-not $loc) { $loc = $e.DisplayIcon }

        # e² studio + FSP bundle, e.g. "Renesas RA Flexible Software Package (FSP) v6.6.0 with e² studio 2026-07"
        if (-not $e2 -and $e.DisplayName -match 'e2\s*studio|e²\s*studio') {
            if ($loc) {
                $loc = $loc -replace '\\uninstall.*$','' -replace '\\$',''
                if (Test-Path $loc) { $e2 = $loc }
            }
        }
        # Renesas Flash Programmer, e.g. "Renesas Flash Programmer V3.24"
        if (-not $rfp -and $e.DisplayName -match 'Flash Programmer') {
            $cand = @()
            if ($loc) { $cand += $loc }
            if ($e.UninstallString -match '^"?(.*?)(uninstall|msiexec)') { }
            foreach ($c in $cand) {
                $found = Find-RfpUnder $c
                if ($found) { $rfp = $found; break }
            }
        }
    }
    return [PSCustomObject]@{ E2Studio = $e2; Rfp = $rfp }
}

# Search a directory tree (bounded depth) for a file name.
function Find-FileUnder {
    param([string]$Root, [string]$Name, [int]$Depth = 4)
    if (-not $Root -or -not (Test-Path $Root)) { return $null }
    # direct hit
    $direct = Join-Path $Root $Name
    if (Test-Path $direct) { return (Resolve-Path $direct).Path }
    # bounded recursive search
    try {
        $hit = Get-ChildItem -Path $Root -Filter $Name -Recurse -Depth $Depth -File -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    } catch { }
    return $null
}

function Find-RfpUnder([string]$Root) { Find-FileUnder -Root $Root -Name 'rfp-cli.exe' -Depth 5 }

# --------------------------------------------------------------------------
# e² studio normalisation: accept the install root, the eclipse folder, or the exe
# --------------------------------------------------------------------------
function Resolve-E2Studio([string]$Hint) {
    if (-not $Hint -or -not (Test-Path $Hint)) { return $null }

    $p = (Resolve-Path $Hint).Path

    if (Test-Path $p -PathType Leaf) {
        if ((Split-Path $p -Leaf) -match '^e2studio\.exe$') { $p = Split-Path $p -Parent }
        else { return $null }
    }
    # p may now be the eclipse dir or the install root
    if ((Split-Path $p -Leaf) -eq 'eclipse') { return (Split-Path $p -Parent) }
    if (Test-Path (Join-Path $p 'eclipse\e2studio.exe')) { return $p }
    # maybe it IS the eclipse dir named something else
    if (Test-Path (Join-Path $p 'e2studio.exe')) { return (Split-Path $p -Parent) }
    return $null
}

# --------------------------------------------------------------------------
# Candidate roots for a custom install location
# --------------------------------------------------------------------------
function Get-CandidateRoots {
    $roots = @()
    # Explicitly requested scan roots come first (used by tests / unusual layouts)
    $roots += $SearchRoot
    foreach ($drive in @('C:','D:','E:','F:')) {
        if (Test-Path "$drive\") {
            $roots += "$drive\Renesas\RA"
            $roots += "$drive\Renesas"
            $roots += "$drive\Program Files\Renesas\RA"
            $roots += "$drive\Program Files (x86)\Renesas\RA"
        }
    }
    $roots += Join-Path $env:USERPROFILE 'Renesas\RA'
    $roots += Join-Path $env:LOCALAPPDATA 'Renesas\RA'
    # de-dupe, keep existing
    $roots | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
}

function Find-E2StudioByScan {
    foreach ($root in Get-CandidateRoots) {
        # Match any e2studio_v*/e2studio_* directory that contains eclipse\e2studio.exe
        $hits = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'e2studio' } |
                Sort-Object Name -Descending
        foreach ($h in $hits) {
            if (Test-Path (Join-Path $h.FullName 'eclipse\e2studio.exe')) { return $h.FullName }
        }
        # one more level (some layouts nest under a vendor folder)
        $deeper = Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue
        foreach ($d in $deeper) {
            $hits2 = Get-ChildItem -Path $d.FullName -Directory -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -match 'e2studio' } |
                     Sort-Object Name -Descending
            foreach ($h in $hits2) {
                if (Test-Path (Join-Path $h.FullName 'eclipse\e2studio.exe')) { return $h.FullName }
            }
        }
    }
    return $null
}

function Find-RfpByScan {
    $roots = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Renesas Electronics'),
        (Join-Path $env:ProgramFiles 'Renesas Electronics'),
        'C:\Renesas Electronics','D:\Renesas Electronics','E:\Renesas Electronics',
        (Join-Path $env:LOCALAPPDATA 'Renesas Electronics')
    )
    # Extra scan roots (tests / unusual layouts)
    foreach ($s in $SearchRoot) { $roots += $s }
    $roots = $roots | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    foreach ($r in $roots) {
        $hit = Find-RfpUnder $r
        if ($hit) { return $hit }
    }
    return $null
}

# --------------------------------------------------------------------------
# Toolchain inside the e² studio install: glob it, never hardcode a version
# --------------------------------------------------------------------------
function Resolve-GccBin([string]$E2SRoot) {
    if (-not $E2SRoot) { return $null }
    $tcRoot = Join-Path $E2SRoot 'toolchains\gcc_arm'
    if (-not (Test-Path $tcRoot)) { return $null }

    $candidates = Get-ChildItem -Path $tcRoot -Directory -ErrorAction SilentlyContinue
    # Prefer the exact file; the folder name is not a reliable version signal.
    foreach ($c in $candidates) {
        $bin = Join-Path $c.FullName 'bin'
        if (Test-Path (Join-Path $bin 'arm-none-eabi-gcc.exe')) { return $bin }
    }
    # legacy layout: toolchains\gcc_arm\<version>\bin
    foreach ($c in $candidates) {
        $deep = Get-ChildItem -Path $c.FullName -Directory -ErrorAction SilentlyContinue
        foreach ($d in $deep) {
            $bin = Join-Path $d.FullName 'bin'
            if (Test-Path (Join-Path $bin 'arm-none-eabi-gcc.exe')) { return $bin }
        }
    }
    return $null
}

function Resolve-Make([string]$E2SRoot) {
    if (-not $E2SRoot) { return $null }
    $plugins = Join-Path $E2SRoot 'eclipse\plugins'
    if (-not (Test-Path $plugins)) { return $null }
    # glob the plugin folder: the version suffix changes between releases
    $hit = Get-ChildItem -Path $plugins -Directory -Filter 'com.renesas.ide.exttools.gnumake.*' -ErrorAction SilentlyContinue |
           Sort-Object Name -Descending |
           ForEach-Object { Find-FileUnder -Root $_.FullName -Name 'make.exe' -Depth 3 } |
           Where-Object { $_ } | Select-Object -First 1
    return $hit
}

# --------------------------------------------------------------------------
# Serial: never assume COM3
# --------------------------------------------------------------------------
function Get-SerialPorts {
    $names = @()
    try { $names = @([System.IO.Ports.SerialPort]::GetPortNames()) } catch { }

    # Device path from the registry, e.g. "\Device\Serial2" -> helps identify the driver
    $devMap = @{}
    try {
        $map = Get-ItemProperty 'HKLM:\HARDWARE\DEVICEMAP\SERIALCOMM' -ErrorAction SilentlyContinue
        if ($map) {
            $map.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object {
                $devMap[$_.Value] = $_.Name
            }
        }
    } catch { }

    # USB serial adapters present, so we can tell whether the port is CH340-based
    $usbSerials = Get-UsbSerialSummary
    $hasCh340 = [bool]($usbSerials | Where-Object { $_.Instance -match 'VID_1A86' })

    $detail = @()
    foreach ($n in $names) {
        $desc = if ($devMap.ContainsKey($n)) { $devMap[$n] } else { $null }
        # A CH340 board shows up as a CH34x service; if the only USB serial adapter
        # present is a CH340 we can attribute the port to it.
        $isCh = $hasCh340 -and ($devMap.ContainsKey($n))
        $detail += [PSCustomObject]@{
            Port        = $n
            Description = $desc
            IsCh340     = [bool]$isCh
        }
    }
    return @($detail)
}

function Get-UsbSerialSummary {
    # Which USB serial-ish devices are present (helps pick the right port)
    $found = @()
    try {
        $usb = 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB'
        if (Test-Path $usb) {
            Get-ChildItem $usb -ErrorAction SilentlyContinue | ForEach-Object {
                $vid = $_.PSChildName
                $svc = ''
                $sub = Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue
                if ($sub) { $svc = (Get-ItemProperty $sub[0].PSPath -ErrorAction SilentlyContinue).Service }
                if ($svc -match 'CH34|usbser|VCP|JLink|WinUSB') {
                    $found += [PSCustomObject]@{ Instance = $vid; Service = $svc }
                }
            }
        }
    } catch { }
    return $found
}

# ==========================================================================
# Resolve everything
# ==========================================================================
$source = [ordered]@{ e2studio = 'not-found'; rfp = 'not-found' }

# --- e² studio ---
$e2root = $null
if ($E2Studio)                      { $e2root = Resolve-E2Studio $E2Studio; if ($e2root) { $source.e2studio = 'parameter' } }
if (-not $e2root -and $env:RA4M2_E2STUDIO) { $e2root = Resolve-E2Studio $env:RA4M2_E2STUDIO; if ($e2root) { $source.e2studio = 'env:RA4M2_E2STUDIO' } }
if (-not $e2root) {
    $reg = Get-FromRegistry
    if ($reg.E2Studio) { $e2root = Resolve-E2Studio $reg.E2Studio; if ($e2root) { $source.e2studio = 'registry' } }
}
if (-not $e2root) { $e2root = Find-E2StudioByScan; if ($e2root) { $source.e2studio = 'scan' } }

# --- RFP ---
$rfpPath = $null
if ($Rfp) {
    $rfpPath = if ((Test-Path $Rfp) -and (Split-Path $Rfp -Leaf) -eq 'rfp-cli.exe') { (Resolve-Path $Rfp).Path }
               else { Find-RfpUnder $Rfp }
    if ($rfpPath) { $source.rfp = 'parameter' }
}
if (-not $rfpPath -and $env:RA4M2_RFP) {
    $rfpPath = if ((Test-Path $env:RA4M2_RFP) -and (Split-Path $env:RA4M2_RFP -Leaf) -eq 'rfp-cli.exe') { (Resolve-Path $env:RA4M2_RFP).Path }
               else { Find-RfpUnder $env:RA4M2_RFP }
    if ($rfpPath) { $source.rfp = 'env:RA4M2_RFP' }
}
if (-not $rfpPath) {
    $reg = Get-FromRegistry
    if ($reg.Rfp) { $rfpPath = $reg.Rfp; $source.rfp = 'registry' }
}
if (-not $rfpPath) { $rfpPath = Find-RfpByScan; if ($rfpPath) { $source.rfp = 'scan' } }

# --- derived ---
$gccBin = Resolve-GccBin $e2root
$makeExe = Resolve-Make $e2root

# --- serial (computed before the result object so Get-SerialPorts can reuse it) ---
$usbSummary = @(Get-UsbSerialSummary)
$serialPorts = @(Get-SerialPorts)

$result = [ordered]@{
    ok        = [bool]($e2root -and $gccBin)
    resolvedBy = $source
    e2studio  = [ordered]@{
        root = $e2root
        exe  = if ($e2root) { Join-Path $e2root 'eclipse\e2studio.exe' } else { $null }
    }
    toolchain = [ordered]@{ gccBin = $gccBin }
    make      = [ordered]@{ exe = $makeExe }
    rfp       = [ordered]@{
        exe = $rfpPath
        dir = if ($rfpPath) { Split-Path $rfpPath -Parent } else { $null }
    }
    serial    = [ordered]@{
        # Force arrays: a single port must still serialize as a JSON array.
        ports = @($serialPorts)
        usb   = @($usbSummary)
    }
    notes = @()
}

if (-not $e2root) { $result.notes += 'e² studio not found. Set $env:RA4M2_E2STUDIO to its install root, or install it.' }
if ($e2root -and -not $gccBin) { $result.notes += 'e² studio found but no ARM GCC toolchain under toolchains\gcc_arm.' }
if (-not $makeExe) { $result.notes += 'make.exe not found under eclipse\plugins\com.renesas.ide.exttools.gnumake.*' }
if (-not $rfpPath) { $result.notes += 'RFP not found. Set $env:RA4M2_RFP to rfp-cli.exe, or install Renesas Flash Programmer.' }
if ($result.serial.ports.Count -eq 0) { $result.notes += 'No serial ports detected. Is the board connected?' }

Write-Note "e2studio : $e2root  [$($source.e2studio)]"
Write-Note "gccBin   : $gccBin"
Write-Note "make     : $makeExe"
Write-Note "rfp      : $rfpPath  [$($source.rfp)]"
Write-Note "ports    : $(($result.serial.ports | ForEach-Object { $_.Port }) -join ', ')"

$result | ConvertTo-Json -Depth 6

if (-not $result.ok) { exit 1 }
exit 0
