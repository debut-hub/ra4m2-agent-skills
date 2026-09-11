---
name: ra4m2-build-flash
description: Build and flash Renesas RA (e² studio + FSP) firmware from the command line on Windows. Use when the user wants to compile an RA/e² studio project, produce a .hex/.srec, program a board over Renesas Flash Programmer or J-Link, or asks why a build or flash fails. Includes portable tool discovery and the boot-mode timing rules that make serial flashing work.
whenToUse: The user wants to build or flash Renesas RA / e² studio / FSP firmware, has a compile or flash failure, no serial output after flashing, or needs to know which mode the board is in.
---

# Renesas RA build & flash (portable)

Everything below works on any Windows machine with e² studio installed. **No absolute
paths are assumed — resolve them first.**

---

## Step 0 (always do this first): resolve the toolchain

```powershell
$env = & "<skill_base>\scripts\resolve-env.ps1" 2>$null | ConvertFrom-Json
```

`<skill_base>` is the skill's own directory. This returns JSON:

```jsonc
{
  "ok": true,
  "resolvedBy": { "e2studio": "registry|scan|env:RA4M2_E2STUDIO|parameter",
                  "rfp":      "registry|scan|env:RA4M2_RFP|parameter" },
  "e2studio":  { "root": "...", "exe": "...\\eclipse\\e2studio.exe" },
  "toolchain": { "gccBin": "...\\toolchains\\gcc_arm\\...\\bin" },
  "make":      { "exe": "...\\com.renesas.ide.exttools.gnumake.*\\mk\\make.exe" },
  "rfp":       { "exe": "...\\rfp-cli.exe", "dir": "..." },
  "serial":    { "ports": [ { "Port": "COM7", "Description": "...", "IsCh340": true } ],
                 "usb":   [ { "Instance": "VID_1A86&PID_7523", "Service": "CH341SER_A64" } ] },
  "notes": []
}
```

The script resolves in this order, first hit wins:
1. `-E2Studio` / `-Rfp` parameters
2. `RA4M2_E2STUDIO` / `RA4M2_RFP` environment variables
3. Windows registry uninstall entries (default installs)
4. Candidate roots + version-glob scan (custom install dirs)

