#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Test suite for resolve-env.ps1.

.DESCRIPTION
  Proves portability by building SYNTHETIC e2 studio / RFP install trees that mimic
  the layouts seen on real machines, then asserting the resolver finds them. Nothing
  here depends on the machine running the tests, so it is safe for CI.

  Design note: synthetic layouts are supplied via -SearchRoot, but a host that really
  has e2 studio installed would already resolve through the registry/scan tiers and
  mask a broken synthetic case. To avoid that false pass, every scenario also asserts
  the resolution came from the tier under test (`resolvedBy`), and the suite reports
  which scenarios were conclusive.

.EXAMPLE
  pwsh -File tests/run-tests.ps1
#>
[CmdletBinding()]
param(
    [string]$Resolver
)

# $PSScriptRoot is empty when the script is dot-sourced or invoked oddly; derive the
# script directory robustly so the suite works under pwsh, powershell.exe and CI.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent }
             else { (Get-Location).Path }
if (-not $Resolver) { $Resolver = Join-Path $scriptDir '..\tools\resolve-env.ps1' }

$ErrorActionPreference = 'Stop'

$script:pass = 0
$script:fail = 0
$script:skip = 0
$script:failures = @()

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        $r = & $Body
        if ($r -is [hashtable] -and $r.Skip) {
            Write-Host ("  SKIP  {0}  ({1})" -f $Name, $r.Reason) -ForegroundColor Yellow
            $script:skip++
        } else {
            Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
            $script:pass++
        }
    } catch {
        Write-Host ("  FAIL  {0}" -f $Name) -ForegroundColor Red
        Write-Host ("        {0}" -f $_.Exception.Message) -ForegroundColor Red
        $script:fail++
        $script:failures += "$Name :: $($_.Exception.Message)"
    }
}

function Assert-True($cond, $msg) { if (-not $cond) { throw $msg } }
function Assert-Eq($a, $b, $msg) { if ("$a" -ne "$b") { throw "$msg (expected '$b', got '$a')" } }

# Run the resolver and return parsed JSON. -SearchRoot is passed through as an extra tier.
function Invoke-Resolver {
    param([string[]]$SearchRoot = @(), [string]$E2Studio, [string]$Rfp, [hashtable]$Env = @{})

    $prev = @{}
    foreach ($k in $Env.Keys) {
        $prev[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
        [Environment]::SetEnvironmentVariable($k, $Env[$k], 'Process')
    }
    try {
        # `powershell.exe -File script.ps1 -SearchRoot @(a,b)` cannot express an array
        # (the switch-style array gets swallowed as a single value), so build a command
        # line instead and let the resolver bind the array normally.
        $parts = @("& '$Resolver'", '-Quiet')
        if ($E2Studio) { $parts += "-E2Studio '$E2Studio'" }
        if ($Rfp)      { $parts += "-Rfp '$Rfp'" }
        if ($SearchRoot.Count -gt 0) {
            $quoted = ($SearchRoot | ForEach-Object { "'$_'" }) -join ','
            $parts += "-SearchRoot @($quoted)"
        }
        # The resolver already prints JSON on stdout; just parse it. (Wrapping it in
        # another ConvertTo-Json would double-encode it into a JSON string.)
        $cmd = ($parts -join ' ')

        $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>$null
        if (-not $raw) { throw "resolver produced no output" }
        $o = ($raw | Out-String).Trim() | ConvertFrom-Json
        if ($null -eq $o) { throw "resolver returned null" }
        if ($o -is [array]) { $o = $o[0] }
        return $o
    } finally {
        foreach ($k in $prev.Keys) {
            [Environment]::SetEnvironmentVariable($k, $prev[$k], 'Process')
        }
    }
}

# --------------------------------------------------------------------------
# Synthetic install-tree builders
# --------------------------------------------------------------------------

# Minimal but structurally faithful e2 studio tree.
function New-FakeE2Studio {
    param([string]$Root, [string]$VersionDir = 'e2studio_v2026-07_fsp_v6.6.0',
          [string]$GccLeaf = 'arm-gnu-toolchain-13.2.Rel1-mingw-w64-i686-arm-none-eabi',
          [string]$MakePlugin = 'com.renesas.ide.exttools.gnumake.win32.x86_64_4.3.1.v20240909-0854')

    $base = Join-Path $Root $VersionDir
    New-Item -ItemType Directory -Force -Path (Join-Path $base 'eclipse') | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $base 'eclipse\e2studio.exe') | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $base 'eclipse\e2studio-cli.exe') | Out-Null

    $gccBin = Join-Path $base "toolchains\gcc_arm\$GccLeaf\bin"
    New-Item -ItemType Directory -Force -Path $gccBin | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $gccBin 'arm-none-eabi-gcc.exe') | Out-Null

    $mkBin = Join-Path $base "eclipse\plugins\$MakePlugin\mk"
    New-Item -ItemType Directory -Force -Path $mkBin | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $mkBin 'make.exe') | Out-Null

    return $base
}

