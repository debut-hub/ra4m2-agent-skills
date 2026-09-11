#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Build a Renesas e² studio / FSP project from the command line, repairing the
  machine-specific defects that e² studio bakes into its generated makefiles.

.DESCRIPTION
  Works on any Windows machine with e² studio installed - no absolute paths are assumed.
  The toolchain is located by scripts/resolve-env.ps1 (registry, env vars, then scan).

  The project is COPIED to an output directory and built there. The source tree is never
  modified, so it is safe to point this at a read-only or version-controlled checkout.

  Two generated-file defects are repaired in the copy:
    A) Absolute paths from whoever last built the project, embedded in Debug\**\subdir.mk
       and Debug\makefile  ->  rewritten to the copy's real location.
    B) An "export PATH=..." line in Debug\makefile.init that replaces the inherited PATH
       and hides the toolchain  ->  removed.

.PARAMETER ProjectDir
  Path to the e² studio project (the folder containing .project / configuration.xml).

.PARAMETER OutName
  Name of the output directory under -OutRoot. Defaults to the project folder name.

.PARAMETER OutRoot
  Where to place the build copy. Defaults to "<ProjectDir>\..\_build".

.PARAMETER Resolver
  Path to resolve-env.ps1. Defaults to the sibling copy next to this script.

.PARAMETER Reuse
  Build in place instead of re-copying (faster repeat builds once the copy exists).

.EXAMPLE
  pwsh -File tools/build-project.ps1 -ProjectDir ..\RA4M2_MINI_Project4
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ProjectDir,
    [string]$OutName,
    [string]$OutRoot,
    [string]$Resolver,
    [switch]$Reuse
)

$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent }
             else { (Get-Location).Path }
if (-not $Resolver) { $Resolver = Join-Path $scriptDir 'resolve-env.ps1' }

if (-not (Test-Path $ProjectDir)) { throw "project not found: $ProjectDir" }
$ProjectDir = (Resolve-Path $ProjectDir).Path
if (-not (Test-Path $Resolver))   { throw "resolver not found: $Resolver" }

if (-not $OutName) { $OutName = Split-Path $ProjectDir -Leaf }
if (-not $OutRoot) { $OutRoot = Join-Path (Split-Path $ProjectDir -Parent) '_build' }

# ---------------------------------------------------------------- environment
Write-Host '[1/5] resolving toolchain'
$json = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Resolver -Quiet 2>$null
if (-not $json) { throw "resolve-env.ps1 produced no output" }
$envInfo = ($json | Out-String) | ConvertFrom-Json

if (-not $envInfo.make.exe)    { throw "make.exe not found. $($envInfo.notes -join '; ')" }
if (-not $envInfo.toolchain.gccBin) { throw "ARM GCC not found. $($envInfo.notes -join '; ')" }
Write-Host "      gcc : $($envInfo.toolchain.gccBin)"
Write-Host "      make: $($envInfo.make.exe)"

# ---------------------------------------------------------------- copy
$dst = Join-Path $OutRoot $OutName

# e2 studio / GNU Make / the ARM toolchain are not reliably UTF-8 clean on Windows.
# GNU Make writes its $(file > ...) response files using the ANSI code page, so a
# non-ASCII path is round-tripped through the wrong encoding and the linker then fails
# with "cannot open linker script file". Compilation may succeed and only linking fail,
# which makes this look like a linker-script bug rather than a path problem. Warn loudly.
$nonAscii = [bool]($dst -match '[^\x00-\x7F]')
if ($nonAscii) {
    Write-Warning "the output path contains non-ASCII characters:"
    Write-Warning "  $dst"
    Write-Warning "e2 studio tooling mangles non-ASCII paths (the failure usually appears at LINK time"
    Write-Warning "as 'cannot open linker script file'). Use an ASCII-only path, e.g. -OutRoot C:\ra4m2_build"
}

if ($Reuse -and (Test-Path (Join-Path $dst 'Debug\makefile'))) {
    Write-Host "[2/5] reusing existing copy -> $dst"
} else {
    if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $OutRoot | Out-Null
    Write-Host "[2/5] copying project -> $dst"
    Copy-Item $ProjectDir $dst -Recurse -Force
}

# ---------------------------------------------------------------- repair paths
Write-Host '[3/5] repairing generated makefiles'

# Defect A: rewrite any "<drive>:\...\workspace\<Project>" prefix. Matches both the
# forward-slash and the backslash-escaped forms, and any user name / e2studio version.
$dstFwd = ($dst -replace '\\','/')
$dstEsc = ($dst -replace '\\','\\')
$reFwd = '(?i)C:(?:\\\\|/)+Users(?:\\\\|/)+[^"/\\\s]+(?:\\\\|/)+[^"/\\\s]+(?:\\\\|/)+workspace(?:\\\\|/)+[^"/\\\s]+'
$reEsc = '(?i)C:\\\\Users\\\\[^"\\]+\\\\[^"\\]+\\\\workspace\\\\[^"\\]+'

