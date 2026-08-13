# Embeddable Win32 host API

`include/winghostty/win32_host.h` is the first extraction boundary for
embedding Winghostty in a caller-owned Win32 window. The API is intentionally
independent of GraphCode product types.

## Ownership and lifecycle

- The caller owns the parent `HWND` and the sole Win32 message loop.
- The host owns every child surface `HWND` and never destroys the parent.
- ABI-facing result and theme values are fixed-width `int32_t` typedefs with
  constants; the external contract checks C/C++ layouts with and without
  `-fshort-enums`.
- `winghostty_surface_options` is copied during creation, including strings
  and callback configuration.
- All host and surface calls are UI-thread-affine to the thread that
  initialized the host.
- Destroy is synchronous. It disables callbacks before destroying the child
  window, drains no caller messages, and frees copied options before
  returning; no callbacks occur after completion.
- If the caller destroys the parent, child windows are invalidated but their
  surface handles remain safe until explicit surface or host teardown.
- Initial focus delivery is guarded against callbacks that destroy the surface
  or deinitialize the host reentrantly.
- `winghostty_host_drain` is a non-blocking adapter hook; it does not pump or
  dispatch the caller's messages.

The current skeleton provides child-window lifecycle, bounds, visibility,
focus, theme, font-scale adapters, and redraw/focus callback delivery.
Renderer, terminal input, DPI, process, IME, clipboard, and UIA adapters are
later extraction boundaries.

## Validation

```powershell
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\compile-win32-host-api.ps1
.\scripts\dev-windows.cmd powershell -NoProfile -ExecutionPolicy Bypass -File .\test\windows\run-win32-host-api-smoke.ps1
.\scripts\dev-windows.cmd zig build -Demit-win32-host=true
```
