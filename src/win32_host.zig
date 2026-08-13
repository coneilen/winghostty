const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const win32_types = @import("apprt/win32_types.zig");
const win32_context = @import("renderer/win32_context.zig");
const win32_presentation = @import("renderer/win32_presentation.zig");

comptime {
    if (builtin.target.os.tag != .windows) {
        @compileError("win32_host is only available for Windows targets");
    }
}

const HWND = win32_types.HWND;
const HINSTANCE = win32_types.HINSTANCE;
const HMENU = win32_types.HMENU;
const HBRUSH = win32_types.HBRUSH;
const HCURSOR = win32_types.HCURSOR;
const HICON = win32_types.HICON;
const HDC = win32_types.HDC;
const HGLRC = win32_types.HGLRC;
const LPCWSTR = win32_types.LPCWSTR;
const LPARAM = win32_types.LPARAM;
const WPARAM = win32_types.WPARAM;
const LRESULT = win32_types.LRESULT;
const LONG_PTR = win32_types.LONG_PTR;
const UINT = win32_types.UINT;
const DWORD = win32_types.DWORD;
const BOOL = win32_types.BOOL;
const ATOM = win32_types.ATOM;
const WNDCLASSEXW = win32_types.WNDCLASSEXW;
const CREATESTRUCTW = win32_types.CREATESTRUCTW;
const PAINTSTRUCT = win32_types.PAINTSTRUCT;
const RECT = win32_types.RECT;

const allocator: Allocator = std.heap.c_allocator;

const GWLP_USERDATA: i32 = -21;
const WM_NCCREATE: u32 = 0x0081;
const WM_NCDESTROY: u32 = 0x0082;
const WM_PAINT: u32 = 0x000F;
const WM_ERASEBKGND: u32 = 0x0014;
const WM_SETFOCUS: u32 = 0x0007;
const WM_KILLFOCUS: u32 = 0x0008;

const WS_CHILD: u32 = 0x40000000;
const WS_VISIBLE: u32 = 0x10000000;
const SW_HIDE: i32 = 0;
const SW_SHOW: i32 = 5;
const SWP_NOZORDER: u32 = 0x0004;
const SWP_NOACTIVATE: u32 = 0x0010;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral(
    "WinghosttyEmbeddableSurface",
);
const empty_title = std.unicode.utf8ToUtf16LeStringLiteral("");

