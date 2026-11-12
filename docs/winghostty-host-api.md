# Embeddable Win32 host API

`include/winghostty/win32_host.h` is the first extraction boundary for
embedding Winghostty in a caller-owned Win32 window. The API is intentionally
independent of GraphCode product types.

## Ownership and lifecycle

- The caller owns the parent `HWND` and the sole Win32 message loop.
- The host owns every child surface `HWND` and never destroys the parent.
- Each surface owns its child `HDC` and `HGLRC`; callers can inspect those
  handles but must not release or destroy them.
- ABI-facing result and theme values are fixed-width `int32_t` typedefs with
  constants; the external contract checks C/C++ layouts with and without
  `-fshort-enums`.
- `winghostty_surface_options` is the legacy 128-byte creation ABI. It is
  copied during creation, including strings and callback configuration; the
  legacy entry point never reads beyond that structure.
- `winghostty_surface_options_v2` is the input-enabled ABI. Its `size` and
  `version` fields must be initialized with
  `winghostty_surface_options_v2_init`, and it is passed to
  `winghostty_host_create_surface_v2`.
- `winghostty_font_config` is a separate additive ABI, so neither surface
  options layout changes. Initialize it with `winghostty_font_config_init` and
  apply it with `winghostty_surface_set_font_config`. A null primary family
  restores the legacy Consolas renderer.
- Host lifecycle and surface mutation calls are UI-thread-affine to the thread
  that initialized the host. Renderer calls are affine to the first thread
  that claims the host's render context.
- Rendering is explicit. The first `make_current`, `present`, or `render`
  call claims one render thread for the host; later renderer calls from any
  other thread return `WINGHOSTTY_WRONG_THREAD`. `render` provides a scoped
  clear-and-swap frame, while `make_current`/`clear_current` allow an embedder
  to issue its complete OpenGL renderer between lifecycle calls.
- Scoped render and presentation save and restore the prior WGL binding, so a
  persistent context on one surface remains current across another surface's
  temporary operation.
- A `makeCurrent` on the render thread transfers tracked persistent ownership
  from the previously bound surface only after the new WGL binding succeeds;
  clearing the replacement then leaves the old surface safe to destroy on the
  UI thread.
- Destroy is synchronous. It disables callbacks before destroying the child
  window, drains no caller messages, and frees copied options before
  returning; no callbacks occur after completion.
- If `winghostty_host_deinitialize` is called reentrantly by the parent
  `WM_PARENTNOTIFY` handler while `winghostty_surface_destroy` is delivering
  child-window destruction, deinitialization is deferred until that destroy
  unwinds; the outer admission then completes host teardown.
- Every public API entry point that consumes a host or surface handle takes a
  registry-backed lifetime admission before touching its state. Teardown
  closes new admissions and waits for admitted calls and active operations
  before freeing the surface, host, or renderer; racing calls are rejected
  with an explicit invalid-state result.
- Opaque host and surface handles preserve the C pointer ABI while carrying
  nonzero process-lifetime numeric IDs, not state or heap-token addresses.
  IDs and generations are never reused; live registry entries are removed
  during teardown, so stale handles cannot admit or destroy replacement
  objects after allocator reuse.
- If teardown is waiting for a persistent context owned by another render
  thread, that thread may call `winghostty_surface_clear_current` to release
  it and allow synchronous destruction to complete.
- Destroy disables callbacks before destroying the child window and drains no
  caller messages. Callback dispatches are pinned until they unwind, and host
  deinitialization requested from a callback or window procedure is deferred
  until callback and window-procedure dispatches unwind.
- If the caller destroys the parent, child windows are invalidated but their
  surface handles remain safe until explicit surface or host teardown.
- Initial focus delivery is guarded against callbacks that destroy the surface
  or deinitialize the host reentrantly.
- DPI and metrics callbacks pin their surface and defer surface/host teardown
  until the callback stack unwinds.
- Surface creation is guarded before `CreateWindowExW`; synchronous parent
  `WM_PARENTNOTIFY` teardown is deferred until creation unwinds and returns a
  null surface after cleaning up any partial child window.
- `winghostty_host_drain` is a non-blocking adapter hook; it does not pump or
  dispatch the caller's messages.

The host API provides child-window lifecycle, bounds, visibility, focus, theme,
font-scale, keyboard/text/IME, mouse/selection/link, paste, clipboard, and an
explicit WGL context/presentation adapter. Input callbacks are delivered
synchronously from the caller's message loop thread. Keyboard events retain
virtual-key, scan-code, repeat/dead-key state, modifier state, and the copied
layout name; text callbacks are UTF-8 and preserve surrogate pairs.
Mouse input requests leave tracking whenever mouse/input callbacks are
enabled, reports client-space wheel coordinates, and maps left, right,
middle, and X-button double-click messages to `click_count == 2`.
Mouse and selection cell coordinates use the surface's current scaled cell
metrics after DPI, font-scale, or base-metric changes.
The URL passed to `on_link` remains valid for the full synchronous callback,
including if the callback replaces or clears the link or deinitializes the
host.
The host also provides per-monitor DPI, logical font/cell metric scaling, and
redraw/focus callback delivery. Each surface owns a server-side UI Automation
provider with live terminal name, focus, role, UTF-16 text ranges, visible
ranges, caret, selection, and update notifications. UIA state is detached
before a surface is destroyed, so retained providers return
`UIA_E_ELEMENTNOTAVAILABLE` and never call back into the embedding application
after teardown.

