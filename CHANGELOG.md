# Changelog

## 1.0.0

Initial release.

### Skills

- **`ra4m2-build-flash`** — build Renesas e² studio / FSP projects from the command line and
  flash over the SCI boot loader. Documents the one-shot boot window, the `makefile.init`
  PATH override, and the author-path rewriting that generated makefiles require.
- **`ra4m2-troubleshoot`** — symptom-to-root-cause map for build, flash and serial failures.
  Separates "no output" (program not running) from "garbled output" (clock misconfigured).
- **`ra4m2-fsp-api`** — RA4M2 peripheral and FSP API reference: GPIO, external IRQ, GPT/AGT
  timers and PWM, UART with printf retargeting, I²C, RTC, ADC, watchdog. Keeps chip-level
  facts separate from board-level pinouts.

### Tooling

- `tools/resolve-env.ps1` — locates e² studio, ARM GCC, make, RFP and serial ports. Layered
  resolution (parameters → env vars → registry → scan) so no path is hardcoded. Emits JSON
  on stdout, diagnostics on stderr.
- `tools/build-project.ps1` — builds a project in a copy, repairing the two machine-specific
  defects in e² studio's generated makefiles. Never modifies the source tree.
- `tools/flash.ps1` — flashing with the reset timing handled; prompts before each image and
  refuses to guess a serial port.
- `tools/capture-serial.ps1` — captures the once-only start-up banner and reports whether
  output looks periodic.

### Verification

- `tests/run-tests.ps1` — 27 assertions. Builds synthetic e² studio / RFP install trees to
  verify discovery against layouts the developer's own machine does not have, checks the
  stdout/JSON contract, and fails the build if a hardcoded author path, a literal `COM<n>`,
  or a version-specific install path is reintroduced.
- Tested on Windows PowerShell 5.1 and PowerShell 7+.
- CI runs the suite on `windows-latest` under both shells.

### Known limitations

- Non-ASCII build paths still fail, at **link** time rather than compile time: GNU Make
  writes response files using the ANSI code page, so the linker reports
  `cannot open linker script file`. The tooling warns; it cannot fix this.
- `e2studio-cli.exe` headless builds are not used — the argument syntax is
  version-specific and undocumented, so the project's own generated makefile is driven instead.