extern "user32" fn RegisterClassExW(
    class: *const WNDCLASSEXW,
) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(
    ex_style: u32,
    class_name_: LPCWSTR,
    window_name: LPCWSTR,
    style: u32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    parent: ?HWND,
    menu: HMENU,
    instance: HINSTANCE,
    param: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(
    hwnd: HWND,
    message: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) callconv(.winapi) LRESULT;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn BeginPaint(hwnd: HWND, paint: *PAINTSTRUCT) callconv(.winapi) HDC;
extern "user32" fn EndPaint(hwnd: HWND, paint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
extern "user32" fn GetWindowLongPtrW(
    hwnd: HWND,
    index: i32,
) callconv(.winapi) LONG_PTR;
extern "user32" fn InvalidateRect(
    hwnd: HWND,
    rect: ?*const RECT,
    erase: BOOL,
) callconv(.winapi) BOOL;
extern "user32" fn SetFocus(hwnd: ?HWND) callconv(.winapi) ?HWND;
extern "user32" fn SetWindowLongPtrW(
    hwnd: HWND,
    index: i32,
    value: LONG_PTR,
) callconv(.winapi) LONG_PTR;
extern "user32" fn SetWindowPos(
    hwnd: HWND,
    insert_after: ?*anyopaque,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    flags: UINT,
) callconv(.winapi) BOOL;
extern "user32" fn ShowWindow(hwnd: HWND, command: i32) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn GetModuleHandleW(module: ?LPCWSTR) callconv(.winapi) HINSTANCE;

pub const Result = i32;
pub const Theme = i32;

const result_ok: Result = 0;
const result_invalid_argument: Result = 1;
const result_wrong_thread: Result = 2;
const result_out_of_memory: Result = 3;
const result_shutting_down: Result = 4;
const result_win32_error: Result = 5;
const result_surface_invalidated: Result = 6;
const result_renderer_error: Result = 7;
const result_context_error: Result = 8;
const result_present_error: Result = 9;

const theme_system: Theme = 0;

pub const Rect = extern struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const Host = opaque {};
pub const Surface = opaque {};

const HandleKind = enum {
    host,
    surface,
};

const HandleIdentity = struct {
    id: usize,
    generation: u64,
    kind: HandleKind,
};

pub const ExitCallback = *const fn (?*anyopaque, *Surface, i32) callconv(.c) void;
pub const TitleCallback = *const fn (?*anyopaque, *Surface, [*:0]const u8) callconv(.c) void;
pub const CwdCallback = *const fn (?*anyopaque, *Surface, [*:0]const u8) callconv(.c) void;
pub const BellCallback = *const fn (?*anyopaque, *Surface) callconv(.c) void;
pub const NotificationCallback = *const fn (?*anyopaque, *Surface, [*:0]const u8) callconv(.c) void;
pub const RedrawCallback = *const fn (?*anyopaque, *Surface) callconv(.c) void;
pub const FocusCallback = *const fn (?*anyopaque, *Surface, u8) callconv(.c) void;
pub const FatalErrorCallback = *const fn (?*anyopaque, *Surface, Result, [*:0]const u8) callconv(.c) void;

pub const Callbacks = extern struct {
    on_exit: ?ExitCallback,
    on_title: ?TitleCallback,
    on_cwd: ?CwdCallback,
    on_bell: ?BellCallback,
    on_notification: ?NotificationCallback,
    on_redraw: ?RedrawCallback,
    on_focus: ?FocusCallback,
    on_fatal_error: ?FatalErrorCallback,
};

pub const SurfaceOptions = extern struct {
    command: ?[*:0]const u8,
    cwd: ?[*:0]const u8,
    environment: ?[*:0]const u8,
    bounds: Rect,
    visible: u8,
    focus: u8,
    theme: Theme,
    font_scale: f32,
    callbacks: Callbacks,
    user_data: ?*anyopaque,
};

const OwnedOptions = struct {
    command: ?[:0]u8 = null,
    cwd: ?[:0]u8 = null,
    environment: ?[:0]u8 = null,
    bounds: Rect,
    visible: u8,
    focus: u8,
    theme: Theme,
    font_scale: f32,
    callbacks: Callbacks,
    user_data: ?*anyopaque,

    fn init(options: *const SurfaceOptions) !OwnedOptions {
        var result = OwnedOptions{
            .bounds = options.bounds,
            .visible = if (options.visible == 0) 0 else 1,
            .focus = if (options.focus == 0) 0 else 1,
            .theme = options.theme,
            .font_scale = options.font_scale,
            .callbacks = options.callbacks,
            .user_data = options.user_data,
        };
        errdefer result.deinit();
        result.command = try duplicate(options.command);
        result.cwd = try duplicate(options.cwd);
        result.environment = try duplicate(options.environment);
        return result;
    }

    fn deinit(self: *OwnedOptions) void {
        if (self.command) |value| allocator.free(value);
        if (self.cwd) |value| allocator.free(value);
        if (self.environment) |value| allocator.free(value);
        self.command = null;
        self.cwd = null;
        self.environment = null;
    }
};

const AdmissionState = struct {
    mutex: std.Thread.Mutex = .{},
    done: std.Thread.Condition = .{},
    accepting: bool = true,
    clearable: bool = true,
    admitted: usize = 0,
    clear_admitted: usize = 0,
};

const SurfaceState = struct {
    handle: HandleIdentity,
    host: *HostState,
    parent: HWND,
    hwnd: ?HWND = null,
    options: OwnedOptions,
    admission: AdmissionState = .{},
    options_mutex: std.Thread.Mutex = .{},
    renderer: ?*win32_context.Context = null,
    retired_renderer: ?*win32_context.Context = null,
    renderer_mutex: std.Thread.Mutex = .{},
    renderer_done: std.Thread.Condition = .{},
    active_renderer_operations: usize = 0,
    renderer_destroying: bool = false,
    last_error: std.atomic.Value(DWORD) = .init(0),
    present_count: std.atomic.Value(u64) = .init(0),
    invalidated: std.atomic.Value(bool) = .init(false),
    creation_in_progress: bool = false,
    destroying: std.atomic.Value(bool) = .init(false),
};

const HostState = struct {
    handle: HandleIdentity,
    thread_id: DWORD,
    surfaces: std.ArrayListUnmanaged(*SurfaceState) = .empty,
    admission: AdmissionState = .{},
    shutting_down: std.atomic.Value(bool) = .init(false),
    deinitialize_requested: bool = false,
    creation_depth: usize = 0,
    destroy_surface_depth: usize = 0,
    render_thread_mutex: std.Thread.Mutex = .{},
    render_thread_id: DWORD = 0,
};

var admission_registry_mutex: std.Thread.Mutex = .{};
var host_registry: std.AutoHashMapUnmanaged(usize, *HostState) = .empty;
var surface_registry: std.AutoHashMapUnmanaged(usize, *SurfaceState) = .empty;
var next_handle_id: std.atomic.Value(usize) = .init(1);
var next_handle_generation: std.atomic.Value(u64) = .init(1);

fn duplicate(value: ?[*:0]const u8) !?[:0]u8 {
    const source = value orelse return null;
    return try allocator.dupeZ(u8, std.mem.span(source));
}

fn hostHandle(host: *HostState) *Host {
    return @ptrFromInt(host.handle.id);
}

fn surfaceHandle(surface: *SurfaceState) *Surface {
    return @ptrFromInt(surface.handle.id);
}

fn nextHandleId() ?usize {
    var current = next_handle_id.load(.monotonic);
    while (current != 0) {
        const next = if (current == std.math.maxInt(usize))
            0
        else
            current + 1;
        if (next_handle_id.cmpxchgWeak(
            current,
            next,
            .monotonic,
            .monotonic,
        ) == null) {
            return current;
        }
        current = next_handle_id.load(.monotonic);
    }
    return null;
}

fn nextHandleGeneration() ?u64 {
    var current = next_handle_generation.load(.monotonic);
    while (current != 0) {
        const next = if (current == std.math.maxInt(u64))
            0
        else
            current + 1;
        if (next_handle_generation.cmpxchgWeak(
            current,
            next,
            .monotonic,
            .monotonic,
        ) == null) {
            return current;
        }
        current = next_handle_generation.load(.monotonic);
    }
    return null;
}

fn allocateHandleIdentity(kind: HandleKind) ?HandleIdentity {
    return .{
        .id = nextHandleId() orelse return null,
        .generation = nextHandleGeneration() orelse return null,
        .kind = kind,
    };
}

fn hostStateFromId(id: usize) ?*HostState {
    const state = host_registry.get(id) orelse return null;
    if (state.handle.id != id or
        state.handle.generation == 0 or
        state.handle.kind != .host)
    {
        return null;
    }
    return state;
}

fn surfaceStateFromId(id: usize) ?*SurfaceState {
    const state = surface_registry.get(id) orelse return null;
    if (state.handle.id != id or
        state.handle.generation == 0 or
        state.handle.kind != .surface)
    {
        return null;
    }
    return state;
}

const HostAdmission = struct {
    state: *HostState,
    released: bool = false,
};

const SurfaceAdmission = struct {
    surface: *SurfaceState,
    host: ?*HostState = null,
    clear: bool = false,
    released: bool = false,
};

fn unavailableHostResult(handle: ?*Host) Result {
    const pointer = handle orelse return result_invalid_argument;
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    const state = hostStateFromId(@intFromPtr(pointer)) orelse
        return result_invalid_argument;
    state.admission.mutex.lock();
    const accepting = state.admission.accepting;
    state.admission.mutex.unlock();
    return if (accepting) result_invalid_argument else result_shutting_down;
}

fn unavailableSurfaceResult(handle: ?*Surface) Result {
    const pointer = handle orelse return result_invalid_argument;
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    const surface = surfaceStateFromId(@intFromPtr(pointer)) orelse
        return result_invalid_argument;
    surface.admission.mutex.lock();
    const accepting = surface.admission.accepting;
    const clearable = surface.admission.clearable;
    surface.admission.mutex.unlock();

    const host = surface.host;
    const host_shutting_down = host.shutting_down.load(.acquire);
    if (!accepting or !clearable or host_shutting_down) {
        return if (host_shutting_down)
            result_shutting_down
        else
            result_surface_invalidated;
    }
    return result_invalid_argument;
}

fn registerHost(state: *HostState) !void {
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    try host_registry.put(allocator, state.handle.id, state);
}

fn registerSurface(state: *SurfaceState) !void {
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    try surface_registry.put(allocator, state.handle.id, state);
}

fn unregisterHost(state: *HostState) void {
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    _ = host_registry.remove(state.handle.id);
}

fn unregisterSurface(state: *SurfaceState) void {
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    _ = surface_registry.remove(state.handle.id);
}

fn admitHost(handle: ?*Host) ?HostAdmission {
    const pointer = handle orelse return null;
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    const state = hostStateFromId(@intFromPtr(pointer)) orelse return null;
    state.admission.mutex.lock();
    defer state.admission.mutex.unlock();
    if (!state.admission.accepting) return null;
    state.admission.admitted += 1;
    return .{ .state = state };
}

fn admitSurface(handle: ?*Surface) ?SurfaceAdmission {
    const pointer = handle orelse return null;
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    const surface = surfaceStateFromId(@intFromPtr(pointer)) orelse return null;
    surface.admission.mutex.lock();
    defer surface.admission.mutex.unlock();
    if (!surface.admission.accepting) return null;

    const host = surface.host;
    const host_admission = hostStateFromId(host.handle.id) orelse return null;
    host_admission.admission.mutex.lock();
    defer host_admission.admission.mutex.unlock();
    if (!host_admission.admission.accepting) return null;

    surface.admission.admitted += 1;
    host_admission.admission.admitted += 1;
    return .{
        .surface = surface,
        .host = host_admission,
    };
}

fn admitClearSurface(handle: ?*Surface) ?SurfaceAdmission {
    const pointer = handle orelse return null;
    admission_registry_mutex.lock();
    defer admission_registry_mutex.unlock();
    const surface = surfaceStateFromId(@intFromPtr(pointer)) orelse return null;
    surface.admission.mutex.lock();
    defer surface.admission.mutex.unlock();
    if (!surface.admission.clearable) return null;
    surface.admission.clear_admitted += 1;
    return .{
        .surface = surface,
        .clear = true,
    };
}

fn releaseHostAdmission(admission: *HostAdmission) void {
    if (admission.released) return;
    admission.state.admission.mutex.lock();
    std.debug.assert(admission.state.admission.admitted > 0);
    admission.state.admission.admitted -= 1;
    admission.state.admission.done.broadcast();
    admission.state.admission.mutex.unlock();
    admission.released = true;
}

fn releaseSurfaceAdmission(admission: *SurfaceAdmission) void {
    if (admission.released) return;
    admission.surface.admission.mutex.lock();
    if (admission.clear) {
        std.debug.assert(admission.surface.admission.clear_admitted > 0);
        admission.surface.admission.clear_admitted -= 1;
    } else {
        std.debug.assert(admission.surface.admission.admitted > 0);
        admission.surface.admission.admitted -= 1;
    }
    admission.surface.admission.done.broadcast();
    admission.surface.admission.mutex.unlock();
    if (admission.host) |host| {
        host.admission.mutex.lock();
        std.debug.assert(host.admission.admitted > 0);
        host.admission.admitted -= 1;
        host.admission.done.broadcast();
        host.admission.mutex.unlock();
    }
    admission.released = true;
}

fn closeHostAdmission(state: *HostState) void {
    admission_registry_mutex.lock();
    state.admission.mutex.lock();
    state.admission.accepting = false;
    state.shutting_down.store(true, .release);
    state.admission.mutex.unlock();
    admission_registry_mutex.unlock();
}

fn closeSurfaceAdmission(state: *SurfaceState) void {
    admission_registry_mutex.lock();
    state.admission.mutex.lock();
    state.admission.accepting = false;
    state.admission.mutex.unlock();
    admission_registry_mutex.unlock();
}

fn waitHostAdmissions(state: *HostState, remaining: usize) void {
    state.admission.mutex.lock();
    while (state.admission.admitted > remaining) {
        state.admission.done.wait(&state.admission.mutex);
    }
    state.admission.mutex.unlock();
}

fn waitSurfaceAdmissions(state: *SurfaceState, remaining: usize) void {
    state.admission.mutex.lock();
    while (state.admission.admitted > remaining) {
        state.admission.done.wait(&state.admission.mutex);
    }
    state.admission.mutex.unlock();
}

fn disableClearAdmissionAndWait(
    state: *SurfaceState,
    remaining: usize,
) void {
    state.admission.mutex.lock();
    state.admission.clearable = false;
    while (state.admission.admitted > remaining or
        state.admission.clear_admitted != 0)
    {
        state.admission.done.wait(&state.admission.mutex);
    }
    state.admission.mutex.unlock();
}

fn checkHost(host: *HostState) Result {
    if (host.shutting_down.load(.acquire)) return result_shutting_down;
    if (GetCurrentThreadId() != host.thread_id) return result_wrong_thread;
    return result_ok;
}

fn checkSurface(surface: *SurfaceState) Result {
    const result = checkHost(surface.host);
    if (result != result_ok) return result;
    if (surface.invalidated.load(.acquire)) return result_surface_invalidated;
    return result_ok;
}

fn checkRenderSurface(surface: *SurfaceState) Result {
    if (surface.host.shutting_down.load(.acquire)) return result_shutting_down;
    if (surface.invalidated.load(.acquire) or
        surface.destroying.load(.acquire))
    {
        return result_surface_invalidated;
    }
    return result_ok;
}

fn claimRenderThread(host: *HostState) Result {
    if (host.shutting_down.load(.acquire)) return result_shutting_down;
    const thread_id = GetCurrentThreadId();
    host.render_thread_mutex.lock();
    defer host.render_thread_mutex.unlock();
    if (host.render_thread_id == 0) {
        host.render_thread_id = thread_id;
        return result_ok;
    }
    return if (host.render_thread_id == thread_id)
        result_ok
    else
        result_wrong_thread;
}

fn rendererResult(surface: *SurfaceState, err: win32_context.Error) Result {
    surface.last_error.store(GetLastError(), .release);
    return switch (err) {
        error.WrongThread => result_wrong_thread,
        error.Destroying => result_shutting_down,
        error.SwapBuffersFailed => result_present_error,
        error.MakeCurrentFailed,
        error.RestoreCurrentFailed,
        => result_context_error,
        else => result_renderer_error,
    };
}

fn destroyRenderer(surface: *SurfaceState) void {
    surface.renderer_mutex.lock();
    surface.renderer_destroying = true;
    while (surface.active_renderer_operations != 0) {
        surface.renderer_done.wait(&surface.renderer_mutex);
    }
    const renderer = surface.renderer;
    surface.renderer_mutex.unlock();

    if (renderer) |value| {
        value.deinit();
    }

    surface.renderer_mutex.lock();
    if (renderer) |value| {
        if (surface.renderer == value) {
            surface.renderer = null;
            surface.retired_renderer = value;
        }
    }
    surface.renderer_destroying = false;
    surface.renderer_done.broadcast();
    surface.renderer_mutex.unlock();
}

fn freeRendererStorage(surface: *SurfaceState) void {
    if (surface.retired_renderer) |renderer| {
        allocator.destroy(renderer);
        surface.retired_renderer = null;
    }
}

fn beginRendererOperation(surface: *SurfaceState) ?*win32_context.Context {
    if (surface.host.shutting_down.load(.acquire)) return null;
    surface.renderer_mutex.lock();
    defer surface.renderer_mutex.unlock();
    if (surface.invalidated.load(.acquire) or
        surface.destroying.load(.acquire) or
        surface.renderer_destroying)
    {
        return null;
    }
    const renderer = surface.renderer orelse return null;
    surface.active_renderer_operations += 1;
    return renderer;
}

fn beginClearRendererOperation(surface: *SurfaceState) ?*win32_context.Context {
    surface.renderer_mutex.lock();
    defer surface.renderer_mutex.unlock();
    const renderer = surface.renderer orelse return null;
    surface.active_renderer_operations += 1;
    return renderer;
}

fn endRendererOperation(surface: *SurfaceState) void {
    surface.renderer_mutex.lock();
    std.debug.assert(surface.active_renderer_operations > 0);
    surface.active_renderer_operations -= 1;
    if (surface.active_renderer_operations == 0) {
        surface.renderer_done.broadcast();
    }
    surface.renderer_mutex.unlock();
}

fn rendererHdc(surface: *SurfaceState) HDC {
    surface.renderer_mutex.lock();
    defer surface.renderer_mutex.unlock();
    if (surface.host.shutting_down.load(.acquire) or
        surface.invalidated.load(.acquire) or
        surface.destroying.load(.acquire) or
        surface.renderer_destroying)
    {
        return null;
    }
    return if (surface.renderer) |renderer| renderer.hdc else null;
}

fn rendererHglrc(surface: *SurfaceState) HGLRC {
    surface.renderer_mutex.lock();
    defer surface.renderer_mutex.unlock();
    if (surface.host.shutting_down.load(.acquire) or
        surface.invalidated.load(.acquire) or
        surface.destroying.load(.acquire) or
        surface.renderer_destroying)
    {
        return null;
    }
    return if (surface.renderer) |renderer| renderer.hglrc else null;
}

fn storeRendererError(surface: *SurfaceState) void {
    surface.last_error.store(GetLastError(), .release);
}

fn loadRendererError(surface: *SurfaceState) DWORD {
    return surface.last_error.load(.acquire);
}

fn registerSurfaceClass() void {
    const class: WNDCLASSEXW = .{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = surfaceWindowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = GetModuleHandleW(null),
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };
    _ = RegisterClassExW(&class);
}

fn getSurface(hwnd: HWND) ?*SurfaceState {
    const raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(raw)));
}