**If `ok` is false**, read `notes`. If e² studio is installed in an odd place, either set
`$env:RA4M2_E2STUDIO` to the install root (the folder containing `eclipse\`) and re-run,
or pass `-SearchRoot <parent dir>`.

**Never hardcode a tool path.** If you catch yourself writing `D:\Renesas\...`, `C:\Program
Files\...`, or a specific `e2studio_v<version>` string into a command, call the resolver instead.

### Port selection — never assume COM3

Use `$env.serial.ports`. Pick the entry whose `IsCh340` is true when the board uses a
CH340 USB-serial bridge (VID `1A86`). If there are several ports, list them for the user
and ask which one the board is on. Do not invent a port number.

---

## Build

### Preferred: use the project's own generated makefile

e² studio projects build to a `Debug\makefile` that invokes `arm-none-eabi-gcc`. Two
machine-specific defects in those generated files must be fixed first:

**Defect A — the author's absolute workspace path is hardcoded.**
`Debug\**\subdir.mk` and `Debug\makefile` contain include paths like
`C:/Users/<someone>/e2_studio/workspace/<ProjectName>/src`. Different projects in the same
repo can come from different machines, so the prefix varies. Symptom:

```
fatal error: hal_data.h: No such file or directory
```

Fix: rewrite the whole `.../workspace/<ProjectName>` prefix to the real project path.
Handle **both** the forward-slash form and the `C:\\...` backslash-escaped form.

**Defect B — `Debug\makefile.init` overrides `PATH`.**
It can contain `export PATH=<another machine's e2studio>\toolchains\...\bin;...`, which
**replaces** the inherited PATH and hides your toolchain. Symptom:

```
'arm-none-eabi-gcc' is not recognized as an internal or external command
```

This one is deceptive: running `arm-none-eabi-gcc --version` by hand works, and a tiny
hand-written makefile works too — only the real project fails. Fix by deleting the
`export PATH=` / `TCINSTALL=` / `PWD=` lines from `makefile.init`.

> Not every project has `makefile.init`. A project without it builds fine, so
> "project A built" does **not** imply "project B builds". Verify against more than one.

### Build commands

```powershell
$env:PATH = "$($env.toolchain.gccBin);$env:PATH"
Push-Location "<project>\Debug"
# Compiler warnings go to stderr; with ErrorActionPreference=Stop PowerShell would treat
# them as terminating errors. Rely on the exit code instead.
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& $env.make.exe all
$code = $LASTEXITCODE
$ErrorActionPreference = $prev
Pop-Location
```

**Success**: exit code 0 and `.elf` / `.srec` / `.map` in `Debug\`.

### If there is no generated makefile

The project was never built in e² studio, so `Debug\` is absent. Options, in order:
1. Ask the user to open the project once in e² studio and build it (this generates `Debug\makefile`).
2. Research `e2studio-cli.exe` / headless build for the installed version — the CLI exists
   at `<e2studio.root>\eclipse\e2studio-cli.exe`, but its argument syntax is version-specific
   and undocumented in this skill. Verify before relying on it.

---

## Flash

### Board must be in SCI boot mode

The mode is a hardware pin (often labelled `MD` or `BOOT`):

| Pin | After reset |
|---|---|
| MD = 1 | single-chip mode — **runs your program** |
| MD = 0 | SCI boot mode — **accepts programming** |

Switching modes is a physical action. **You cannot do it; the user must.** Ask explicitly.

### The boot window is one-shot — this is the #1 source of confusion

The RA serial boot loader accepts a connection **once**, and the chip leaves boot mode when
the tool disconnects. Consequences:

- **Do not "connect first to check, then flash."** The check consumes the only window and
  the flash then fails with `E3000105 The device is not responding`.
- **Every flash needs a fresh reset.** The window does not survive from the previous flash.
- Correct sequence: **user resets (or power-cycles) → you immediately send one complete
  program command, with nothing in between.**

### Command

```powershell
& $env.rfp.exe -d RA -t COM -if uart -port <PORT> -s 115200 `
    -file "<firmware>.srec" -e -p -v -run
```

`-e` erase all · `-p` program · `-v` verify · `-run` release reset after disconnecting

**Success**: the output contains `Operation successful` and exit code is 0.

### Device name is the family, not the part number

`rfp-cli -list-devices` lists families (`RA`, `RA6B1`, `RL78`, ...). There is no
`R7FA4M2` entry. Use `-d RA`; RFP reads and reports the actual part.

### Other useful rfp-cli invocations

```powershell
& $env.rfp.exe -d RA -t COM -if uart -port <PORT> -s 115200 -sig   # read-only: is it in boot mode?
& $env.rfp.exe -d RA -t COM -if uart -port <PORT> -s 115200 -r out.srec   # read back flash
& $env.rfp.exe -d RA -list-ports                                   # available ports
& $env.rfp.exe -d RA -t COM -list-interfaces                       # -> uart  2 wire UART
```

`-sig` is read-only and tells you the chip's state:
`Connected to <part>` → in boot mode · `E3000105` → not in boot mode.

Note that `-sig` also consumes the boot window; a reset is needed before flashing afterwards.

### After flashing

Tell the user to: **power off → switch BOOT back to single-chip mode (MD=1) → power on.**
Skipping this is the most common "it flashed fine but nothing happens" cause: with MD=0 the
chip returns to boot mode after reset and never runs your program, so the serial port is silent.

---

## Verify the program is actually running

```powershell
$port = ($env.serial.ports | Where-Object IsCh340 | Select-Object -First 1).Port
$sp = New-Object System.IO.Ports.SerialPort $port,115200,'None',8,'One'
$sp.ReadTimeout = 500
$sp.Open(); Start-Sleep -Seconds 3; $sp.ReadExisting(); $sp.Close()
```

**Opening a serial port does not reset an RA board.** `DtrEnable` and `RtsEnable` toggling
have been measured to have no effect. So a start-up banner printed once at boot can only be
captured if the user presses reset while you are reading — tell them to do so, and read for
a window (e.g. 15 s) while they press.

**Easiest liveness check**: look for *periodic* output (a once-per-second timestamp, a
repeating sensor line). Periodic output proves the main loop is running; you do not need
the banner.

---

## Full sequence

```
resolve-env.ps1
  -> fix makefile paths / makefile.init PATH override
  -> make (exit code 0 -> .srec)
  -> user: BOOT=0, power on, press RESET
  -> rfp-cli -e -p -v -run            (one shot, nothing before it)
  -> user: power off, BOOT=1, power on
  -> read serial, look for periodic output
```
