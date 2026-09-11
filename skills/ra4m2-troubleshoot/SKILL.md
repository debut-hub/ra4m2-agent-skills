---
name: ra4m2-troubleshoot
description: Diagnose Renesas RA / e² studio / FSP development failures on Windows. Use when a build fails, flashing fails, the board appears dead, the serial port prints nothing or garbage, or behaviour does not match the source. Maps symptoms to root causes with concrete verification commands, and covers the failure modes generic advice misses.
whenToUse: The user reports any RA/e² studio failure - compile error, flash error (E3000105), no serial output, garbled serial output, board unresponsive, or unexpected program behaviour.
---

# Renesas RA troubleshooting

## Resolve the environment first

```powershell
$env = & "<skill_base>\..\ra4m2-build-flash\scripts\resolve-env.ps1" 2>$null | ConvertFrom-Json
```

Or copy `scripts/resolve-env.ps1` from the `ra4m2-build-flash` skill next to this file.
Never hardcode tool paths or a COM port; use `$env.rfp.exe` and `$env.serial.ports`.

---

## Diagnose by layer, not by guessing

```
1. Is the BOARD healthy?     -> flash the vendor's known-good demo, observe
2. Did the flash succeed?    -> RFP -v verification passed?
3. Is the program RUNNING?   -> is there periodic serial output?
4. Is it doing the right thing? -> compare against the source's intent
```

**Critical distinction — "no output" and "garbage output" are different bugs:**

| Observation | Meaning |
|---|---|
| No output at all | Program is not running (wrong mode / not flashed / clock unconfigured / stuck in an assert) |
| Garbled output | Program **is** running but the clock is misconfigured — almost always the crystal frequency |

---

## Symptom → root cause

| Symptom | Most likely cause |
|---|---|
| `fatal error: hal_data.h: No such file or directory` | Generated makefile hardcodes the original author's absolute path (see below) |
| `'arm-none-eabi-gcc' is not recognized as an internal or external command` | `Debug\makefile.init` overrides `PATH` (see below) |
| `E3000105 The device is not responding` | Chip is not in SCI boot mode, or the boot window was already consumed |
| Flash reports success but the program never runs | BOOT/MD pin still in boot mode (MD=0) after flashing |
| Serial completely silent | Board not in run mode, peripheral never opened, or stuck in an assert |
| Serial is garbled | Crystal (XTAL) setting does not match the hardware |
| `%.2f` prints `0.00` | Linker option `-u _printf_float` missing |
| printf crashes or misbehaves | Stack too small (printf uses varargs heavily) |
| Code has no `g_xxx` symbol after adding a peripheral | The configurator output was never generated ("generate project content") |
| `assert(FSP_SUCCESS == err)` hangs | Some `Open` failed: pin conflict, duplicate channel, clock not configured |
| `FSP_ERR_NOT_OPEN` from `*_Start` | `*_Open` was not called first |

---

## Build failures

### A. Missing generated headers

**Root cause**: the e² studio generated makefiles embed an absolute workspace path from
whoever last built the project —
`C:/Users/<name>/e2_studio/workspace/<ProjectName>/...`. **Different projects in one repo
can come from different people**, so the prefix varies.

**Confirm**:
```powershell
Select-String -Path "<project>\Debug\*\subdir.mk" -Pattern 'Users' | Select-Object -First 3
```

**Fix**: rewrite the entire `.../workspace/<ProjectName>` prefix to the real project path.
Handle both the forward-slash form and the `C:\\...` escaped form.

### B. Compiler "not recognized"

**Root cause**: `<project>\Debug\makefile.init` contains
`export PATH=<another machine's e² studio>\toolchains\...\bin;...`,
which **replaces** the inherited PATH.

**Why it fools you**: `arm-none-eabi-gcc --version` works when typed by hand, and a
minimal hand-written makefile also works. Only the real project fails, so it looks like a
missing toolchain when the toolchain is fine.

**Confirm**:
```powershell
Get-Content "<project>\Debug\makefile.init" | Select-String 'PATH'
```

**Fix**: delete the `export PATH=` / `TCINSTALL=` / `PWD=` lines from `makefile.init`.

> Not every project has this file. One project building does not prove the next will.

### C. Other build issues