fn setUserData(hwnd: HWND, surface: ?*SurfaceState) void {
    const value: LONG_PTR = if (surface) |ptr|
        @intCast(@intFromPtr(ptr))
    else
        0;
    _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, value);
}

fn notifyFocus(surface: *SurfaceState, focused: bool) void {
    if (surface.destroying.load(.acquire)) return;
    if (surface.options.callbacks.on_focus) |callback| {
        callback(
            surface.options.user_data,
            surfaceHandle(surface),
            if (focused) 1 else 0,
        );
    }
}

fn notifyRedraw(surface: *SurfaceState) void {
    if (surface.destroying.load(.acquire)) return;
    if (surface.options.callbacks.on_redraw) |callback| {
        callback(surface.options.user_data, surfaceHandle(surface));
    }
}

fn surfaceWindowProc(
    hwnd: HWND,
    message: UINT,
    wparam: WPARAM,
    lparam: LPARAM,
) callconv(.winapi) LRESULT {
    if (message == WM_NCCREATE) {
        const create: *const CREATESTRUCTW =
            @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (create.lpCreateParams) |ptr| {
            setUserData(hwnd, @ptrCast(@alignCast(ptr)));
        }
    }

    const surface = getSurface(hwnd);
    switch (message) {
        WM_SETFOCUS => {
            if (surface) |value| notifyFocus(value, true);
            return 0;
        },
        WM_KILLFOCUS => {
            if (surface) |value| notifyFocus(value, false);
            return 0;
        },
        WM_ERASEBKGND => return 1,
        WM_PAINT => {
            var paint: PAINTSTRUCT = undefined;
            _ = BeginPaint(hwnd, &paint);
            defer _ = EndPaint(hwnd, &paint);
            if (surface) |value| notifyRedraw(value);
            return 0;
        },
        WM_NCDESTROY => {
            setUserData(hwnd, null);
            if (surface) |value| {
                value.hwnd = null;
                destroyRenderer(value);
                if (!value.destroying.load(.acquire)) {
                    value.invalidated.store(true, .release);
                }
            }
            return DefWindowProcW(hwnd, message, wparam, lparam);
        },
        else => return DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

fn removeSurface(host: *HostState, surface: *SurfaceState) void {
    var index: usize = 0;
    while (index < host.surfaces.items.len) : (index += 1) {
        if (host.surfaces.items[index] == surface) {
            _ = host.surfaces.swapRemove(index);
            return;
        }
    }
}

fn destroySurfaceNow(
    surface: *SurfaceState,
    remaining_admissions: usize,
) void {
    surface.destroying.store(true, .release);
    removeSurface(surface.host, surface);
    waitSurfaceAdmissions(surface, remaining_admissions);
    destroyRenderer(surface);
    if (surface.hwnd) |hwnd| {
        setUserData(hwnd, null);
        _ = DestroyWindow(hwnd);
        surface.hwnd = null;
    }
    disableClearAdmissionAndWait(surface, remaining_admissions);
    unregisterSurface(surface);
    freeRendererStorage(surface);
    surface.options.deinit();
}

fn cleanupUnregisteredSurface(
    surface: *SurfaceState,
    hwnd: ?HWND,
) void {
    surface.destroying.store(true, .release);
    if (hwnd) |value| {
        setUserData(value, null);
        _ = DestroyWindow(value);
        surface.hwnd = null;
    }
    closeSurfaceAdmission(surface);
    destroySurfaceNow(surface, 0);
    allocator.destroy(surface);
}

fn finishUnregisteredSurfaceCreation(
    state: *HostState,
    surface: *SurfaceState,
    hwnd: ?HWND,
    result: Result,
    host_admission: *HostAdmission,
) Result {
    surface.creation_in_progress = false;
    cleanupUnregisteredSurface(surface, hwnd);
    state.creation_depth -= 1;
    const deinitialize_requested = state.deinitialize_requested;
    if (deinitialize_requested and state.creation_depth == 0) {
        deinitializeHost(state, 1);
        releaseHostAdmission(host_admission);
        allocator.destroy(state);
    }
    return if (deinitialize_requested) result_shutting_down else result;
}

fn deinitializeHost(
    state: *HostState,
    remaining_host_admissions: usize,
) void {
    closeHostAdmission(state);
    waitHostAdmissions(state, remaining_host_admissions);
    while (state.surfaces.items.len > 0) {
        const surface = state.surfaces.items[state.surfaces.items.len - 1];
        closeSurfaceAdmission(surface);
        destroySurfaceNow(surface, 0);
        allocator.destroy(surface);
    }
    state.surfaces.deinit(allocator);
    unregisterHost(state);
}

fn finishDeferredHostDeinitialize(
    state: *HostState,
    remaining_host_admissions: usize,
) bool {
    if (!state.deinitialize_requested or
        state.creation_depth != 0 or
        state.destroy_surface_depth != 0)
    {
        return false;
    }
    state.deinitialize_requested = false;
    deinitializeHost(state, remaining_host_admissions);
    return true;
}

pub export fn winghostty_surface_options_init(options: *SurfaceOptions) void {
    options.* = .{
        .command = null,
        .cwd = null,
        .environment = null,
        .bounds = .{ .x = 0, .y = 0, .width = 800, .height = 600 },
        .visible = 1,
        .focus = 0,
        .theme = theme_system,
        .font_scale = 1.0,
        .callbacks = .{
            .on_exit = null,
            .on_title = null,
            .on_cwd = null,
            .on_bell = null,
            .on_notification = null,
            .on_redraw = null,
            .on_focus = null,
            .on_fatal_error = null,
        },
        .user_data = null,
    };
}

pub export fn winghostty_host_initialize(out_host: ?*?*Host) Result {
    const output = out_host orelse return result_invalid_argument;
    output.* = null;

    const host = allocator.create(HostState) catch return result_out_of_memory;
    const handle = allocateHandleIdentity(.host) orelse {
        allocator.destroy(host);
        return result_out_of_memory;
    };
    host.* = .{
        .handle = handle,
        .thread_id = GetCurrentThreadId(),
    };
    registerHost(host) catch {
        allocator.destroy(host);
        return result_out_of_memory;
    };
    registerSurfaceClass();
    output.* = hostHandle(host);
    return result_ok;
}

pub export fn winghostty_host_deinitialize(host: ?*Host) Result {
    var admission = admitHost(host) orelse
        return unavailableHostResult(host);
    const state = admission.state;
    const result = checkHost(state);
    if (result != result_ok) {
        releaseHostAdmission(&admission);
        return result;
    }

    state.shutting_down.store(true, .release);
    if (state.creation_depth != 0 or state.destroy_surface_depth != 0) {
        state.deinitialize_requested = true;
        releaseHostAdmission(&admission);
        return result_ok;
    }
    deinitializeHost(state, 1);
    releaseHostAdmission(&admission);
    allocator.destroy(state);
    return result_ok;
}

pub export fn winghostty_host_create_surface(
    host: ?*Host,
    parent: ?HWND,
    options: ?*const SurfaceOptions,
    out_surface: ?*?*Surface,
) Result {
    const output = out_surface orelse return result_invalid_argument;
    output.* = null;
    const parent_hwnd = parent orelse return result_invalid_argument;
    const source = options orelse return result_invalid_argument;
    var host_admission = admitHost(host) orelse
        return unavailableHostResult(host);
    defer releaseHostAdmission(&host_admission);
    const state = host_admission.state;
    const thread_result = checkHost(state);
    if (thread_result != result_ok) return thread_result;
    if (source.font_scale <= 0 or !std.math.isFinite(source.font_scale)) {
        return result_invalid_argument;
    }
    if (source.theme < 0 or source.theme > 2) {
        return result_invalid_argument;
    }
    if (source.bounds.width > std.math.maxInt(i32) or
        source.bounds.height > std.math.maxInt(i32))
    {
        return result_invalid_argument;
    }

    const owned = OwnedOptions.init(source) catch return result_out_of_memory;
    const surface = allocator.create(SurfaceState) catch {
        var cleanup = owned;
        cleanup.deinit();
        return result_out_of_memory;
    };
    const handle = allocateHandleIdentity(.surface) orelse {
        var cleanup = owned;
        cleanup.deinit();
        allocator.destroy(surface);
        return result_out_of_memory;
    };
    surface.* = .{
        .handle = handle,
        .host = state,
        .parent = parent_hwnd,
        .options = owned,
    };
    registerSurface(surface) catch {
        surface.options.deinit();
        allocator.destroy(surface);
        return result_out_of_memory;
    };
    state.creation_depth += 1;
    surface.creation_in_progress = true;
    const hwnd = CreateWindowExW(
        0,
        class_name,
        empty_title,
        WS_CHILD | if (source.visible != 0) WS_VISIBLE else 0,
        source.bounds.x,
        source.bounds.y,
        @intCast(source.bounds.width),
        @intCast(source.bounds.height),
        parent_hwnd,
        null,
        GetModuleHandleW(null),
        surface,
    ) orelse {
        return finishUnregisteredSurfaceCreation(
            state,
            surface,
            null,
            result_win32_error,
            &host_admission,
        );
    };
    surface.hwnd = hwnd;

    if (state.shutting_down.load(.acquire)) {
        return finishUnregisteredSurfaceCreation(
            state,
            surface,
            hwnd,
            result_shutting_down,
            &host_admission,
        );
    }

    const renderer = allocator.create(win32_context.Context) catch {
        return finishUnregisteredSurfaceCreation(
            state,
            surface,
            hwnd,
            result_out_of_memory,
            &host_admission,
        );
    };
    renderer.* = win32_context.Context.init(hwnd) catch |err| {
        storeRendererError(surface);
        allocator.destroy(renderer);
        return finishUnregisteredSurfaceCreation(
            state,
            surface,
            hwnd,
            switch (err) {
                error.GetDCFailed,
                error.ChoosePixelFormatFailed,
                error.SetPixelFormatFailed,
                => result_renderer_error,
                error.CreateContextFailed => result_context_error,
                else => result_renderer_error,
            },
            &host_admission,
        );
    };
    surface.renderer = renderer;

    state.surfaces.append(allocator, surface) catch {
        return finishUnregisteredSurfaceCreation(
            state,
            surface,
            hwnd,
            result_out_of_memory,
            &host_admission,
        );
    };

    if (source.focus != 0) {
        _ = SetFocus(hwnd);
    }
    surface.creation_in_progress = false;
    state.creation_depth -= 1;

    if (surface.destroying.load(.acquire) or
        surface.invalidated.load(.acquire) or
        state.shutting_down.load(.acquire))
    {
        const was_invalidated = surface.invalidated.load(.acquire);
        const was_shutting_down = state.shutting_down.load(.acquire);
        if (!surface.destroying.load(.acquire)) {
            surface.destroying.store(true, .release);
        }
        closeSurfaceAdmission(surface);
        destroySurfaceNow(surface, 0);
        allocator.destroy(surface);
        const deinitialize_requested = state.deinitialize_requested;
        if (deinitialize_requested and state.creation_depth == 0) {
            deinitializeHost(state, 1);
            releaseHostAdmission(&host_admission);
            allocator.destroy(state);
        }
        return if (was_invalidated and !was_shutting_down)
            result_surface_invalidated
        else
            result_shutting_down;
    }

    output.* = surfaceHandle(surface);
    return result_ok;
}

pub export fn winghostty_surface_destroy(surface: ?*Surface) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkHost(state.host);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    if (state.destroying.load(.acquire)) {
        releaseSurfaceAdmission(&admission);
        return result_ok;
    }
    if (state.creation_in_progress) {
        state.destroying.store(true, .release);
        releaseSurfaceAdmission(&admission);
        return result_ok;
    }
    const host = state.host;
    host.destroy_surface_depth += 1;
    closeSurfaceAdmission(state);
    destroySurfaceNow(state, 1);
    host.destroy_surface_depth -= 1;
    const host_deinitialized = finishDeferredHostDeinitialize(host, 1);
    releaseSurfaceAdmission(&admission);
    if (host_deinitialized) allocator.destroy(host);
    allocator.destroy(state);
    return result_ok;
}

pub export fn winghostty_surface_set_bounds(
    surface: ?*Surface,
    bounds: ?*const Rect,
) Result {
    const next = bounds orelse return result_invalid_argument;
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    if (next.width > std.math.maxInt(i32) or next.height > std.math.maxInt(i32)) {
        releaseSurfaceAdmission(&admission);
        return result_invalid_argument;
    }
    state.options_mutex.lock();
    state.options.bounds = next.*;
    state.options_mutex.unlock();
    const hwnd = state.hwnd orelse {
        releaseSurfaceAdmission(&admission);
        return result_shutting_down;
    };
    releaseSurfaceAdmission(&admission);
    if (SetWindowPos(
        hwnd,
        null,
        next.x,
        next.y,
        @intCast(next.width),
        @intCast(next.height),
        SWP_NOZORDER | SWP_NOACTIVATE,
    ) == 0) return result_win32_error;
    return result_ok;
}

pub export fn winghostty_surface_set_visible(
    surface: ?*Surface,
    visible: u8,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const next_visible: u8 = if (visible == 0) 0 else 1;
    state.options_mutex.lock();
    state.options.visible = next_visible;
    state.options_mutex.unlock();
    const hwnd = state.hwnd orelse {
        releaseSurfaceAdmission(&admission);
        return result_shutting_down;
    };
    releaseSurfaceAdmission(&admission);
    _ = ShowWindow(hwnd, if (next_visible != 0) SW_SHOW else SW_HIDE);
    return result_ok;
}

pub export fn winghostty_surface_set_focus(
    surface: ?*Surface,
    focused: u8,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const next_focused: u8 = if (focused == 0) 0 else 1;
    state.options_mutex.lock();
    state.options.focus = next_focused;
    state.options_mutex.unlock();
    const hwnd = state.hwnd orelse {
        releaseSurfaceAdmission(&admission);
        return result_shutting_down;
    };
    releaseSurfaceAdmission(&admission);
    if (focused != 0) {
        _ = SetFocus(hwnd);
    } else if (GetFocus()) |current| {
        if (current == hwnd) _ = SetFocus(null);
    }
    return result_ok;
}

pub export fn winghostty_surface_set_theme(
    surface: ?*Surface,
    theme: Theme,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    if (theme < 0 or theme > 2) {
        releaseSurfaceAdmission(&admission);
        return result_invalid_argument;
    }
    state.options_mutex.lock();
    state.options.theme = theme;
    state.options_mutex.unlock();
    const hwnd = state.hwnd;
    releaseSurfaceAdmission(&admission);
    if (hwnd) |value| _ = InvalidateRect(value, null, 0);
    return result_ok;
}

pub export fn winghostty_surface_set_font_scale(
    surface: ?*Surface,
    font_scale: f32,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    if (font_scale <= 0 or !std.math.isFinite(font_scale)) {
        releaseSurfaceAdmission(&admission);
        return result_invalid_argument;
    }
    state.options_mutex.lock();
    state.options.font_scale = font_scale;
    state.options_mutex.unlock();
    const hwnd = state.hwnd;
    releaseSurfaceAdmission(&admission);
    if (hwnd) |value| _ = InvalidateRect(value, null, 0);
    return result_ok;
}

pub export fn winghostty_surface_make_current(surface: ?*Surface) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    const result = checkRenderSurface(state);
    if (result != result_ok) return result;
    const render_result = claimRenderThread(state.host);
    if (render_result != result_ok) return render_result;
    const renderer = beginRendererOperation(state) orelse
        return if (state.host.shutting_down.load(.acquire))
            result_shutting_down
        else
            result_surface_invalidated;
    defer endRendererOperation(state);
    renderer.makeCurrent() catch |err| return rendererResult(state, err);
    return result_ok;
}

