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

`winghostty_surface_paste_text` validates UTF-8 and uses the host's paste
protection classifier. Unsafe text requires `allow_unsafe` and bracketed paste
is enabled by default. Clipboard read/write supports Unicode text and
`CF_HTML` writes. A surface's input options and strings are copied during
creation.

## Validation

```powershell
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\compile-win32-host-api.ps1
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\run-win32-host-api-smoke.ps1
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\run-win32-host-renderer.ps1
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\run-win32-host-api-input.ps1
.\scripts\dev-windows.cmd zig build -Demit-win32-host=true
```
