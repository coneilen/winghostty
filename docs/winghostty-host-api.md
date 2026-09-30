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
- Host lifecycle and surface mutation calls are UI-thread-affine to the thread
  that initialized the host. Renderer calls are affine to the first thread
  that claims the host's render context.
- Rendering is explicit. The first `make_current`, `present`, or `render`
  call claims one render thread for the host; later renderer calls from any
  other thread return `WINGHOSTTY_WRONG_THREAD`. `render` provides a scoped
  clear-and-swap frame, while `make_current`/`clear_current` allow an embedder
  to issue its complete OpenGL renderer between lifecycle calls.
- `render` establishes its GL error boundary before issuing provider GL work:
  it consumes and logs pre-existing caller error flags, without attributing
  them to a new glyph upload. This is bounded to 16 queries; if the flags do
  not clear, rendering is refused before frame/cache mutation with
  `WINGHOSTTY_RENDERER_ERROR` and Win32 `ERROR_GEN_FAILURE`. Embedders that need
  their own error flags should inspect them before calling `render`.
  Glyph rasterization and texture creation/upload errors still fail rendering.
  Raster error names and captured GL codes remain in diagnostics; these
  failures report `ERROR_GEN_FAILURE` through
  `winghostty_surface_get_last_error`, not an ambient Win32 last-error value.
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

The v2 grapheme snapshot (`winghostty_surface_set_terminal_snapshot_v2`)
uses native grayscale GDI coverage. Its renderer derives pixel cell sizes
from the surface bounds divided by the snapshot columns/rows. Each cell
dimension must be at most 4096 pixels; a wide lead's coverage spans two
columns. OpenGL 1.1 uploads round each coverage dimension up to a power of
two. An ink-bearing raster is supported only when those padded dimensions
fit the current context's `GL_MAX_TEXTURE_SIZE` and their product is at most
65,536 texels. This is an area limit, not a 256-pixel limit on each axis:
512 x 128 is also supported when the context permits it.

For example, a wide glyph at 128 x 129 cell pixels pads to 256 x 256 and
fits; at 129 x 129 it pads to 512 x 256 and is refused, while a narrow glyph
at those same metrics still fits. Unsupported dimensions return
`WINGHOSTTY_RENDERER_ERROR` from `winghostty_surface_render`, set
`winghostty_surface_get_last_error` to Win32 `ERROR_NOT_SUPPORTED`, and emit
a dimension/limit diagnostic. This recoverable refusal happens before
framebuffer clearing, cache flushing, raster allocation, or presentation;
the prior frame and present count remain unchanged at unchanged window
bounds. The installed snapshot is not discarded. Install a supported
snapshot or adjust bounds/grid dimensions to recover. Blank cells do not
require a glyph texture and are not refused for this reason. The v1 path
and public layouts/results remain unchanged.

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

## Validation

```powershell
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\compile-win32-host-api.ps1
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\run-win32-host-api-smoke.ps1
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\run-win32-host-renderer.ps1
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\run-win32-host-api-input.ps1
.\scripts\dev-windows.cmd zig build -Demit-win32-host=true
```
