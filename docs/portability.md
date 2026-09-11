# Portability design

The goal: a student clones this repo, installs the skills, and they **work on their machine**
without editing anything. That constrains the design more than it might appear.

## The problem

e² studio, FSP, the ARM toolchain and Renesas Flash Programmer all live at
machine-specific paths:

```
D:\Renesas\RA\e2studio_v2026-07_fsp_v6.6.0\              <- drive, vendor folder, version
C:\Renesas\RA\e2studio_v2025-04_fsp_v5.9.0\              <- different release
C:\Program Files (x86)\Renesas Electronics\...\rfp-cli.exe
```

Version strings appear in directory names. Toolchain folder names differ between
installs (`arm-gnu-toolchain-13.2.Rel1-mingw-w64-i686-arm-none-eabi` vs a bare `13.2.rel1`).
Some machines put things on `D:`, some in `Program Files`, some in a user profile.
Renesas Flash Programmer is usually *not* under the e² studio tree at all.

So a skill that names a path works for exactly one machine.

## The approach

**One place knows about paths: `tools/resolve-env.ps1`.** Everything else consumes its
output. Resolution is layered, first hit wins:

| Tier | Mechanism | Why it exists |
|---|---|---|
| 1 | `-E2Studio` / `-Rfp` parameters | Scripted/CI use, and the escape hatch when nothing else works |
| 2 | `RA4M2_E2STUDIO` / `RA4M2_RFP` env vars | Explicit user override for unusual installs |
| 3 | Windows registry uninstall entries | Finds *default* installs without guessing, and survives version changes |
| 4 | Candidate roots + version glob | Finds *custom* install locations |

The registry tier matters: it means the common case needs no configuration at all. The scan
tier is the fallback for people who installed somewhere the registry does not record usefully.

Two details that only show up in practice:

- **Glob for the toolchain, do not construct it.** The `.exe` is the reliable signal, not
  the folder name. `resolve-env.ps1` looks for `arm-none-eabi-gcc.exe` under any directory
  in `toolchains\gcc_arm\`, which covers both the long-name and short-name layouts.
- **Glob the make plugin too.** `com.renesas.ide.exttools.gnumake.win32.x86_64_*` changes
  version between releases.

## Serial ports

Never assume `COM3`. `resolve-env.ps1` enumerates the ports and reports, per port, whether
it is attributable to a CH340-class adapter (by checking the USB enumeration for vendor
`1A86`). When more than one port is plausible, the tools **refuse to guess** — they list the
candidates and exit non-zero so the caller can ask the user.

## Output contract

`resolve-env.ps1` prints **JSON on stdout and nothing else**; diagnostics go straight to
stderr via `[Console]::Error`. This is deliberate:

- `... | ConvertFrom-Json` works.
- `2>$null` silences the noise without corrupting the payload.

Getting this right took iteration. `Write-Host` merges into stdout when a child process is
captured, and PowerShell's warning stream leaks into the parent's stdout too. Only
`[Console]::Error` is reliably separable.

Arrays are forced with `@(...)` so a machine with a single serial port still produces a
JSON array rather than an object — otherwise consumers break on the one-port case, which is
exactly the common case for a single-board setup.

## Testing portability without owning many machines

The test suite creates **synthetic install trees** in a temp directory and asserts the
resolver finds them. Scenarios cover: default-style roots, a different drive, a different
e² studio release, an older make plugin, the legacy short toolchain layout, an older RFP
version, and RFP in a nested non-standard folder.

One subtlety: a developer running the suite on a machine that *already* has e² studio
installed will resolve through the registry tier before the synthetic tree is ever
consulted — which would make a broken synthetic case pass. Two things prevent that false
pass:

1. Every assertion also checks `resolvedBy`, the tier that actually answered, so the test
   cannot pass via a different tier than the one under test.
2. Where host state could still interfere, the scenario uses a parameter (`-E2Studio`,
   `-Rfp`) so the answer is deterministic regardless of the host.

Static checks back this up: the suite fails if a hardcoded author path, a literal `COM\d`,
or a version-specific install path appears in any shipped file, and if the two copies of
`resolve-env.ps1` (repo-level and bundled inside the skill) drift apart.

## Why the skill bundles its own copy of the resolver

`skills/ra4m2-build-flash/scripts/resolve-env.ps1` is a duplicate of `tools/resolve-env.ps1`.
The duplication is intentional: a student may install only that one skill directory, and it
must remain self-contained. A test asserts the two copies are byte-identical, so the
duplication cannot rot silently. **If you edit one, re-copy it to the other.**

## Constraints that are *not* solved here

- **Non-ASCII paths still break the build.** GNU Make writes `$(file > ...)` response files
  using the ANSI code page, so a non-ASCII build path survives compilation and then fails
  at link with `cannot open linker script file`. This is a toolchain limitation; the tooling
  warns rather than pretends to fix it.
- **Case-sensitive filesystems / Linux are untested.** The tools are PowerShell and target
  Windows, matching the toolchain's supported environment.
- **`e2studio-cli.exe` headless build is not used.** It exists and has been confirmed on
  disk, but its argument syntax is version-specific and undocumented; the skills use the
  project's own generated `makefile` instead, which is what the IDE itself drives.