## Glyph font configuration

`winghostty_surface_set_font_config` copies a version-1
`winghostty_font_config`, including every UTF-8 family name, before returning.
The configured primary family is followed by at most seven ordered fallbacks.
For each grapheme run the provider rejects silent GDI face substitution,
selects the first exact configured family that has every glyph, then falls
back to the first exact installed configured family so Windows font linking or
the missing-glyph box can still render. If none of the configured families is
installed, the legacy Consolas path remains the final fallback. This lets an
embedder name its shipped Nerd/Powerline-capable family explicitly rather than
depending on machine-specific GDI linking.

`point_size` is the final typographic size. The provider converts it with
`points * monitor_dpi / 72` once; it is not multiplied by the legacy
`font_scale`. `cell_width_ratio` sets the requested GDI glyph width relative
to that pixel height. Neither field changes terminal grid geometry. Embedders
that need input hit testing and cell bounds to match should continue to call
`winghostty_surface_set_cell_metrics` with logical 96-DPI metrics; Winghostty
applies the current monitor DPI to those metrics.

`WINGHOSTTY_FONT_RASTER_GRAYSCALE` retains GDI grayscale antialiasing.
`WINGHOSTTY_FONT_RASTER_NATURAL` requests ClearType-natural hinting, then
collapses its RGB coverage to one luminance alpha channel because the current
OpenGL renderer uploads `GL_ALPHA` textures. The glyph cache identity includes
the full ordered font configuration, point size, width ratio, weight, raster
mode, cell dimensions, and monitor DPI.

The automated unit, ABI, and renderer contracts prove configuration
validation, point-to-pixel conversion, fallback selection, cache separation,
and that configured glyphs reach the WGL renderer. They do not prove live
screen raster quality, antialiasing appearance, or that GraphCode's selected
JetBrains Mono / Nerd Font families are installed or packaged on a target
machine; those remain integration and visual-validation responsibilities.
Embedders that own a parsed libghostty-vt render state can push a copied
`winghostty_terminal_cell` snapshot with
`winghostty_surface_set_terminal_snapshot` (or the legacy
`winghostty_surface_set_terminal_cells` entry point). Initialize the
versioned snapshot with `winghostty_terminal_snapshot_init`; the host copies
the cells before returning and does not retain caller memory. The provider
renderer consumes that snapshot for the visible cell frame;
`notify_accessibility_*` remains a separate UI Automation channel and is not
used as renderer state. Set
`WINGHOSTTY_TERMINAL_CELL_FOREGROUND_SET` and
`WINGHOSTTY_TERMINAL_CELL_BACKGROUND_SET` in each cell's flags when the
corresponding packed RGB value is present; this preserves valid black
(`0x000000`) rather than treating it as unset. Use the corresponding
`*_DEFAULT` flags for explicit theme defaults. A zero flags value retains
legacy behavior for callers that use nonzero colors and zero for defaults.
The optional generation identifies a replayed render-state snapshot to the
embedder.
The external renderer contract builds against libghostty-vt, feeds VT output
through `ghostty_terminal_vt_write`, converts the resulting
`GhosttyRenderState` rows/cells into this snapshot, and verifies the rendered
`visible` output. A reconnecting surface can replay the same caller-owned
snapshot before its first render; no renderer state is inferred from
`winghostty_surface_notify_terminal_text`.
Retained UIA providers synchronize concurrent queries, updates, selection
callbacks, and teardown; provider options advertise COM-threaded access.
UIA selection callbacks synchronously marshal through the surface window to the
host owner thread, so embedding callbacks and all `DestroyWindow`/host teardown
remain owner-thread-only. Provider release defers final storage reclamation
while a COM-threaded callback is still in flight, and the provider retains a
strong dispatch-context reference until every copied callback context has
returned.
Each child tracks its screen-space origin for `RangeFromPoint` and bounding
rectangles and refreshes it after moves, DPI changes, and bounds updates.
Text geometry uses Unicode display-cell columns (including combining and
wide characters), not UTF-8 byte offsets; production widths come from
Ghostty's generated `uucode` data.
Each retained text range owns the exact immutable accessibility snapshot that
produced its offsets, including cloned and found ranges. Terminal surfaces do
not advertise `ValuePattern`; edit-role providers are read-only, and
unsupported text units return `UIA_E_NOTSUPPORTED`.
`ITextProvider2::GetCaretRange` clears its active flag and range output on
failure (including provider detach and allocation failure). Retained ranges
keep their source text across updates but return `UIA_E_ELEMENTNOTAVAILABLE`
after detach.
Changing the role raises `ControlType` and `LocalizedControlType` property
changes.