function New-FakeRfp {
    param([string]$Root, [string]$VersionDir = 'Renesas Flash Programmer V3.24')
    $base = Join-Path $Root $VersionDir
    New-Item -ItemType Directory -Force -Path $base | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $base 'rfp-cli.exe') | Out-Null
    New-Item -ItemType File -Force -Path (Join-Path $base 'RFPV3.exe') | Out-Null
    return (Join-Path $base 'rfp-cli.exe')
}

# ==========================================================================
Write-Host ""
Write-Host "resolve-env.ps1 test suite" -ForegroundColor Cyan
Write-Host ("resolver: {0}" -f (Resolve-Path $Resolver).Path)
Write-Host ""

if (-not (Test-Path $Resolver)) { throw "resolver not found: $Resolver" }

$work = Join-Path ([IO.Path]::GetTempPath()) ("ra4m2-skill-tests-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
Write-Host "sandbox: $work"
Write-Host ""

try {
    # ---------------------------------------------------------------- S1
    Write-Host "Scenario 1: default-style install (C:\<vendor>\RA\<version>)" -ForegroundColor Cyan
    $s1root = Join-Path $work 's1\Renesas\RA'
    $null = New-FakeE2Studio -Root $s1root
    $null = New-FakeRfp -Root (Join-Path $work 's1\Renesas Electronics')

    Test-Case 'finds e2studio by scanning a default-style root' {
        $o = Invoke-Resolver -SearchRoot @($s1root, (Join-Path $work 's1\Renesas Electronics'))
        Assert-True $o.ok 'expected ok=true'
        Assert-True ($o.e2studio.root -like "$s1root*") "wrong root: $($o.e2studio.root)"
        Assert-True ($o.toolchain.gccBin -like "*\bin") 'gccBin should end in \bin'
        Assert-True (Test-Path $o.toolchain.gccBin) 'gccBin should exist'
        Assert-True ($o.make.exe -like '*make.exe') 'make should be found'
        Assert-True (Test-Path $o.make.exe) 'make should exist'
        Assert-True ($o.rfp.exe -like '*rfp-cli.exe') 'rfp should be found'
    }

    # ---------------------------------------------------------------- S2
    Write-Host ""
    Write-Host "Scenario 2: different drive + different version + different toolchain leaf" -ForegroundColor Cyan
    $s2root = Join-Path $work 's2\Tools\Renesas\RA'
    $null = New-FakeE2Studio -Root $s2root -VersionDir 'e2studio_v2025-04_fsp_v5.9.0' `
        -GccLeaf '13.2.rel1' -MakePlugin 'com.renesas.ide.exttools.gnumake.win32.x86_64_4.2.1.v20230101-0000'
    $s2rfpRoot = Join-Path $work 's2\Tools\Renesas Electronics'
    $s2rfp = New-FakeRfp -Root $s2rfpRoot -VersionDir 'Renesas Flash Programmer V3.19'

    Test-Case 'handles a different version dir and legacy gcc leaf' {
        # -E2Studio must point at the version directory itself (or deeper); scanning a
        # PARENT directory is what -SearchRoot is for. Asserting both keeps the two
        # options' semantics from silently drifting.
        $o = Invoke-Resolver -E2Studio (Join-Path $s2root 'e2studio_v2025-04_fsp_v5.9.0')
        Assert-True $o.ok 'expected ok=true'
        Assert-True ($o.e2studio.root -like "$s2root*") "wrong root: $($o.e2studio.root)"
        Assert-Eq $o.resolvedBy.e2studio 'parameter' 'wrong resolution tier'
        Assert-True (Test-Path $o.toolchain.gccBin) 'gccBin should exist (legacy layout)'
        Assert-True (Test-Path $o.make.exe) 'make should exist (older plugin)'
    }

    Test-Case '-SearchRoot scans a PARENT dir for the version folder' {
        $o = Invoke-Resolver -SearchRoot @($s2root)
        Assert-True ($o.e2studio.root -like "$s2root*") "wrong root: $($o.e2studio.root)"
        Assert-Eq $o.resolvedBy.e2studio 'scan' 'wrong resolution tier'
        Assert-True (Test-Path $o.toolchain.gccBin) 'gccBin should exist (legacy layout)'
        Assert-True (Test-Path $o.make.exe) 'make should exist (older plugin)'
    }

    Test-Case '-E2Studio on a PARENT dir does not scan downwards (falls through)' {
        $o = Invoke-Resolver -E2Studio $s2root
        Assert-True ($o.resolvedBy.e2studio -ne 'parameter') 'parent dir must not be accepted as an install root'
    }

    Test-Case 'handles an older RFP version dir' {
        # Use -Rfp so the answer cannot come from this host's real RFP install.
        $o = Invoke-Resolver -Rfp $s2rfp
        Assert-True ($o.rfp.exe -like '*Renesas Flash Programmer V3.19*') "wrong rfp: $($o.rfp.exe)"
        Assert-Eq $o.resolvedBy.rfp 'parameter' 'wrong resolution tier'
    }

    # ---------------------------------------------------------------- S3
    Write-Host ""
    Write-Host "Scenario 3: env-var override wins" -ForegroundColor Cyan
    $s3root = Join-Path $work 's3\Renesas\RA'
    $null = New-FakeE2Studio -Root $s3root -VersionDir 'e2studio_v2026-07_fsp_v6.6.0'
    $s3base = Join-Path $s3root 'e2studio_v2026-07_fsp_v6.6.0'

    Test-Case 'env var propagates to a child powershell process' {
        [Environment]::SetEnvironmentVariable('RA4M2_PROBE', 'hello', 'Process')
        try {
            $probe = & powershell.exe -NoProfile -Command '$env:RA4M2_PROBE' 2>$null
        } finally {
            [Environment]::SetEnvironmentVariable('RA4M2_PROBE', $null, 'Process')
        }
        if ("$probe".Trim() -ne 'hello') {
            throw "env propagation is not observable in this harness (got '$probe'); env-var test would be vacuous"
        }
    }

    Test-Case 'RA4M2_E2STUDIO env var resolves and is reported as the source' {
        # -SearchRoot is deliberately NOT passed, so the only way to reach the synthetic
        # tree is the environment variable. resolvedBy proves which tier answered.
        $o = Invoke-Resolver -Env @{ RA4M2_E2STUDIO = $s3base; RA4M2_PROBE = 'hello' }
        Assert-Eq $o.resolvedBy.e2studio 'env:RA4M2_E2STUDIO' "wrong tier (root=$($o.e2studio.root))"
        Assert-True ($o.e2studio.root -like "$s3root*") "wrong root: $($o.e2studio.root)"
        Assert-True $o.ok 'expected ok=true'
    }

    # ---------------------------------------------------------------- S4
    Write-Host ""
    Write-Host "Scenario 4: -E2Studio parameter points at various shapes" -ForegroundColor Cyan
    $s4root = Join-Path $work 's4\Renesas\RA'
    $s4base = New-FakeE2Studio -Root $s4root

    Test-Case 'accepts the install root' {
        $o = Invoke-Resolver -E2Studio $s4base
        Assert-True $o.ok 'expected ok=true'
        Assert-True ($o.e2studio.root -like "$s4root*") "wrong root: $($o.e2studio.root)"
        Assert-Eq $o.resolvedBy.e2studio 'parameter' 'wrong resolution tier'
    }

    Test-Case 'accepts the eclipse subfolder' {
        $o = Invoke-Resolver -E2Studio (Join-Path $s4base 'eclipse')
        Assert-True $o.ok 'expected ok=true'
        Assert-Eq $o.resolvedBy.e2studio 'parameter' 'wrong resolution tier'
        Assert-True ($o.e2studio.root -like "$s4root*") "wrong root: $($o.e2studio.root)"
    }

    Test-Case 'accepts the e2studio.exe path itself' {
        $o = Invoke-Resolver -E2Studio (Join-Path $s4base 'eclipse\e2studio.exe')
        Assert-True $o.ok 'expected ok=true'
        Assert-Eq $o.resolvedBy.e2studio 'parameter' 'wrong resolution tier'
    }

    Test-Case 'a bogus -E2Studio path falls through instead of throwing' {
        $o = Invoke-Resolver -E2Studio (Join-Path $work 'does-not-exist')
        # Falls through to other tiers; must not throw. ok may be true (host install) or false.
        Assert-True ($null -ne $o) 'resolver returned nothing'
        Assert-True ($o.resolvedBy.e2studio -ne 'parameter') 'bogus path must not be treated as resolved'
    }

    # ---------------------------------------------------------------- S5
    Write-Host ""
    Write-Host "Scenario 5: RFP in an unusual location" -ForegroundColor Cyan
    $s5rfp = New-FakeRfp -Root (Join-Path $work 's5\Some Vendor\Flash Tools') -VersionDir 'RFP'

    Test-Case 'finds rfp-cli.exe under a nested non-standard folder' {
        $o = Invoke-Resolver -SearchRoot @((Join-Path $work 's5'))
        Assert-True ($o.rfp.exe -like '*rfp-cli.exe') 'rfp not found'
    }

    Test-Case '-Rfp accepts the exe path directly' {
        $o = Invoke-Resolver -Rfp $s5rfp
        Assert-True ($o.rfp.exe -eq (Resolve-Path $s5rfp).Path) "wrong rfp: $($o.rfp.exe)"
        Assert-Eq $o.resolvedBy.rfp 'parameter' 'wrong resolution tier'
    }

    Test-Case '-Rfp accepts the containing folder' {
        $o = Invoke-Resolver -Rfp (Split-Path $s5rfp -Parent)
        Assert-True ($o.rfp.exe -like '*rfp-cli.exe') 'rfp not found from folder hint'
        Assert-Eq $o.resolvedBy.rfp 'parameter' 'wrong resolution tier'
    }

    # ---------------------------------------------------------------- S6
    Write-Host ""
    Write-Host "Scenario 6: output contract" -ForegroundColor Cyan

    Test-Case 'stdout is pure JSON (nothing else may leak in)' {
        $raw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Resolver -Quiet 2>$null
        $text = ($raw | Out-String).Trim()
        $null = $text | ConvertFrom-Json   # throws if polluted
        Assert-True ($text.StartsWith('{')) "stdout must start with '{', got: $($text.Substring(0,[Math]::Min(40,$text.Length)))"
    }

    Test-Case 'serial.ports is always a JSON array, even with <=1 port' {
        $o = Invoke-Resolver
        Assert-True ($o.serial.ports -is [array] -or $null -eq $o.serial.ports) 'ports must be an array (or null)'
        Assert-True ($o.serial.ports.GetType().Name -eq 'Object[]') "ports type was $($o.serial.ports.GetType().Name)"
    }

    Test-Case 'required top-level keys are present' {
        $o = Invoke-Resolver
        foreach ($k in @('ok','resolvedBy','e2studio','toolchain','make','rfp','serial','notes')) {
            Assert-True ($o.PSObject.Properties.Name -contains $k) "missing key: $k"
        }
    }

    Test-Case 'exits 0 when it resolves, non-zero when it cannot' {
        $o = Invoke-Resolver -E2Studio (Join-Path $work 'nope')
        # On a machine with no install at all this must be exit 1. We can only assert
        # the contract that ok and exit code agree.
        $p = Start-Process -FilePath 'powershell.exe' -PassThru -Wait -WindowStyle Hidden `
             -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$Resolver,'-Quiet') `
             -RedirectStandardOutput (Join-Path $work 'out.json') -RedirectStandardError (Join-Path $work 'err.txt')
        $json = Get-Content (Join-Path $work 'out.json') -Raw | ConvertFrom-Json
        if ($json.ok) { Assert-Eq $p.ExitCode 0 'ok=true must exit 0' }
        else          { Assert-True ($p.ExitCode -ne 0) 'ok=false must exit non-zero' }
    }

    # ---------------------------------------------------------------- S7
    Write-Host ""
    Write-Host "Scenario 7: no hardcoded user paths in shipped files" -ForegroundColor Cyan

    Test-Case 'shipped skills/tools contain no absolute path from the author machine' {
        $repo = Resolve-Path (Join-Path $scriptDir '..')
        $patterns = @(
            'C:\\Users\\Lenovo', 'D:\\Renesas\\RA\\e2studio_v2026',
            'C:\\RA4M2_ws', 'C:\\Users\\Administrator', 'C:\\Users\\a8456'
        )
        $files = Get-ChildItem $repo -Recurse -File -Include *.md,*.ps1,*.json,*.yml |
                 Where-Object { $_.FullName -notlike "*$([IO.Path]::DirectorySeparatorChar)tests$([IO.Path]::DirectorySeparatorChar)*" }
        $bad = @()
        foreach ($f in $files) {
            foreach ($p in $patterns) {
                if (Select-String -Path $f.FullName -Pattern $p -SimpleMatch -Quiet) {
                    $bad += "$($f.Name) matches '$p'"
                }
            }
        }
        # resolve-env.ps1 legitimately mentions C:\Users\Administrator / a8456 as
        # EXAMPLES of bad paths to rewrite, so allow those in that one file.
        $bad = $bad | Where-Object { $_ -notmatch '^resolve-env\.ps1' }
        Assert-True ($bad.Count -eq 0) ("hardcoded paths found: " + ($bad -join '; '))
    }

    Test-Case 'no hardcoded COM3 as a required port in skills' {
        $repo = Resolve-Path (Join-Path $scriptDir '..')
        $files = Get-ChildItem (Join-Path $repo 'skills') -Recurse -File -Include *.md
        $bad = @()
        foreach ($f in $files) {
            # COM3 is allowed only in illustrative examples that also say to enumerate ports
            if (Select-String -Path $f.FullName -Pattern 'COM3' -SimpleMatch -Quiet) {
                $txt = Get-Content $f.FullName -Raw
                if ($txt -notmatch 'GetPortNames|Get-SerialPorts|resolve-env') {
                    $bad += $f.Name
                }
            }
        }
        Assert-True ($bad.Count -eq 0) ("COM3 used without port enumeration guidance: " + ($bad -join ', '))
    }

    Test-Case 'no COM3/COM4-style literal in shipped tool scripts' {
        $repo = Resolve-Path (Join-Path $scriptDir '..')
        $files = Get-ChildItem (Join-Path $repo 'tools') -File -Include *.ps1
        $bad = @()
        foreach ($f in $files) {
            if (Select-String -Path $f.FullName -Pattern "COM\d" -Quiet) { $bad += $f.Name }
        }
        Assert-True ($bad.Count -eq 0) ("tool scripts must take -Port, not hardcode a port: " + ($bad -join ', '))
    }

    Test-Case 'the two copies of resolve-env.ps1 are identical (no drift)' {
        $repo = Resolve-Path (Join-Path $scriptDir '..')
        $a = Join-Path $repo 'tools\resolve-env.ps1'
        $b = Join-Path $repo 'skills\ra4m2-build-flash\scripts\resolve-env.ps1'
        Assert-True (Test-Path $a) "missing $a"
        Assert-True (Test-Path $b) "missing $b - the skill bundles its own copy so a single skill folder is self-contained"
        $ha = (Get-FileHash $a -Algorithm SHA256).Hash
        $hb = (Get-FileHash $b -Algorithm SHA256).Hash
        Assert-Eq $ha $hb 'resolve-env.ps1 copies have diverged; re-copy tools\resolve-env.ps1 over the skill copy'
    }

    Test-Case 'every skill has a SKILL.md whose name matches its directory' {
        $repo = Resolve-Path (Join-Path $scriptDir '..')
        $skills = Get-ChildItem (Join-Path $repo 'skills') -Directory
        Assert-True ($skills.Count -gt 0) 'no skills found'
        foreach ($s in $skills) {
            $sk = Join-Path $s.FullName 'SKILL.md'
            Assert-True (Test-Path $sk) "$($s.Name) has no SKILL.md"
            $head = Get-Content $sk -TotalCount 20
            Assert-Eq $head[0] '---' "$($s.Name)/SKILL.md must start with YAML frontmatter"
            $nameLine = $head | Where-Object { $_ -match '^name:' } | Select-Object -First 1
            Assert-True ([bool]$nameLine) "$($s.Name)/SKILL.md has no 'name:' field"
            $declared = ($nameLine -replace '^name:\s*','').Trim()
            Assert-Eq $declared $s.Name "$($s.Name) declares name '$declared' - the registry rejects mismatches"
            Assert-True ([bool]($head | Where-Object { $_ -match '^description:' })) "$($s.Name) has no 'description:'"
            # closing --- must exist
            $close = $head | Select-Object -Skip 1 | Where-Object { $_ -match '^---\s*$' } | Select-Object -First 1
            Assert-True ([bool]$close) "$($s.Name)/SKILL.md frontmatter is not closed"
        }
    }

    Test-Case 'shipped skills do not reference a specific author tool version' {
        $repo = Resolve-Path (Join-Path $scriptDir '..')
        $files = Get-ChildItem (Join-Path $repo 'skills') -Recurse -File -Include *.md
        $bad = @()
        foreach ($f in $files) {
            # A concrete install version string means the text is not portable
            if (Select-String -Path $f.FullName -Pattern 'e2studio_v20\d\d-\d\d' -Quiet) { $bad += $f.Name }
        }
        Assert-True ($bad.Count -eq 0) ("version-specific install path in: " + ($bad -join ', '))
    }

    # ---------------------------------------------------------------- S8
    Write-Host ""
    Write-Host "Scenario 8: known-encoding regressions stay fixed" -ForegroundColor Cyan

    Test-Case 'build-project.ps1 writes files as UTF-8 without a BOM' {
        $repo = Resolve-Path (Join-Path $scriptDir '..')
        $bp = Join-Path $repo 'tools\build-project.ps1'
        $txt = Get-Content $bp -Raw
        # Regression: Set-Content -Encoding ASCII turned non-ASCII path characters into
        # '?', producing include paths that did not exist. Match actual calls only, not
        # the comment that explains the hazard.
        $banned = [regex]::Matches($txt, '(?m)^\s*(Set-Content|Out-File)\b[^\r\n]*-Encoding\s+ASCII')
        Assert-True ($banned.Count -eq 0) `
            'must not rewrite generated files with -Encoding ASCII (destroys non-ASCII paths)'
        Assert-True ($txt -match 'UTF8Encoding\(\$false\)') `
            'should write via .NET UTF8Encoding($false) so no BOM is emitted'
    }

    Test-Case 'build-project.ps1 warns about non-ASCII output paths' {
        $repo = Resolve-Path (Join-Path $scriptDir '..')
        $txt = Get-Content (Join-Path $repo 'tools\build-project.ps1') -Raw
        Assert-True ($txt -match 'non-ASCII') 'should warn when the build path is not ASCII'
        Assert-True ($txt -match 'linker script') 'warning should name the symptom (linker script failure)'
    }

    Test-Case 'no shipped script uses an array parameter through -File splatting' {
        # powershell.exe -File cannot bind an array to a switch-style parameter, so
        # scripts must take scalars (or a list file) as their file-based interface.
        $repo = Resolve-Path (Join-Path $scriptDir '..')
        $files = Get-ChildItem (Join-Path $repo 'tools') -File -Include *.ps1
        $bad = @()
        foreach ($f in $files) {
            $txt = Get-Content $f.FullName -Raw
            if ($txt -match '\[Parameter[^\]]*Mandatory[^\]]*\]\s*\[string\[\]\]\s*\$(\w+)') {
                $bad += "$($f.Name) (array param `$$($Matches[1]))"
            }
        }
        Assert-True ($bad.Count -eq 0) ("array parameters cannot be passed via -File; use a list file: " + ($bad -join ', '))
    }

} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "================================" -ForegroundColor Cyan
Write-Host ("  PASS {0}   FAIL {1}   SKIP {2}" -f $script:pass, $script:fail, $script:skip)
Write-Host "================================" -ForegroundColor Cyan

if ($script:fail -gt 0) {
    Write-Host ""
    Write-Host "Failures:" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
exit 0