pub export fn winghostty_surface_clear_current(surface: ?*Surface) Result {
    var admission = admitClearSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    state.host.render_thread_mutex.lock();
    const render_thread_id = state.host.render_thread_id;
    state.host.render_thread_mutex.unlock();
    if (GetCurrentThreadId() != render_thread_id) {
        return result_wrong_thread;
    }
    const renderer = beginClearRendererOperation(state) orelse
        return result_surface_invalidated;
    defer endRendererOperation(state);
    renderer.clearCurrent();
    return result_ok;
}

pub export fn winghostty_surface_render(surface: ?*Surface) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    if (state.invalidated.load(.acquire) or
        state.destroying.load(.acquire))
    {
        return result_surface_invalidated;
    }
    const render_result = claimRenderThread(state.host);
    if (render_result != result_ok) return render_result;
    const renderer = beginRendererOperation(state) orelse
        return if (state.host.shutting_down.load(.acquire))
            result_shutting_down
        else
            result_surface_invalidated;
    defer endRendererOperation(state);

    state.options_mutex.lock();
    const render_state = win32_presentation.RenderState{
        .theme = @enumFromInt(state.options.theme),
        .font_scale = state.options.font_scale,
        .width = state.options.bounds.width,
        .height = state.options.bounds.height,
    };
    state.options_mutex.unlock();

    win32_presentation.render(renderer, render_state) catch |err| {
        return rendererResult(state, err);
    };
    _ = state.present_count.fetchAdd(1, .release);
    return result_ok;
}