$repaired = 0
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
# Read/write via .NET as UTF-8 without a BOM. Using `Set-Content -Encoding ASCII` here
# would silently rewrite every non-ASCII character in the *destination* path as '?',
# producing include paths that do not exist - the classic non-ASCII-path trap.
Get-ChildItem $dst -Recurse -Include *.mk, makefile -File -ErrorAction SilentlyContinue | ForEach-Object {
    $c = [System.IO.File]::ReadAllText($_.FullName)
    if ($c -and ($c -match $reFwd -or $c -match $reEsc)) {
        $c = [regex]::Replace($c, $reFwd, $dstFwd)
        $c = [regex]::Replace($c, $reEsc, $dstEsc)
        [System.IO.File]::WriteAllText($_.FullName, $c, $utf8NoBom)
        $script:repaired++
    }
}
Write-Host "      path-rewritten files: $repaired"

$left = Get-ChildItem $dst -Recurse -Include *.mk, makefile -File -ErrorAction SilentlyContinue |
        Select-String -Pattern 'workspace\\', 'workspace/' -SimpleMatch -ErrorAction SilentlyContinue
if ($left) { Write-Warning "still $($left.Count) absolute-workspace references remain" }

# Defect B: drop PATH / TCINSTALL / PWD exports from makefile.init
$init = Join-Path $dst 'Debug\makefile.init'
if (Test-Path $init) {
    $raw = [System.IO.File]::ReadAllText($init)
    $new = [regex]::Replace($raw, '(?m)^\s*export\s+(PATH|TCINSTALL|PWD)\s*=.*(?:\r?\n|$)', '')
    if ($new -ne $raw) {
        [System.IO.File]::WriteAllText($init, $new, $utf8NoBom)
        Write-Host '      stripped PATH/TCINSTALL override from makefile.init'
    } else {
        Write-Host '      makefile.init had no PATH override'
    }
}

# Guard against a lossy encoding round-trip having eaten part of a rewritten path
$lossy = Get-ChildItem $dst -Recurse -Include *.mk, makefile -File -ErrorAction SilentlyContinue |
         Select-String -Pattern '????' -SimpleMatch -ErrorAction SilentlyContinue
if ($lossy) { Write-Warning "$($lossy.Count) place(s) contain '????' - a path was encoded lossily" }

if (-not (Test-Path (Join-Path $dst 'Debug\makefile'))) {
    throw "no Debug\makefile in the project. Build it once in e2 studio to generate the makefiles, or pass a project that already has a Debug folder."
}

# ---------------------------------------------------------------- build
Write-Host '[4/5] building'
$env:PATH = "$($envInfo.toolchain.gccBin);$env:PATH"

Push-Location (Join-Path $dst 'Debug')
$prevEA = $ErrorActionPreference
# Compiler warnings go to stderr; with ErrorActionPreference=Stop PowerShell would turn
# those harmless warnings into terminating errors. Judge by the exit code instead.
$ErrorActionPreference = 'Continue'
try {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $log = & $envInfo.make.exe all 2>&1
    $code = $LASTEXITCODE
    $sw.Stop()
} finally {
    $ErrorActionPreference = $prevEA
    Pop-Location
}

if ($code -ne 0) {
    Write-Host "BUILD FAILED (exit $code)" -ForegroundColor Red
    $log | Where-Object { $_ -match 'error|Error' } | Select-Object -First 15 |
        ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
    exit $code
}

# ---------------------------------------------------------------- report
Write-Host '[5/5] outputs'
$dbg  = Join-Path $dst 'Debug'
$elf  = Get-ChildItem $dbg -Filter *.elf  -File -ErrorAction SilentlyContinue | Select-Object -First 1
$hex  = Get-ChildItem $dbg -Filter *.hex  -File -ErrorAction SilentlyContinue | Select-Object -First 1
$srec = Get-ChildItem $dbg -Filter *.srec -File -ErrorAction SilentlyContinue | Select-Object -First 1

if (-not $elf) { Write-Host 'no .elf produced' -ForegroundColor Red; exit 1 }

Write-Host ''
Write-Host ("BUILD OK in {0:N1}s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
Write-Host "  ELF : $($elf.FullName)  ($($elf.Length) bytes)"
if ($hex)  { Write-Host "  HEX : $($hex.FullName)  ($($hex.Length) bytes)" }
if ($srec) { Write-Host "  SREC: $($srec.FullName)  ($($srec.Length) bytes)" }

$flash = if ($hex) { $hex.FullName } elseif ($srec) { $srec.FullName } else { $null }
if ($flash) { Write-Host ''; Write-Host "FLASH FILE: $flash" }
exit 0
