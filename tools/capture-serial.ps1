#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Capture a board's serial output, including the start-up banner that only prints once.

.DESCRIPTION
  Opening a serial port does NOT reset an RA board (DTR/RTS toggling has been measured to
  have no effect), so a banner printed at boot can only be captured if the board is reset
  while you are already reading. This script opens the port, tells the user to press reset,
  and reads for a window.

  Periodic output (a repeating timestamp, a sensor line) is a more reliable liveness signal
  than the banner, so this also reports whether the capture looks periodic.

.PARAMETER Seconds
  How long to read. Default 15.

.PARAMETER Port
  Serial port. Defaults to the first CH340-class port; lists candidates and refuses to
  guess when ambiguous.

.PARAMETER Baud
  Default 115200.

.PARAMETER Until
  Stop early once this regex matches the captured text.

.PARAMETER Quiet
  Suppress the prompt (for scripted use where something else triggers the reset).

.EXAMPLE
  pwsh -File tools/capture-serial.ps1 -Seconds 20
#>
[CmdletBinding()]
param(
    [int]$Seconds = 15,
    [string]$Port,
    [int]$Baud = 115200,
    [string]$Until,
    [string]$Resolver,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent }
             else { (Get-Location).Path }
if (-not $Resolver) { $Resolver = Join-Path $scriptDir 'resolve-env.ps1' }

# ---------------------------------------------------------------- port
if (-not $Port) {
    $json = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Resolver -Quiet 2>$null
    $envInfo = ($json | Out-String) | ConvertFrom-Json
    $ports = @($envInfo.serial.ports)
    if ($ports.Count -eq 0) { throw 'no serial ports detected; pass -Port explicitly' }
    $ch = @($ports | Where-Object { $_.IsCh340 })
    if ($ch.Count -eq 1) { $Port = $ch[0].Port }
    elseif ($ports.Count -eq 1) { $Port = $ports[0].Port }
    else {
        Write-Host 'Multiple candidate ports - re-run with -Port <name>:' -ForegroundColor Yellow
        $ports | ForEach-Object { Write-Host ("  {0,-8} CH340={1,-5} {2}" -f $_.Port, $_.IsCh340, $_.Description) }
        exit 2
    }
}

Write-Host "Opening $Port @ $Baud for $Seconds s ..." -ForegroundColor Cyan
$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 300
$sp.Open()

# Drain anything already buffered so we see the effect of the reset
Start-Sleep -Milliseconds 300
[void]$sp.ReadExisting()

if (-not $Quiet) {
    Write-Host ''
    Write-Host ">>> Press the board RESET button now (within $Seconds s) <<<" -ForegroundColor Yellow
    Write-Host ''
}

$buf = New-Object System.Text.StringBuilder
$deadline = (Get-Date).AddSeconds($Seconds)
try {
    while ((Get-Date) -lt $deadline) {
        try {
            $c = $sp.ReadExisting()
            if ($c.Length -gt 0) {
                [void]$buf.Append($c)
                if ($Until -and $buf.ToString() -match $Until) { break }
            }
        } catch { }
        Start-Sleep -Milliseconds 50
    }
} finally {
    $sp.Close(); $sp.Dispose()
}

$text = $buf.ToString()

Write-Host ("Captured {0} chars" -f $text.Length) -ForegroundColor Cyan
Write-Host '==== raw ===='
Write-Host $text
Write-Host '==== end ===='

if ($text.Length -eq 0) {
    Write-Host ''
    Write-Host 'Nothing received. Check:' -ForegroundColor Yellow
    Write-Host '  - board is in single-chip mode (not SCI boot mode)'
    Write-Host '  - correct port and baud rate'
    Write-Host '  - the reset button was actually pressed during the window'
    exit 1
}

# Periodic output is stronger evidence of a running main loop than the banner
$lineCount = ($text -split "`r?`n" | Where-Object { $_.Trim() -ne '' }).Count
Write-Host ''
Write-Host ("Non-empty lines: {0}" -f $lineCount)
if ($lineCount -ge 3) { Write-Host 'Looks like periodic output -> the program is running.' -ForegroundColor Green }
exit 0