pub export fn winghostty_surface_present(surface: ?*Surface) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    if (state.invalidated.load(.acquire) or
        state.destroying.load(.acquire))
    {
        return result_surface_invalidated;
    }
    const render_result = claimRenderThread(state.host);
    if (render_result != result_ok) return render_result;
    const renderer = beginRendererOperation(state) orelse
        return if (state.host.shutting_down.load(.acquire))
            result_shutting_down
        else
            result_surface_invalidated;
    defer endRendererOperation(state);
    win32_presentation.present(renderer) catch |err| {
        return rendererResult(state, err);
    };
    _ = state.present_count.fetchAdd(1, .release);
    return result_ok;
}

pub export fn winghostty_surface_notify_exit(
    surface: ?*Surface,
    status: i32,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const callback = state.options.callbacks.on_exit;
    const user_data = state.options.user_data;
    const handle = surfaceHandle(state);
    releaseSurfaceAdmission(&admission);
    if (callback) |value| value(user_data, handle, status);
    return result_ok;
}

pub export fn winghostty_surface_notify_title(
    surface: ?*Surface,
    title: ?[*:0]const u8,
) Result {
    const value = title orelse return result_invalid_argument;
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const callback = state.options.callbacks.on_title;
    const user_data = state.options.user_data;
    const handle = surfaceHandle(state);
    releaseSurfaceAdmission(&admission);
    if (callback) |callback_value| callback_value(user_data, handle, value);
    return result_ok;
}

