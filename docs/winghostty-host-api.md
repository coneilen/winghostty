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
- `winghostty_surface_options` is copied during creation, including strings
  and callback configuration.
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
- Destroy is synchronous. It disables callbacks before destroying the child
  window, drains no caller messages, and frees copied options before
  returning; no callbacks occur after completion.
- If teardown is waiting for a persistent context owned by another render
  thread, that thread may call `winghostty_surface_clear_current` to release
  it and allow synchronous destruction to complete.
- If the caller destroys the parent, child windows are invalidated but their
  surface handles remain safe until explicit surface or host teardown.
- Initial focus delivery is guarded against callbacks that destroy the surface
  or deinitialize the host reentrantly.
- Surface creation is guarded before `CreateWindowExW`; synchronous parent
  `WM_PARENTNOTIFY` teardown is deferred until creation unwinds and returns a
  null surface after cleaning up any partial child window.
- `winghostty_host_drain` is a non-blocking adapter hook; it does not pump or
  dispatch the caller's messages.

The host boundary provides child-window lifecycle, bounds, visibility, focus,
theme, font-scale adapters, redraw/focus callback delivery, and an explicit
WGL context/presentation adapter. Terminal input, DPI, process, IME,
clipboard, and UIA adapters remain separate extraction boundaries.

## Validation

```powershell
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\compile-win32-host-api.ps1
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\run-win32-host-api-smoke.ps1
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\run-win32-host-renderer.ps1
.\scripts\dev-windows.cmd zig build -Demit-win32-host=true
```
