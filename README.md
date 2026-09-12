# RA4M2 Agent Skills

[English](README.md) | [中文](README.zh-CN.md)

Agent skills that help an LLM assistant drive **Renesas RA / e² studio / FSP** embedded
development on Windows — building from the command line, flashing over the SCI boot loader,
and diagnosing the failures that generic advice gets wrong.

Built and verified against a real board. The failure modes documented here were hit for
real, not guessed.

---

## What is in here

| Skill | Use it when |
|---|---|
| [`ra4m2-build-flash`](skills/ra4m2-build-flash/) | Building an e² studio project or flashing a board over Renesas Flash Programmer |
| [`ra4m2-troubleshoot`](skills/ra4m2-troubleshoot/) | A build fails, a flash fails, the board looks dead, serial is silent or garbled |
| [`ra4m2-fsp-api`](skills/ra4m2-fsp-api/) | Writing or changing RA firmware: GPIO, IRQ, GPT/AGT PWM, UART+printf, I²C, RTC, ADC, watchdog |

Plus portable CLI tools (no agent required):

| Tool | Purpose |
|---|---|
| [`tools/resolve-env.ps1`](tools/resolve-env.ps1) | Locate e² studio, ARM GCC, make, RFP and serial ports on *this* machine. Emits JSON. |
| [`tools/build-project.ps1`](tools/build-project.ps1) | Build an e² studio project from the CLI, repairing the generated makefiles' machine-specific defects |
| [`tools/flash.ps1`](tools/flash.ps1) | Flash one or more images over the SCI boot loader, with the reset timing handled |
| [`tools/capture-serial.ps1`](tools/capture-serial.ps1) | Capture serial output including the once-only start-up banner |

---

## Portability

These skills contain **no absolute paths**. Everything machine-specific is discovered at
runtime by `resolve-env.ps1`, which resolves in this order:

1. `-E2Studio` / `-Rfp` parameters
2. `RA4M2_E2STUDIO` / `RA4M2_RFP` environment variables
3. Windows registry uninstall entries (finds default installs)
4. Candidate roots + version-glob scan (finds custom install locations)

It also **enumerates serial ports** rather than assuming `COM3`, and detects CH340-class
USB-serial adapters.

If discovery fails, set the environment variables and re-run:

```powershell
$env:RA4M2_E2STUDIO = 'E:\Tools\Renesas\RA\e2studio_vXXXX'   # folder containing \eclipse
$env:RA4M2_RFP      = 'D:\Tools\RFP\rfp-cli.exe'
```

The test suite builds **synthetic install trees** in a temp directory and asserts the
resolver finds them, so portability is verified rather than asserted. It also fails the
build if a hardcoded author path, a hardcoded COM port, or a version-specific install path
creeps back into a shipped file.

See [`docs/portability.md`](docs/portability.md) for the design and the reasoning.

---

## Install

Skills are directories containing `SKILL.md`. Copy them into whichever skill root your
agent reads. Layout matters — **no extra nesting level** (the loader does not recurse):

```
<skill-root>/
├── ra4m2-build-flash/
│   ├── SKILL.md
│   └── scripts/resolve-env.ps1
├── ra4m2-troubleshoot/
│   └── SKILL.md
└── ra4m2-fsp-api/
    └── SKILL.md
```

Common roots:

| Agent | User-level root |
|---|---|
| DeepSeek Harness | `~/.dsh/skills/` |
| Project-local (any) | `<project>/.dsh/skills/` |

```powershell
# example: DeepSeek Harness, user level
$dst = "$env:USERPROFILE\.dsh\skills"
New-Item -ItemType Directory -Force -Path $dst | Out-Null
Copy-Item .\skills\* $dst -Recurse -Force
```

Verify by asking the assistant something only these skills know, e.g.
*"which timer clock does the AGT peripheral use, and what does `R_GPT_Start` return if you skipped `Open`?"*
(`PCLKB`; `FSP_ERR_NOT_OPEN`).

---

## Use the tools directly

```powershell
# What does this machine have?
pwsh -File tools/resolve-env.ps1

# Build (source tree is copied; it is never modified)
pwsh -File tools/build-project.ps1 -ProjectDir C:\work\MyProject

# Flash (prompts for a reset before each image - the boot window is one-shot)
pwsh -File tools/flash.ps1 -Image C:\work\_build\MyProject\Debug\MyProject.srec

# See what the board prints (press reset during the window)
pwsh -File tools/capture-serial.ps1 -Seconds 20
```

`resolve-env.ps1` writes diagnostics to stderr and **JSON to stdout**, so it composes:

```powershell
$env = & .\tools\resolve-env.ps1 2>$null | ConvertFrom-Json
& $env.rfp.exe -d RA -t COM -if uart -port $env.serial.ports[0].Port -s 115200 -sig
```

---

## Verify it works

```powershell
pwsh -File tests/run-tests.ps1
```

The suite needs only PowerShell and a filesystem — it does not need e² studio, a board, or
network access, so it runs in CI.

---

## Requirements

- Windows
- PowerShell 5.1 (ships with Windows) or PowerShell 7+
- For building: e² studio with the ARM GCC toolchain
- For flashing: Renesas Flash Programmer (its `rfp-cli.exe` is used)
- A Renesas RA board on a serial port (CH340-class adapters are recognised)

---

## Hard-won lessons baked into these skills

These are the things that cost real time. They are why this repo exists.

1. **The serial boot window is one-shot.** The RA boot loader accepts one connection and
   the chip leaves boot mode when the tool disconnects. So "connect first to check, then
   flash" *always* fails with `E3000105`. Reset immediately before each flash.

2. **Flashing success does not mean the program runs.** If the BOOT/MD pin is still in
   boot mode, the chip re-enters the boot loader after reset and never starts your code —
   the serial port is simply silent.

3. **`makefile.init` can silently replace your `PATH`.** Some generated projects contain
   `export PATH=<another machine's e² studio>\...`, which hides your toolchain. The symptom
   (`arm-none-eabi-gcc is not recognized`) is deceptive because the compiler works fine
   when invoked by hand.

4. **Generated makefiles embed the build machine's absolute path** — and different projects
   in one repo can come from different machines, so the prefix varies.

5. **Non-ASCII project paths break the link, not the compile.** GNU Make writes its
   `$(file > ...)` response files using the ANSI code page. A non-ASCII path survives
   compilation but the linker then reports `cannot open linker script file`. Keep build
   paths ASCII.

6. **Opening a serial port does not reset an RA board.** DTR/RTS toggling has been measured
   to do nothing, so a banner printed once at boot can only be caught by asking the user to
   press reset while you read. Periodic output is the better liveness signal.

---

## License

MIT — see [LICENSE](LICENSE).