pub export fn winghostty_surface_notify_cwd(
    surface: ?*Surface,
    cwd: ?[*:0]const u8,
) Result {
    const value = cwd orelse return result_invalid_argument;
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const callback = state.options.callbacks.on_cwd;
    const user_data = state.options.user_data;
    const handle = surfaceHandle(state);
    releaseSurfaceAdmission(&admission);
    if (callback) |callback_value| callback_value(user_data, handle, value);
    return result_ok;
}

pub export fn winghostty_surface_notify_bell(surface: ?*Surface) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const callback = state.options.callbacks.on_bell;
    const user_data = state.options.user_data;
    const handle = surfaceHandle(state);
    releaseSurfaceAdmission(&admission);
    if (callback) |value| value(user_data, handle);
    return result_ok;
}

pub export fn winghostty_surface_notify_notification(
    surface: ?*Surface,
    notification: ?[*:0]const u8,
) Result {
    const value = notification orelse return result_invalid_argument;
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const callback = state.options.callbacks.on_notification;
    const user_data = state.options.user_data;
    const handle = surfaceHandle(state);
    releaseSurfaceAdmission(&admission);
    if (callback) |callback_value| callback_value(user_data, handle, value);
    return result_ok;
}

pub export fn winghostty_surface_notify_redraw(surface: ?*Surface) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const callback = state.options.callbacks.on_redraw;
    const user_data = state.options.user_data;
    const handle = surfaceHandle(state);
    releaseSurfaceAdmission(&admission);
    if (callback) |value| value(user_data, handle);
    return result_ok;
}

