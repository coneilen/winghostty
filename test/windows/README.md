# Windows Tests

Manual and interactive harnesses for Windows-specific functionality.

## GitHub-hosted Windows Server CPU profile

The `windows-interactive` job uses **`windows-2025` X64 (Windows Server 2025)**,
not Windows 11 client, with application-local **Mesa 26.2.3 WGL llvmpipe**.
Its required check name remains **Windows 11 Interactive Composite** solely
for historical rule compatibility. The job summary, artifact
`hosted-windows-server-cpu-<run>-<attempt>`, and versioned evidence identify
the actual profile as **`HOSTEDWINDOWSSERVERCPU`**.

This is real core GUI/render/shader correctness coverage, not Windows 11
client, physical GPU, hardware pacing/reset recovery, Snap/Mica, native
ARM64, release, or GraphCode/macOS parity proof. No policy, required-check
identity, renderer/application code, or provider pin is changed. The
strict client release consumer `scripts\check-accessibility-evidence.ps1`
is separate and unchanged; hosted evidence does not satisfy it.
`assert-interactive-runner.ps1` defaults to `ClientRelease` and now
explicitly requires self-hosted provenance and Windows **client**
`ProductType=1`. This is intentional provenance tightening; its existing
desktop/session/user/runner-version/SHA checks still apply.

The hosted runner producer is `assert-interactive-runner.ps1 -Profile
HostedServerCpu`. `winghostty.hosted-runner-provenance.v1` records the actual
OS product type/build, runner environment/architecture, Runner.Worker
executable resolved through trusted process ancestry, exact checkout,
repository/run/attempt, and current session/window station/thread/input
desktop. Native and CIM process creation times must agree within only
the documented CIM microsecond truncation interval, never a millisecond
PID-reuse tolerance. The owned native canary must actually acquire
foreground/focus, receive `SendInput`, and capture its painted pixels with
`CopyFromScreen`. Missing desktop, Explorer, ownership, input, capture, or
cleanup capability is a **failure**, not a skip or an assumed capability.
GitHub image documentation is not evidence that this canary will pass.

The first eligible hosted run established the native canary on the actual
`win25-vs2026` image, but stopped before app/GL execution because the dev
wrapper's year/edition-only paths missed the installed Visual Studio.
`scripts\dev-windows.cmd` now queries the already installed official
`vswhere.exe` for the latest C++-capable installation and requires exactly
one existing `Common7\Tools\VsDevCmd.bat`. Tool failure, ambiguous output
and stale paths fail explicitly; absent discovery retains the existing
2019/2022 developer fallback. No installation, system changes or Zig-version
change is involved. The wrapper is included in the exact source-binding
roster; headless controls execute the actual batch with a console-only
tool/path fixture, never a GUI or GL proxy.

`scripts\setup-hosted-opengl.ps1` verifies the exact release asset, size and
SHA256 from `fixtures\hosted-opengl-lock.json` before extraction. It stages
only `x64\opengl32.dll` and `x64\libgallium_wgl.dll` beside this job's
`zig-out\bin\winghostty.exe`, never into system DLL directories or release
packages. All existing harness executable resolvers use that exact
application directory, including the shader-enabled rebuild. The locked
archive SHA256 is
`3f3613adb43cfd0f2e665ce2400b130c275f0b3317cb3a05566320a3a67589ed`.
The loader imports the megadriver plus GDI32/KERNEL32; the megadriver
imports only SHELL32/ole32/ADVAPI32/ntdll/KERNEL32/USER32/GDI32/VERSION.
The producer independently decodes **both static and delay PE imports**;
these pinned DLLs have no delay imports or extra DLL dependencies.
Pinned distribution/Mesa/LLVM/zstd/zlib notices and build information are
retained as artifacts. The only driver selector is `GALLIUM_DRIVER=llvmpipe`;
GL/GLSL version and extension overrides are forbidden.

A real WGL context probes GL/GLSL >= 4.3 and actual function availability.
Each application stage separately binds the retained app PID, exact
native creation time, owned HWNDs, and both actually loaded Mesa DLL paths
and hashes. Screen capture validates the current foreground/hit-tested
owned rectangle immediately before reading pixels. UIA semantic pixel
tests retain their existing owned-window-DC sampling (not screen-capture
substitutes), with immediate retained-owner/client-coordinate guards.
Cleanup independently attempts all steps, preserves the original failure
and every secondary, and records available, observed and remaining
process counts. Unavailable counts remain null/error, never zero.

`run-hosted-interactive.ps1` runs the unchanged eight PR groups (smoke,
key input, new tab, resize, undo, accessibility, palette/theme and session
restore) plus the real custom-shader harness. Its existing `+version`,
solid-magenta fixture and dominant 4-by-4 sampled RGB threshold
`R >= 220, G <= 40, B >= 220` remain intact. The strict checker
`assert-hosted-interactive-evidence.ps1` independently decodes the actual
retained PNG and recomputes that same ordered sampling/threshold, checks
artifact bytes/hashes, exact canonical harness/source rosters, typed
counters, app/HWND/module correlation and nonempty, known zero-leak
cleanup. Non-PR eligible events additionally retain the full flagship
composite, 600-second accessibility soak, High Contrast palette test and
session-restore run; the 60-minute budget and 14-day retention are unchanged.