`winghostty_surface_paste_text` validates UTF-8 and uses the host's paste
protection classifier. Unsafe text requires `allow_unsafe` and bracketed paste
is enabled by default. Clipboard read/write supports Unicode text and
`CF_HTML`; HTML reads return only the fragment, while the
`CF_UNICODETEXT` fallback contains plain text without markup. A surface's
input options and strings are copied during creation.

Per-monitor DPI is reported through `winghostty_surface_get_dpi`; callers can
set base cell metrics and receive scaled metric/DPI callbacks. Each surface
also owns an independent UI Automation provider with live terminal name,
focus, role, UTF-8 text ranges, visible range, caret, and selection state.
Accessibility snapshots are caller-owned and are pushed through the
`notify_accessibility_*` functions. Providers disconnect before surface
teardown, and retained providers return `UIA_E_ELEMENTNOTAVAILABLE` without
invoking callbacks after destruction.

## Visual cursor snapshots

The additive `winghostty_terminal_snapshot_v3` is 104 bytes on Win64: the
unchanged v2 fields occupy the first 72 bytes, followed by a 32-byte
`winghostty_terminal_cursor`. Initialize and install it on the UI thread:

```c
void winghostty_terminal_snapshot_v3_init(winghostty_terminal_snapshot_v3 *);
winghostty_result winghostty_surface_set_terminal_snapshot_v3(
    winghostty_surface *, const winghostty_terminal_snapshot_v3 *);
```

The provider validates the entire snapshot before changing accepted state,
then owns independent copies of cells, spans, text, and cursor. Invalid
versions, sizes, UTF-8/spans, cursor styles/flags/colors/reserved words, or
in-grid wide-tail mismatches return `WINGHOSTTY_INVALID_ARGUMENT`; allocation
and timer failures return their explicit errors without replacing the snapshot.
The old v1/v2 layouts and entry points remain supported and clear a prior v3
cursor rather than pairing it with unrelated cells.

Cursor styles are block (0), bar (1), underline (2), and hollow block (3).
Flags are visible (1), blinking (2), wide tail (4), and pending wrap (8).
Signed x/y are viewport cell coordinates, not accessibility offsets. Negative
or out-of-viewport coordinates suppress drawing; wide tails normalize to the
lead cell and cover the complete wide grapheme. Pending wrap does not advance
to another cell. Cursor geometry uses the same padded, device-pixel grid as
the glyph pass, without scaling font size or padding a second time.
The one-device-pixel bar/outline follows the retained Ghostty sprite default;
the bar is clipped at the left grid edge, and the underline is clipped to the
bottom of the provider cell (the provider does not expose a font underline
position).

`color_rgb` and `text_rgb` are resolved opaque RGB values. The caller must
provide effective cursor color (OSC 12/config, otherwise terminal foreground)
and cursor text color (config, otherwise terminal background), matching
`src/renderer/generic.zig`'s defaults. Do not substitute the styled cell colors.
Initialization uses `Config.zig` defaults (`FFFFFF` and `282C34`) and an
invisible, out-of-viewport block. Filled blocks recolor the underlying entire
grapheme; bars, underlines, and hollow blocks preserve glyph ink.

The provider owns the 600 ms blink clock, using the existing child window's
message loop and `on_redraw` callback. The embedder must service that callback
by scheduling its normal render operation on the owning render thread, even
without PTY output; no consumer timer or HWND overlay is needed. A cursor
change or focus/visibility transition restarts the visible phase; repeating
identical cursor state (including newer snapshot generations) does not.
Hidden, out-of-viewport, nonblinking, and unfocused cursors do not keep a timer
running. Unfocused visible cursors are steady hollow blocks, per
`src/renderer/Cursor.zig`. Teardown cancels the timer before detaching the HWND.

**Capability limit:** secure-input/password lock cursors are not represented
by v3. Ghostty renders those using the Nerd Font U+F023 glyph, which this
standalone provider cannot guarantee is present. Consumers must surface that
unsupported state explicitly, not silently convert it into a normal cursor.
This contract does not qualify live GPU presentation, OS focus delivery,
macOS pixel parity, or backend PTY resize.

## Validation

Pure geometry/blink and copied-snapshot/ABI regressions (no WGL device) run
with:

```powershell
.\scripts\dev-windows.cmd zig test src\renderer\win32_cursor.zig
.\scripts\dev-windows.cmd zig test src\win32_host.zig -lc -luser32 -lkernel32 -lgdi32 -lopengl32 -lole32 -loleaut32
```

The renderer executable below creates hidden native HWND/WGL contexts and
reads GL pixels. It requires a usable native graphics device; compilation or
pure tests alone do not prove its pixel assertions or idle message delivery.

```powershell
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\compile-win32-host-api.ps1
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\run-win32-host-api-smoke.ps1
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\run-win32-host-renderer.ps1
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\run-win32-host-api-input.ps1
.\scripts\dev-windows.cmd zig build -Demit-win32-host=true
```