pub export fn winghostty_surface_notify_focus(
    surface: ?*Surface,
    focused: u8,
) Result {
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const callback = state.options.callbacks.on_focus;
    const user_data = state.options.user_data;
    const handle = surfaceHandle(state);
    releaseSurfaceAdmission(&admission);
    if (callback) |value| value(user_data, handle, if (focused == 0) 0 else 1);
    return result_ok;
}

pub export fn winghostty_surface_notify_fatal_error(
    surface: ?*Surface,
    result_code: Result,
    message: ?[*:0]const u8,
) Result {
    const value = message orelse return result_invalid_argument;
    var admission = admitSurface(surface) orelse
        return unavailableSurfaceResult(surface);
    const state = admission.surface;
    const result = checkSurface(state);
    if (result != result_ok) {
        releaseSurfaceAdmission(&admission);
        return result;
    }
    const callback = state.options.callbacks.on_fatal_error;
    const user_data = state.options.user_data;
    const handle = surfaceHandle(state);
    releaseSurfaceAdmission(&admission);
    if (callback) |callback_value| callback_value(user_data, handle, result_code, value);
    return result_ok;
}

pub export fn winghostty_surface_get_hwnd(surface: ?*const Surface) ?HWND {
    var admission = admitSurface(@constCast(surface)) orelse return null;
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    if (checkSurface(state) != result_ok or
        state.destroying.load(.acquire))
    {
        return null;
    }
    return state.hwnd;
}