- **No `Debug\` folder at all** → never built in e² studio. Build it once in the IDE to
  generate the makefiles.
- **PowerShell reports a build failure that is only a warning** → compiler warnings go to
  stderr and `$ErrorActionPreference='Stop'` turns them into terminating errors. Set
  `'Continue'` around the build call and judge by `$LASTEXITCODE`.
- **`$PSScriptRoot` empty** in a helper script → derive the script dir from
  `$MyInvocation.MyCommand.Path` instead.

---

## Flash failures

### `E3000105 The device is not responding`

In order of likelihood:

1. **Not in boot mode.** The MD/BOOT pin must be at the boot position (typically MD=0) —
   this is a physical switch the user must set.
2. **The boot window was already consumed.** The loader accepts one connection; a prior
   probe/reset/flash attempt uses it up.
   - Do **not** probe first and then flash.
   - **Reset immediately before each flash**, then send one complete command.
3. **Each flash needs its own reset.** Batching several images back-to-back fails after
   the first one — that is hardware behaviour, not a script bug.

**Read-only state check** (does not program anything):
```powershell
& $env.rfp.exe -d RA -t COM -if uart -port <PORT> -s 115200 -sig
# Connected to <part>  -> in boot mode
# E3000105             -> not in boot mode
```
`-sig` consumes the window too; reset before flashing afterwards.

### "Invalid value" for a device name

RFP's device list is family-level only (`RA`, `RA6B1`, `RL78`, ...). Use `-d RA`.
The COM tool is named `COM` and its interface is `uart`.

### Flash succeeded but nothing runs

**Root cause**: the BOOT/MD pin is still in boot mode. Even though `-run` releases reset,
with MD=0 the chip re-enters boot mode after reset and never starts your program — the
serial port stays completely silent.

**Confirm**: `-sig` connects ⇒ the chip is sitting in boot mode, not running firmware.

**Fix**: power off → set MD=1 (single-chip) → power on.

---

## Serial problems

### No output

Work through in order:

1. **Is the board in run mode?** `-sig` connecting means it is in boot mode, so of course
   nothing runs.
2. **Right port?** Enumerate; do not assume. On a CH340 board pick `IsCh340 = true`.
   ```powershell
   $env.serial.ports
   [System.IO.Ports.SerialPort]::GetPortNames()
   ```
3. **Right baud?** 115200 8N1 is the common default; confirm from the project's UART config.
4. **Terminal settings** — in SSCOM: 115200, **HEX display off**, then press reset.
5. **Does the program open the UART?** Check for `R_SCI_UART_Open` in the source.
6. **Stuck before it prints?** An `assert` after a failed `Open` spins forever.

**You cannot reset the board from software.** `DtrEnable`/`RtsEnable` toggling has been
measured to do nothing on these boards. If the program prints only once at startup, you have
to ask the user to press reset while you read.

### Garbled output

**Almost always the crystal setting.** If the project's XTAL value does not match the
physical crystal, every baud-rate divisor is wrong, producing garbage — and software delays
are wrong too. Check the clock configuration's XTAL against the board's crystal.

Other possibilities: wrong baud rate, or altered PCLKD/PCLKB divider settings.

---

## printf problems

- **Floats print as `0.00`** → add `-u _printf_float` to the linker options. A Cortex-M33
  has an FPU, but the float formatting code still has to be linked in.
- **printf crashes** → increase the stack. printf's varargs handling is stack-hungry.
- **printf produces nothing** → the retargeting is incomplete. All three are required:
  `#include <stdio.h>`, an `__io_putchar` implementation that writes to the UART and waits
  for the send-complete event, and a `_write()` that loops over `__io_putchar`.

---

## Fallback: gather data instead of guessing

```powershell
# 1. What mode is the chip in?
& $env.rfp.exe -d RA -t COM -if uart -port <PORT> -s 115200 -sig

# 2. Is anything coming out?
$sp = New-Object System.IO.Ports.SerialPort <PORT>,115200,'None',8,'One'
$sp.ReadTimeout=500; $sp.Open(); Start-Sleep -Seconds 3; $sp.ReadExisting(); $sp.Close()

# 3. What ports exist?
$env.serial.ports
```

### Things only the user can do — always ask explicitly

You cannot see the board. State the action and the expected mode:

- **Switch the BOOT/MD pin** — say which position and why.
- **Press reset** — say "I'm going to start reading now, press reset when I say".
- **Power-cycle** — after changing a mode pin.

**Never assume the user already did it.** Ask, wait for confirmation, then act.
