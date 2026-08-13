# Winghostty baseline

This is the reproducible pre-extraction baseline for the Windows fork. It
It does not add GraphCode product code or extract the original renderer and
terminal implementation. The standalone `win32_host` API skeleton is the
explicit lifecycle boundary for later extraction work.

## Compatibility tuple

The pinned inputs below are atomic: changing one requires re-running the
baseline validation. MSVC and Windows SDK are detected reference values on
the validating machine, not portable pins.

| Component | Value |
| --- | --- |
| Upstream source baseline (`winghostty/main`) | `dccedf73600e0ef59c938aa8997f378f27d08f31` |
| Initial baseline branch commit (`host/baseline-ci`) | `ca6273e249a4410470f2449786d0ea950e05e250` |
| Ghostty base | `ba398dfff3e30ff83da07140981ca138410cf608` (merge-base with `ghostty/main`, 2026-04-05) |
| Zig | `0.15.2` (pinned and enforced by wrapper/CI) |
| GitHub Actions Windows runners | x64 `windows-2022`; native ARM64 `windows-11-arm` (fixed labels) |
| MSVC detected reference | `19.29.30159` (`14.29.30133`, x64 host tools) |
| Windows SDK detected reference | `10.0.26100.0` |

The public host contract used for later work is
`GraphCode/investigation/contracts/winghostty-host.md` at GraphCode
`ece55b692fecbe3942e3cc33f3ec44258aa949fe`. This baseline records the
provider as-is; no extraction has started.

## Clean validation

Run from the repository root. Seed and build through the wrapper so separate
processes receive the same explicit cache paths:

```powershell
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\fetch-zig-deps.ps1
.\scripts\dev-windows.cmd zig build test -Dtest-filter=win32
.\scripts\dev-windows.cmd zig build -Demit-exe=true
```

The wrapper places `ZIG_GLOBAL_CACHE_DIR` and `ZIG_LOCAL_CACHE_DIR` on the
worktree volume. This is required for Zig 0.15.2 on Windows when the checkout
and the global cache would otherwise be on different drives. The regression
guards are:

```powershell
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\zig-cache-same-drive.ps1
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\zig-cache-cmd-cross-drive.ps1
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\zig-cache-offline-build.ps1
```

## Win32 terminal `Surface` dependency map

The extraction root is the Win32 runtime `Surface` in
`src/apprt/win32.zig:23836`. This map describes current ownership and imports;
it is intentionally not an extraction plan or a new public API.

### Runtime root

`src/apprt/win32.zig` contains the Win32 `App`, `Host`, and terminal `Surface`
objects plus the window procedures, message loop, WGL setup, child HWND
lifecycle, focus/input dispatch, clipboard, IME, accessibility, persistence,
and shell integration wiring.

The direct imports from that root are:

```text
src/apprt.zig
src/build_config.zig
src/App.zig
src/Surface.zig
src/cli/args.zig
src/config.zig
src/config/edit.zig
src/config/theme.zig
src/config/windows_shell.zig
src/input.zig
src/os/homedir.zig
src/os/main.zig
src/terminal/main.zig
src/renderer.zig
src/update/github_releases.zig
src/datastruct/split_tree.zig
src/apprt/win32_theme.zig
src/apprt/win32_tween.zig
src/apprt/win32_uia/mod.zig
src/apprt/win32_terminal_accessibility.zig
src/apprt/win32_palette.zig
src/apprt/win32_layout.zig
src/apprt/win32_settings.zig
src/apprt/win32_aumid.zig
src/apprt/win32_chrome_state.zig
src/apprt/win32_clipboard_html.zig
src/apprt/win32_undo.zig
src/apprt/win32_toast_winrt.zig
src/apprt/win32_taskbar_progress.zig
src/apprt/win32_powershell_install.zig
src/apprt/win32_link_preview.zig
src/apprt/win32_quick_terminal.zig
src/apprt/win32_surface_drop.zig
src/apprt/win32_surface_drop_target.zig
src/apprt/win32_toast_activation.zig
src/apprt/win32_tab_drag.zig
src/apprt/win32_tab_drag_ole.zig
src/apprt/win32_tab_drop_zones.zig
src/apprt/win32_search_bar.zig
src/apprt/win32_icons.zig
src/apprt/win32_paste_protection.zig
src/apprt/win32_scrollbar_geometry.zig
src/apprt/win32_nc_layout.zig
src/apprt/win32_status_bar.zig
src/apprt/win32_tab_visual.zig
src/apprt/win32_focus_ring.zig
src/apprt/win32_types.zig
src/apprt/win32_session_state.zig
src/apprt/win32_session_persistence.zig
src/apprt/win32_structural_history.zig
src/apprt/win32_recovery.zig
src/apprt/win32_compositor.zig
src/apprt/win32_compositor_native.zig
src/apprt/win32_shell.zig
src/apprt/win32_ipc.zig
```

### Surface-owned edges

| Edge | Current responsibility | Extraction boundary to preserve |
| --- | --- | --- |
| Win32 `Surface` → `CoreSurface` (`src/Surface.zig`) | Terminal core, renderer thread, PTY/child process, font/input state, terminal callbacks | UI-thread calls and callback lifetime; `CoreSurface` remains authoritative for terminal behavior |
| Win32 `Surface` → `App`/`Host`/`Tab` in `win32.zig` | HWND parentage, host/tab/split topology, focus, layout, teardown | Parent HWND and message-loop ownership; no later callback after destruction |
| Win32 `Surface` → `win32_compositor*` | Native shell composition; terminal content remains WGL/OpenGL | Shell composition is top-level host state, not terminal renderer state |
| Win32 `Surface` → `win32_terminal_accessibility`/`win32_uia` | UIA provider/session, text snapshots, focus and selection events | UI thread and COM apartment affinity; provider release is deferred safely |
| Win32 `Surface` → `win32_shell` | Shell pane identity, child process launch, cwd/title synchronization | Surface creation copies command/cwd/environment; process access ends before destruction |
| Win32 `Surface` → `win32_surface_drop*`/clipboard/IME modules | OLE drop target, clipboard payloads, composition and text input | Native handles and callbacks are owned by the Surface lifetime |
| Win32 `Surface` → persistence/recovery/history modules | Session state, atomic files, close-tree rollback, undo | Synchronous or awaitable teardown must leave no posted work or retained surface pointer |

### Transitive core roots

`src/Surface.zig` fans into the shared Ghostty core:

```text
src/renderer.zig
  -> src/renderer/OpenGL.zig
  -> src/font/*
  -> src/terminal/*
src/termio.zig
  -> src/pty.zig
  -> src/shell-integration/*
src/terminal/main.zig
  -> parser, screen, search, selection, Kitty graphics, OSC/VT state
src/config.zig
  -> src/config/* and src/input/*
src/App.zig
  -> apprt callbacks, surface registry, actions, crash/reporting
```

The practical later-extraction seam is therefore the Win32 `Surface` wrapper
and its direct Win32 collaborators. `CoreSurface`, terminal state, renderer,
font, PTY, and shared configuration are provider internals and remain in the
baseline until an explicit host extraction task defines ownership and ABI
boundaries.