pub export fn winghostty_surface_get_hdc(surface: ?*const Surface) HDC {
    var admission = admitSurface(@constCast(surface)) orelse return null;
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    return rendererHdc(state);
}

pub export fn winghostty_surface_get_hglrc(surface: ?*const Surface) HGLRC {
    var admission = admitSurface(@constCast(surface)) orelse return null;
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    return rendererHglrc(state);
}

pub export fn winghostty_host_get_ui_thread_id(host: ?*const Host) DWORD {
    var admission = admitHost(@constCast(host)) orelse return 0;
    defer releaseHostAdmission(&admission);
    const state = admission.state;
    if (state.shutting_down.load(.acquire)) return 0;
    return state.thread_id;
}

pub export fn winghostty_host_get_render_thread_id(host: ?*const Host) DWORD {
    var admission = admitHost(@constCast(host)) orelse return 0;
    defer releaseHostAdmission(&admission);
    const state = admission.state;
    if (state.shutting_down.load(.acquire)) return 0;
    state.render_thread_mutex.lock();
    defer state.render_thread_mutex.unlock();
    return state.render_thread_id;
}

pub export fn winghostty_surface_get_last_error(
    surface: ?*const Surface,
) DWORD {
    var admission = admitSurface(@constCast(surface)) orelse return 0;
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    if (state.host.shutting_down.load(.acquire) or
        state.invalidated.load(.acquire) or
        state.destroying.load(.acquire))
    {
        return 0;
    }
    return loadRendererError(state);
}

pub export fn winghostty_surface_get_present_count(
    surface: ?*const Surface,
) u64 {
    var admission = admitSurface(@constCast(surface)) orelse return 0;
    defer releaseSurfaceAdmission(&admission);
    const state = admission.surface;
    if (state.host.shutting_down.load(.acquire) or
        state.invalidated.load(.acquire) or
        state.destroying.load(.acquire))
    {
        return 0;
    }
    return state.present_count.load(.acquire);
}

pub export fn winghostty_host_drain(
    host: ?*Host,
    out_drained: ?*u32,
) Result {
    var admission = admitHost(host) orelse
        return unavailableHostResult(host);
    defer releaseHostAdmission(&admission);
    const state = admission.state;
    const result = checkHost(state);
    if (result != result_ok) return result;
    if (out_drained) |count| count.* = 0;
    return result_ok;
}

test "SurfaceOptions copies caller-owned strings" {
    var command = [_:0]u8{ 'c', 'm', 'd', '.', 'e', 'x', 'e' };
    var cwd = [_:0]u8{ 'C', ':', '\\' };
    var environment = [_:0]u8{ 'A', '=', 'B' };
    const options = SurfaceOptions{
        .command = &command,
        .cwd = &cwd,
        .environment = &environment,
        .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .visible = 0,
        .focus = 0,
        .theme = theme_system,
        .font_scale = 1,
        .callbacks = .{
            .on_exit = null,
            .on_title = null,
            .on_cwd = null,
            .on_bell = null,
            .on_notification = null,
            .on_redraw = null,
            .on_focus = null,
            .on_fatal_error = null,
        },
        .user_data = null,
    };
    var owned = try OwnedOptions.init(&options);
    defer owned.deinit();
    command[0] = 'X';
    try std.testing.expectEqualStrings("cmd.exe", owned.command.?);
    try std.testing.expectEqualStrings("C:\\", owned.cwd.?);
    try std.testing.expectEqualStrings("A=B", owned.environment.?);
}
