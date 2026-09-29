# Developing winghostty

This fork is Windows-only. The native app target is Win32, the default build
is `winghostty.exe`, and the retained secondary deliverable is
`libghostty-vt`.

If you plan to change code here, read [CONTRIBUTING.md](CONTRIBUTING.md)
first — it owns the contribution rules and the scope guard. For the product
direction and visual contract behind UX decisions, read
[PRODUCT.md](PRODUCT.md) and [DESIGN.md](DESIGN.md) before proposing UI or
interaction changes.

## Build And Test

Use the standard Zig workflow from the repository root:

| Command                                | Description                                |
| -------------------------------------- | ------------------------------------------ |
| `.\scripts\dev-windows.cmd zig build`                            | Build the Win32 app and bundled resources  |
| `.\scripts\dev-windows.cmd zig build -Demit-exe=true`            | Force-install `zig-out/bin/winghostty.exe` |
| `.\scripts\dev-windows.cmd zig build test -Dtest-filter=<name>`  | Run targeted tests (preferred)             |
| `.\scripts\dev-windows.cmd zig build test -Demit-test-exe=true`  | Run the full test suite (slow)             |
| `.\scripts\dev-windows.cmd zig build test -Dtest-filter=win32`   | Run Win32-focused tests                    |
| `.\scripts\dev-windows.cmd zig build test -Dtest-filter=scroll`  | Run scroll/input regression tests          |
| `.\scripts\dev-windows.cmd zig build test -Dtest-filter=keybind` | Run keybinding/default-behavior tests      |
| `.\scripts\dev-windows.cmd zig build -Demit-lib-vt`              | Build the retained `libghostty-vt` library |

Bare `zig build` is not the documented baseline command because a separate
process must receive the same explicit cache paths as dependency seeding.
The wrapper supplies those paths and the Visual Studio environment. Bare
`zig build test` also errors in this fork — pass `-Dtest-filter=<name>` or
`-Demit-test-exe=true` (enforced in `build.zig`).

### Clean Windows baseline

From the repository root, use the native shell wrapper for a clean build/test
run:

```powershell
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\fetch-zig-deps.ps1
.\scripts\dev-windows.cmd zig build test -Dtest-filter=win32
.\scripts\dev-windows.cmd zig build -Demit-exe=true
```

Seeding and every build run through the wrapper, so separate processes share
the same repo-local `ZIG_GLOBAL_CACHE_DIR` and `ZIG_LOCAL_CACHE_DIR`. The
offline-consumption regression is:

```powershell
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\zig-cache-offline-build.ps1
```

Zig 0.15.2's Windows build runner can panic when a generated child path and
its dependency cwd are on different volumes. The focused guard is
`test/windows/zig-cache-same-drive.ps1`.

## Toolchain

This baseline uses **Zig 0.15.2 exactly**. The wrapper and CI enforce that
version. The source guard in `src/build/zig.zig::requireZig` also permits
later 0.15 patches, but those are outside this compatibility tuple.

If Zig fails before compilation because the dependency cache is empty or
cannot be hydrated automatically for Windows builds, run the seed command in
the clean baseline section from the repository root. The repo also ships
`scripts/dev-windows.ps1` and `scripts/dev-windows.cmd`
to open a Windows-native shell with the expected Visual Studio and Zig cache
environment already configured. Do not seed with a bare PowerShell process
and then build with a bare `zig` process; the latter will not inherit the
repo-local cache paths.

The pinned fork/base and validated Windows toolchain tuple, plus the Win32
terminal `Surface` dependency map, are recorded in
[docs/winghostty-baseline.md](docs/winghostty-baseline.md).

## Manual Validation

For manual app validation on Windows, use:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/interactive-win11.ps1
```

This launches the worktree executable with repo-local runtime state under
`.sandbox/win11/<worktree-id>/` instead of global `%LOCALAPPDATA%\winghostty`.
Pass `-Rebuild` when you need a fresh executable after source edits,
`-ResetState` for clean first-run repros, and `-OpenShell` to open a shell
with the same sandbox environment.

For a mechanical smoke check that the launched app can start its initial
terminal under the same sandboxed environment:

```powershell
powershell -ExecutionPolicy Bypass -File test/windows/interactive-win11-smoke.ps1
```

If your change touches input, rendering, or chrome behavior, manually
verify:

1. Wheel mouse scrolling in a long buffer.
2. Precision touchpad scrolling, if available.
3. Fast sustained scrolling for flicker, title churn, or dropped repaint.
4. Keybindings affected by the change.
5. Launch `scripts/interactive-win11.ps1 -Rebuild`; add `-ResetState` when
   validating first-run behavior.
6. For UI or chrome changes, also check the accessibility targets in
   [DESIGN.md](DESIGN.md#accessibility-targets): keyboard traversal, High
   Contrast, reduced motion, DPI scaling, and a Narrator or NVDA
   spot-check.

## Runtime Notes

- The application runtime is Win32.
- The renderer backend is OpenGL on Windows.
- The repo still retains `libghostty-vt` for Zig and C consumers.

## Project Layout (quick map)

- `src/apprt/win32.zig` — Win32 application runtime entry point (large
  single file; behavior-bearing extractions are in progress).
- `src/apprt/win32_theme.zig` — theme tokens, DWM integration, accent
  helpers, HC handling (extracted from `win32.zig` in `a759eb6`).
- `src/update/github_releases.zig` — release checks plus verified installer
  staging for user-initiated updates.
- `src/renderer/OpenGL.zig` — WGL + OpenGL 4.3 renderer backend.
- `src/config/Config.zig` — single source of config options and defaults.
- `dist/windows/` — Inno Setup script, icon, manifest, RC file.
- `scripts/` — Windows packaging, dep-cache bootstrap, dev-shell helpers.

Upstream-derived areas intentionally left alone in day-to-day fork work
include `src/terminal/`, `src/font/`, `src/input/`, `src/termio/`,
`src/shell-integration/`, `src/crash/`, and `libghostty-vt` surfaces.

## Logging

Logging to `stderr` is always available. Debug builds also emit additional
diagnostic output.

Win32-specific local traces used during bring-up may also write to
`winghostty-win32.log` in the current working directory.

## Formatting

- Zig: `zig fmt .`
- Other docs/resources: `prettier -w .`

## Scope Guard

This fork does not preserve the upstream macOS/GTK app surface; when
Windows-native behavior conflicts with upstream cross-platform behavior,
prefer the Windows-native result. The full list of what must not be
reintroduced is in [CONTRIBUTING.md](CONTRIBUTING.md#scope-guard).