Headless contract controls (no local GUI/GL/input operations):

```powershell
pwsh -NoProfile -File .\test\windows\test-hosted-interactive.ps1
pwsh -NoProfile -File .\test\windows\flagship\Test-VerificationContracts.ps1
pwsh -NoProfile -File .\test\windows\interactive-win11.ps1
```

The synthetic fixture is explicitly marked **fixture-only**, not native
evidence. These tests and declaration-only interop compilation cannot
establish hosted desktop/GL feasibility. That requires the normal new
PR's actual GitHub-hosted run; it must fail explicitly if the capability
is unavailable. Do not provision login/users/runners or waive assertions
to manufacture success.

Public dependency/platform references:
[GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
[Windows 2025 image](https://github.com/actions/runner-images/blob/main/images/windows/Windows2025-Readme.md),
[pinned Mesa distribution](https://github.com/pal1000/mesa-dist-win/tree/26.2.3),
[llvmpipe](https://docs.mesa3d.org/drivers/llvmpipe.html).

Each interactive Win11 harness uses its own repo-local sandbox under
`.sandbox\win11\<worktree-id>\<sandbox-name>`, so `-ResetState` resets
only that harness's logs/temp state instead of tearing down sibling
validators.

## interactive-win11-validate.ps1

Composite Win11 validator. It runs launch-helper checks and startup smoke,
then runs the command-finish and progress validators in parallel against
separate sandbox roots.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-validate.ps1 -ResetState
```

From the repository root, pass `-Rebuild` to force one upfront
`.\scripts\dev-windows.cmd zig build -Demit-exe=true` before the suite starts.
The suite also does that upfront build automatically
when tracked inputs are newer than `zig-out\bin\winghostty.exe`, so child
harnesses reuse one fresh binary instead of rebuilding in parallel.

## interactive-win11-smoke.ps1

Interactive Win11 startup smoke validation. It launches `winghostty`
inside the repo-local Win11 sandbox and waits for shell startup to be
observed in stderr.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-smoke.ps1 -ResetState -TimeoutSeconds 10
```

## interactive-win11-command-finish.ps1

Interactive Win11 validation for command-finished notifications. It launches
`winghostty` inside the repo-local Win11 sandbox, emits raw OSC `133;C`,
OSC `9;4`, and OSC `133;D;17`, and then validates that the
command-finished path fired.

- If Windows toast delivery is enabled for the current user, the script
  asserts the command-finished path completed without a WinRT toast
  failure.
- If Windows toast delivery is disabled for the current user or app, the
  script asserts the runtime logs the explicit
  `error.NotifierDisabled; falling back to banner` path instead of
  silently dropping the notification.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-command-finish.ps1 -ResetState -TimeoutSeconds 12
```

The harness rebuilds automatically when `build.zig`, `build.zig.zon`, or
files under `src\` are newer than `zig-out\bin\winghostty.exe`. Pass
`-Rebuild` to force a full rebuild anyway.

## vt-probe-win32-conformance.ps1

Win32 VT protocol conformance metadata validation. It runs `+vt-probe` and
asserts that each capability reports a separate Win32-runtime
classification:

- `validated` means an interactive Win32 harness exercises the behavior.
- `parser-only` means shared parser/core support exists, but no Win32 GUI
  behavior is validated.
- `pending` means the Win32 behavior exists or is expected, but the practical
  harness is still missing.

Run the fast metadata check with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\vt-probe-win32-conformance.ps1 -ResetState -TimeoutSeconds 10
```

Pass `-Runtime` to also run the heavier Win32 evidence harnesses currently
referenced by `+vt-probe`: command finish / notification, taskbar progress,
and synchronized-output repaint performance.

## interactive-win11-progress.ps1

Interactive Win11 validation for native progress state changes. It
launches `winghostty` inside the repo-local Win11 sandbox, emits raw
OSC `9;4` state transitions for `set`, `pause`, `error`,
`indeterminate`, and `remove`, captures the `winghostty` window via
screenshots for each state, and fails if:

- the runtime logs `taskbar progress init failed`,
  `taskbar progress sync failed`, or a crash
- the runtime never logs one of the expected taskbar progress sync
  states (`set`, `pause`, `error`, `indeterminate`, `remove`)

The script reports whether captured `set`/`remove` and `pause`/`error`
window images differ, and does the same for bottom-of-screen strips.
These image comparisons are diagnostic only: hosted desktop environments
do not always expose the rendered shell surface or Explorer taskbar to
screen capture, and bottom-strip captures can include unrelated desktop
content.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-progress.ps1 -ResetState -TimeoutSeconds 20
```

## interactive-win11-shaders.ps1

Interactive Win11 validation for custom post-processing shaders. It builds
with `-Dcustom-shaders=true`, loads a deterministic solid-magenta ShaderToy
fixture, captures the terminal surface child window, and fails unless the
dominant sampled surface color is magenta.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-shaders.ps1 -Rebuild -ResetState
```

## interactive-win11-resize.ps1

Interactive Win11 validation for resize repaint coverage. It launches
`winghostty` with a light terminal background, synthesizes a live resize
growth, exits the resize loop, captures the settled enlarged window, and fails
if the newly exposed right or bottom content bands are mostly near-black or
unpainted neutral gray.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-resize.ps1 -ResetState -TimeoutSeconds 15
```

## interactive-win11-ime-candidate.ps1

Interactive Win11 validation for IME candidate anchoring. It launches
`winghostty`, scripts the terminal cursor to a non-origin row/column,
sends a synthetic mouse move near the surface origin to poison the old
mouse-derived path, triggers `WM_IME_STARTCOMPOSITION` on the surface
HWND, and reads the env-gated runtime trace for the composition/candidate
forms computed inside `positionImeWindow()`.

The harness verifies that the traced candidate form uses `CFS_EXCLUDE`,
shares the composition point, exposes a caret-height exclusion rect, and
lands near the scripted caret instead of the poisoned mouse coordinate. It
does not assert that Windows created an IME context or that a real IME
language pack renders a visible candidate popup; that remains
manual/IME-environment coverage.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-ime-candidate.ps1 -ResetState -TimeoutSeconds 18
```

## interactive-win11-undo.ps1

Interactive Win11 validation for the shipped undo/redo action set. It launches
`winghostty`, exercises split creation, tab close/restore, and empty-host
survival after last-tab close, then verifies the visible tab/surface counts
after each replay step. Last-tab headless undo/redo remains covered by focused
Zig tests plus manual validation; this harness does not claim foreground
keyboard coverage.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-undo.ps1 -ResetState -TimeoutSeconds 35
```

## interactive-win11-palette-theme.ps1

Validates Universal Palette theme preview, Escape rollback, Enter commit and
config persistence, plus suppression of theme preview while Windows High
Contrast is active. High Contrast mutation is opt-in with
`-ExerciseHighContrast`; the harness serializes that phase and restores the
original system setting in `finally`.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-palette-theme.ps1 -ResetState
```

## interactive-win11-session-restore.ps1

Validates a three-tab session save/restart restore with the second tab selected,
then injects corrupt state and requires a fresh one-tab launch plus a uniquely
named quarantine artifact.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\interactive-win11-session-restore.ps1 -ResetState
```

## ..\..\scripts\interactive-win11.ps1

Generic repo-local Win11 launcher for ad hoc debugging. It uses the
same sandbox/bootstrap logic as the focused harnesses and can either
launch `winghostty` directly or open a shell with the sandbox
environment applied.

Run with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File ..\..\scripts\interactive-win11.ps1 -ResetState
```

## test_dll_init.c

Regression test for the DLL CRT initialization fix. Loads ghostty.dll
at runtime and calls ghostty_info + ghostty_init to verify the MSVC C
runtime is properly initialized.

### Build

From the repository root, first build ghostty.dll, then compile the test:

```powershell
.\scripts\dev-windows.cmd zig build -Dapp-runtime=none -Demit-exe=false
Push-Location .\test\windows
..\..\scripts\dev-windows.cmd zig cc test_dll_init.c -o test_dll_init.exe -target native-native-msvc
Pop-Location
```

### Run

From this directory:

```powershell
copy ..\..\zig-out\lib\ghostty.dll . && test_dll_init.exe
```

Expected output (after the CRT fix):

```text
ghostty_info: <version string>
```

The ghostty_info call verifies the DLL loads and the CRT is initialized.
Before the fix, loading the DLL would crash with "access violation writing
0x0000000000000024".

## run-win32-host-renderer.ps1

External host contract for the embeddable renderer. It validates caller-owned
parenting, child HWND/HDC/HGLRC ownership, UI/render thread affinity,
visibility/bounds/theme/font-scale updates, synchronous WGL presentation and
teardown, renderer-entry races against surface/host destruction, and 100
create/destroy cycles with USER/GDI handle counts. The teardown stress also
enters the public host, mutation, notification, renderer, and getter APIs
while destruction is in progress, and verifies stale handles cannot affect
replacement objects after allocator address reuse. It also has a parent
`WM_PARENTNOTIFY` handler that calls host deinitialization during child
destruction and verifies deferred teardown completes without a deadlock. A
1024-cycle parent-reentrant teardown run measures process-heap busy
blocks/bytes to catch retained `SurfaceState` and copied options beyond
USER/GDI accounting. A 1024-cycle numeric-handle run measures process-heap
busy blocks/bytes to catch registry and retired-token growth beyond USER/GDI
accounting. Persistent
context coverage switches render-thread ownership from surface A to B, clears
B, destroys A on the UI thread, and switches B again.

```powershell
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\run-win32-host-renderer.ps1
```
