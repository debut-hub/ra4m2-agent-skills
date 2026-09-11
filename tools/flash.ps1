#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Flash one or more firmware images to a Renesas RA board over the SCI boot loader.

.DESCRIPTION
  The RA serial boot loader accepts exactly ONE connection: the chip leaves boot mode as
  soon as the tool disconnects. So each image needs the board to be reset immediately
  before its flash. This script is therefore INTERACTIVE by default - it prompts before
  every image.

  With -Auto it does not prompt, which only works for the first image on a board that is
  already sitting in boot mode. Use -Auto for a single image, or when scripting a flow
  where something else performs the reset.

.PARAMETER Image
  One or more firmware files (.srec / .hex). Paths may be relative.

.PARAMETER ListFile
  A text file with one firmware path per line. '#' starts a comment.

.PARAMETER Port
  Serial port. Defaults to the first CH340-class port found; if that is ambiguous the
  script lists the candidates and refuses to guess.

.PARAMETER Baud
  Programming baud rate. Default 115200.

.PARAMETER Auto
  Do not prompt between images (see above).

.EXAMPLE
  pwsh -File tools/flash.ps1 -Image build\fw.srec

.EXAMPLE
  pwsh -File tools/flash.ps1 -ListFile images.txt
#>
[CmdletBinding(DefaultParameterSetName='Image')]
param(
    [Parameter(ParameterSetName='Image', Mandatory=$true, Position=0)]
    [string[]]$Image,

    [Parameter(ParameterSetName='List', Mandatory=$true)]
    [string]$ListFile,

    [string]$Port,
    [int]$Baud = 115200,
    [string]$Resolver,
    [switch]$Auto
)

$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent }
             else { (Get-Location).Path }
if (-not $Resolver) { $Resolver = Join-Path $scriptDir 'resolve-env.ps1' }
if (-not (Test-Path $Resolver)) { throw "resolver not found: $Resolver" }

# ---------------------------------------------------------------- images
if ($PSCmdlet.ParameterSetName -eq 'List') {
    if (-not (Test-Path $ListFile)) { throw "list file not found: $ListFile" }
    $images = Get-Content $ListFile |
              Where-Object { $_.Trim() -ne '' -and $_.Trim() -notmatch '^#' } |
              ForEach-Object { $_.Trim() }
} else {
    $images = $Image
}
if (-not $images) { throw 'no firmware images given' }

$resolved = @()
foreach ($i in $images) {
    if (-not (Test-Path $i)) { throw "firmware not found: $i" }
    $resolved += (Resolve-Path $i).Path
}

# ---------------------------------------------------------------- environment
$json = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Resolver -Quiet 2>$null
if (-not $json) { throw 'resolve-env.ps1 produced no output' }
$envInfo = ($json | Out-String) | ConvertFrom-Json

if (-not $envInfo.rfp.exe) { throw "rfp-cli.exe not found. $($envInfo.notes -join '; ')" }

# ------------------------------------------------- port (never assume COM3)
if (-not $Port) {
    $ports = @($envInfo.serial.ports)
    if ($ports.Count -eq 0) {
        throw 'no serial ports detected. Connect the board and re-run, or pass -Port explicitly.'
    }
    $ch = @($ports | Where-Object { $_.IsCh340 })
    if ($ch.Count -eq 1) {
        $Port = $ch[0].Port
        Write-Host "port: $Port (detected CH340)" -ForegroundColor Cyan
    } elseif ($ports.Count -eq 1 -and $ch.Count -eq 0) {
        $Port = $ports[0].Port
        Write-Host "port: $Port (only port present)" -ForegroundColor Yellow
    } else {
        Write-Host 'Multiple candidate ports - refusing to guess. Re-run with -Port <name>:' -ForegroundColor Yellow
        $ports | ForEach-Object { Write-Host ("  {0,-8} CH340={1,-5} {2}" -f $_.Port, $_.IsCh340, $_.Description) }
        exit 2
    }
}

Write-Host "rfp : $($envInfo.rfp.exe)"
Write-Host "port: $Port @ $Baud"
Write-Host ""

# ---------------------------------------------------------------- flash
$results = @()
$n = 0
foreach ($img in $resolved) {
    $n++
    $label = Split-Path $img -Leaf
    Write-Host ("=== [{0}/{1}] {2} ===" -f $n, $resolved.Count, $label) -ForegroundColor Cyan

    if (-not $Auto) {
        Write-Host '    Put the board in SCI BOOT mode, then press RESET (or power-cycle),' -ForegroundColor Yellow
        Write-Host '    and press Enter IMMEDIATELY - the boot window is short.' -ForegroundColor Yellow
        [void](Read-Host '    Ready')
    }

    $prevEA = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $envInfo.rfp.exe -d RA -t COM -if uart -port $Port -s $Baud `
              -file $img -e -p -v -run 2>&1 | Out-String
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevEA

    $failed = ($out -match '\[Error\]') -or ($out -match 'E3000')
    $okLine = ($out -match 'Operation successful')

    if ($code -eq 0 -and $okLine -and -not $failed) {
        Write-Host '    OK' -ForegroundColor Green
        $results += [PSCustomObject]@{ Order=$n; Image=$label; Result='OK' }
    } else {
        Write-Host "    FAILED (exit $code)" -ForegroundColor Red
        ($out -split "`n" | Where-Object { $_ -match '\[Error\]|E3000' } | Select-Object -First 3) |
            ForEach-Object { Write-Host "      $($_.Trim())" -ForegroundColor Red }
        if ($out -match 'E3000105') {
            Write-Host '      -> chip not in boot mode. Reset the board and retry immediately.' -ForegroundColor Yellow
        }
        $results += [PSCustomObject]@{ Order=$n; Image=$label; Result='FAILED' }
        # A failed flash always means the boot window is gone; continuing is pointless.
        if (-not $Auto) {
            Write-Host '    Stopping: subsequent flashes need a fresh reset.' -ForegroundColor Yellow
            break
        }
    }
}

Write-Host ''
Write-Host '===== SUMMARY =====' -ForegroundColor Cyan
$results | ForEach-Object { '{0}. {1,-40} {2}' -f $_.Order, $_.Image, $_.Result }
$okCount = ($results | Where-Object Result -eq 'OK').Count
Write-Host ''
Write-Host ("Flashed OK: {0}/{1}" -f $okCount, $results.Count)

if ($okCount -gt 0) {
    Write-Host ''
    Write-Host 'Now: power off -> set BOOT/MD back to single-chip mode -> power on.' -ForegroundColor Yellow
}

if ($okCount -ne $results.Count -or $results.Count -ne $resolved.Count) { exit 1 }
exit 0
